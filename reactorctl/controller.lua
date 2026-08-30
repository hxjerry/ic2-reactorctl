local hardware = require("reactorctl.hardware")

local Controller = {}
Controller.__index = Controller

local function nowOrZero(computer)
  local ok, value = pcall(computer.uptime)
  return ok and value or 0
end

local function itemDescription(stack)
  if hardware.isEmpty(stack) then
    return "empty"
  end
  return tostring(stack.name or stack.label or "unknown item")
end

function Controller.new(configuration, dependencies)
  local self = setmetatable({}, Controller)
  self.config = configuration
  self.component = dependencies.component
  self.computer = dependencies.computer
  self.reactors = {}
  self.logs = {}
  self.armed = false
  self.nextWatchdog = 0
  self.watchdogLevel = 0
  self.nextIndex = 1
  return self
end

function Controller:log(level, message)
  self.logs[#self.logs + 1] = {
    time = nowOrZero(self.computer),
    level = level,
    message = tostring(message),
  }
  while #self.logs > 30 do
    table.remove(self.logs, 1)
  end
end

function Controller:setRedstone(address, side, value)
  local proxy, reason = hardware.proxy(self.component, address, "redstone")
  if not proxy then
    return false, reason
  end
  local ok, result = pcall(proxy.setOutput, side, value)
  if not ok then
    return false, tostring(result)
  end
  return true
end

function Controller:setRun(runtime, enabled)
  local value = enabled and 15 or 0
  if runtime.runLevel == value then
    return true
  end
  local ok, reason = self:setRedstone(runtime.config.redstone.address, runtime.config.redstone.side, value)
  if not ok then
    runtime.runLevel = nil
    return false, reason
  end
  runtime.runLevel = value
  return true
end

function Controller:disableAll()
  for _, runtime in ipairs(self.reactors) do
    self:setRun(runtime, false)
  end
end

function Controller:initialize()
  if type(self.config.reactors) ~= "table" or #self.config.reactors == 0 then
    return nil, "no reactors are configured"
  end

  -- Persisted redstone outputs may still be high after a prior crash. Drive every
  -- configured output low before inventory scans or any other fallible startup work.
  local redstones = {}
  local usedOutputs = {}
  local firstOutputError
  for index, reactorConfig in ipairs(self.config.reactors) do
    local redstoneConfig = reactorConfig.redstone
    if type(redstoneConfig) ~= "table" then
      firstOutputError = firstOutputError or string.format("reactor %d has no redstone output", index)
    else
      local key = tostring(redstoneConfig.address) .. ":" .. tostring(redstoneConfig.side)
      if usedOutputs[key] then
        firstOutputError = firstOutputError or "duplicate redstone output " .. key
      end
      usedOutputs[key] = true
      local redstone, redstoneError = hardware.proxy(self.component, redstoneConfig.address, "redstone")
      if not redstone then
        firstOutputError = firstOutputError or redstoneError
      else
        redstones[index] = redstone
        local ok, reason = pcall(redstone.setOutput, redstoneConfig.side, 0)
        if not ok then
          firstOutputError = firstOutputError or tostring(reason)
        end
      end
    end
  end

  local watchdog = self.config.watchdog
  if type(watchdog) ~= "table" then
    firstOutputError = firstOutputError or "watchdog redstone output is missing from configuration"
  else
    local watchdogKey = tostring(watchdog.address) .. ":" .. tostring(watchdog.side)
    if usedOutputs[watchdogKey] then
      firstOutputError = firstOutputError or "watchdog output duplicates reactor output " .. watchdogKey
    end
    local watchdogProxy, watchdogError = hardware.proxy(self.component, watchdog.address, "redstone")
    if not watchdogProxy then
      firstOutputError = firstOutputError or watchdogError
    else
      self.watchdog = watchdogProxy
      local ok, reason = pcall(self.watchdog.setOutput, watchdog.side, 0)
      if not ok then
        firstOutputError = firstOutputError or tostring(reason)
      end
    end
  end
  self.watchdogLevel = 0
  if firstOutputError then
    return nil, firstOutputError
  end
  if type(self.config.inventoryTypes) ~= "table" then
    return nil, "inventoryTypes is missing from configuration"
  end
  for _, role in ipairs({"reactor", "fuel", "coolant", "staging"}) do
    if type(self.config.inventoryTypes[role]) ~= "table" then
      return nil, "inventory type is missing for role " .. role
    end
  end

  for index, reactorConfig in ipairs(self.config.reactors) do
    local transposer, transposerError = hardware.proxy(self.component, reactorConfig.transposer, "transposer")
    if not transposer then
      return nil, transposerError
    end
    if not hardware.hasMethod(self.component, reactorConfig.transposer, "swap") then
      return nil, string.format(
        "transposer %s has no atomic swap method; OpenComputers 1.12.30-GTNH or newer is required",
        reactorConfig.transposer
      )
    end
    if not hardware.hasMethod(self.component, reactorConfig.transposer, "transferItem") then
      return nil, string.format(
        "transposer %s has no transferItem method; OpenComputers item transfer is required",
        reactorConfig.transposer
      )
    end

    local inventorySides, discoveryError = hardware.discoverInventorySides(transposer, self.config.inventoryTypes)
    if not inventorySides then
      return nil, string.format("%s: %s", reactorConfig.name or ("reactor " .. index), discoveryError)
    end

    local reactorType = self.component.type(reactorConfig.reactor)
    if reactorType ~= "reactor" and reactorType ~= "reactor_chamber" then
      return nil, string.format(
        "component %s is %s, expected reactor or reactor_chamber",
        tostring(reactorConfig.reactor),
        tostring(reactorType)
      )
    end
    local ok, reactor = pcall(self.component.proxy, reactorConfig.reactor)
    if not ok then
      return nil, tostring(reactor)
    end

    local runtime = {
      config = reactorConfig,
      transposer = transposer,
      reactor = reactor,
      redstone = redstones[index],
      sides = inventorySides,
      state = "DISARMED",
      reason = "not armed",
      runLevel = 0,
      nextDue = 0,
      offSince = nil,
      fault = nil,
      stagingDirty = true,
      heat = 0,
      maxHeat = 0,
      output = 0,
    }
    self.reactors[#self.reactors + 1] = runtime
  end

  self.nextWatchdog = nowOrZero(self.computer)
  self:log("INFO", string.format("initialized %d reactors with atomic-swap-only transport", #self.reactors))
  return true
end

function Controller:setArmed(armed)
  self.armed = armed == true
  if not self.armed then
    self:disableAll()
  end
  for _, runtime in ipairs(self.reactors) do
    runtime.nextDue = 0
    runtime.offSince = nil
    if not self.armed then
      runtime.state = "DISARMED"
      runtime.reason = "not armed"
    elseif not runtime.fault then
      runtime.state = "VERIFYING"
      runtime.reason = "initial inventory verification"
    end
  end
  self:log("INFO", self.armed and "controller armed" or "controller disarmed")
end

function Controller:resetFaults()
  for _, runtime in ipairs(self.reactors) do
    runtime.fault = nil
    runtime.offSince = nil
    runtime.nextDue = 0
    runtime.state = self.armed and "VERIFYING" or "DISARMED"
    runtime.reason = "fault reset requested"
  end
  self:log("INFO", "fault latches reset")
end

function Controller:fault(runtime, message)
  self:setRun(runtime, false)
  runtime.fault = tostring(message)
  runtime.state = "FAULT"
  runtime.reason = runtime.fault
  runtime.offSince = nil
  self:log("ERROR", string.format("%s: %s", runtime.config.name, runtime.fault))
end

function Controller:kickWatchdog(now)
  if not self.watchdog or now < self.nextWatchdog then
    return true
  end
  self.watchdogLevel = self.watchdogLevel == 0 and 15 or 0
  local ok, reason = pcall(self.watchdog.setOutput, self.config.watchdog.side, self.watchdogLevel)
  if not ok then
    self.armed = false
    self:disableAll()
    self:log("ERROR", "watchdog output failed: " .. tostring(reason))
    return false
  end
  self.nextWatchdog = now + self.config.watchdogInterval
  return true
end

function Controller:scanReactor(runtime)
  local stacks, scanError = hardware.scanInventory(runtime.transposer, runtime.sides.reactor)
  if not stacks then
    return nil, scanError
  end
  if #stacks ~= #runtime.config.schematic then
    return nil, string.format("reactor inventory has %d slots, schematic has %d", #stacks, #runtime.config.schematic)
  end

  local heat, heatError = hardware.call(runtime.reactor, "getHeat")
  if heat == nil then
    return nil, heatError
  end
  local maxHeat, maxHeatError = hardware.call(runtime.reactor, "getMaxHeat")
  if maxHeat == nil then
    return nil, maxHeatError
  end
  local producesEnergy, activeError = hardware.call(runtime.reactor, "producesEnergy")
  if producesEnergy == nil then
    return nil, activeError
  end
  local output = hardware.call(runtime.reactor, "getReactorEUOutput")

  runtime.heat = tonumber(heat) or 0
  runtime.maxHeat = tonumber(maxHeat) or 0
  runtime.output = tonumber(output) or 0
  runtime.producesEnergy = producesEnergy == true
  return stacks
end

function Controller:analyze(runtime, stacks)
  local coolantIssue
  local fuelIssue

  for slot, expected in ipairs(runtime.config.schematic) do
    local actual = stacks[slot]
    if expected.role == "empty" then
      if not hardware.isEmpty(actual) then
        return nil, nil, string.format("slot %d should be empty, found %s", slot, itemDescription(actual))
      end
    elseif expected.role == "fixed" then
      if hardware.isEmpty(actual) or actual.name ~= expected.name then
        return nil, nil, string.format("fixed slot %d expected %s, found %s", slot, expected.name, itemDescription(actual))
      end
    elseif expected.role == "coolant" then
      if hardware.isEmpty(actual) then
        coolantIssue = coolantIssue or {slot = slot, kind = "missing", expected = expected}
      elseif actual.name ~= expected.name then
        return nil, nil, string.format("coolant slot %d expected %s, found %s", slot, expected.name, itemDescription(actual))
      elseif actual.maxDamage == nil or tonumber(actual.maxDamage) == nil or tonumber(actual.maxDamage) <= 0 then
        return nil, nil, string.format("coolant slot %d has no usable durability data", slot)
      elseif hardware.remainingFraction(actual) <= self.config.coolantMinimumRemaining then
        coolantIssue = coolantIssue or {slot = slot, kind = "low", expected = expected}
      end
    elseif expected.role == "fuel" then
      if hardware.isEmpty(actual) then
        fuelIssue = fuelIssue or {slot = slot, kind = "missing", expected = expected}
      elseif actual.name ~= expected.name then
        fuelIssue = fuelIssue or {slot = slot, kind = "spent", expected = expected, actual = actual}
      end
    else
      return nil, nil, string.format("slot %d has unknown schematic role %s", slot, tostring(expected.role))
    end
  end

  return coolantIssue, fuelIssue, nil
end

function Controller:findFresh(runtime, role, expectedName, minimumRemaining)
  local side = runtime.sides[role]
  local stacks, reason = hardware.scanInventory(runtime.transposer, side)
  if not stacks then
    return nil, nil, reason
  end
  local slot, stack = hardware.findStack(stacks, function(candidate)
    return candidate.name == expectedName and hardware.remainingFraction(candidate) >= minimumRemaining
  end)
  return slot, stack
end

function Controller:stagingDestination(runtime, stack)
  for _, expected in ipairs(runtime.config.schematic) do
    if expected.role == "coolant" and expected.name == stack.name then
      return "coolant"
    end
  end
  return "fuel"
end

function Controller:flushOneStagingSlot(runtime)
  if not runtime.stagingDirty then
    return true
  end

  local stagingStacks, stagingError = hardware.scanInventory(runtime.transposer, runtime.sides.staging)
  if not stagingStacks then
    return false, stagingError
  end
  local stagingSlot, stagedStack = hardware.findStack(stagingStacks, function()
    return true
  end)
  if not stagingSlot then
    runtime.stagingDirty = false
    return true
  end

  local destination = self:stagingDestination(runtime, stagedStack)
  local destinationStacks, destinationError = hardware.scanInventory(runtime.transposer, runtime.sides[destination])
  if not destinationStacks then
    return false, destinationError
  end
  local destinationSlot = hardware.findMatching(destinationStacks, stagedStack)
  local merge = destinationSlot ~= nil
  destinationSlot = destinationSlot or hardware.findEmpty(destinationStacks)
  if not destinationSlot then
    return true
  end

  local ok, transferError = hardware.transfer(
    runtime.transposer,
    runtime.sides.staging,
    runtime.sides[destination],
    stagingSlot,
    destinationSlot,
    1
  )
  if not ok and merge then
    destinationSlot = hardware.findEmpty(destinationStacks)
    if destinationSlot then
      merge = false
      ok, transferError = hardware.transfer(
        runtime.transposer,
        runtime.sides.staging,
        runtime.sides[destination],
        stagingSlot,
        destinationSlot,
        1
      )
    end
  end
  if not ok then
    return false, transferError
  end
  self:log("INFO", string.format(
    "%s: returned staged %s to %s inventory%s",
    runtime.config.name,
    tostring(stagedStack.name),
    destination,
    merge and " stack" or ""
  ))
  return true
end

function Controller:emptyStagingSlot(runtime)
  local flushed, flushError = self:flushOneStagingSlot(runtime)
  if not flushed then
    return nil, flushError, "io"
  end

  local stagingStacks, stagingError = hardware.scanInventory(runtime.transposer, runtime.sides.staging)
  if not stagingStacks then
    return nil, stagingError, "io"
  end
  if hardware.findStack(stagingStacks, function() return true end) then
    return nil, "stable staging inventory is occupied and its destination has no free slot", "occupied"
  end
  local slot = hardware.findEmpty(stagingStacks)
  if not slot then
    return nil, "stable staging inventory has no empty slot", "occupied"
  end
  runtime.stagingDirty = false
  return slot
end

function Controller:stageFresh(runtime, role, expectedName, minimumRemaining)
  local stagingSlot, stagingError, stagingKind = self:emptyStagingSlot(runtime)
  if not stagingSlot then
    return nil, stagingError, stagingKind
  end
  local freshSlot, _, findError = self:findFresh(runtime, role, expectedName, minimumRemaining)
  if findError then
    return nil, findError, "io"
  end
  if not freshSlot then
    return nil, "no fresh " .. expectedName .. " is available", "unavailable"
  end
  local moved, transferError = hardware.transfer(
    runtime.transposer,
    runtime.sides[role],
    runtime.sides.staging,
    freshSlot,
    stagingSlot,
    1
  )
  if not moved then
    return nil, transferError, "io"
  end
  runtime.stagingDirty = true

  -- The provider inventory may be modified by ME or pipe automation between
  -- discovery and the transfer. Validate the isolated staging slot before it
  -- can ever be inserted into the reactor.
  local stagingStacks, validationError = hardware.scanInventory(runtime.transposer, runtime.sides.staging)
  if not stagingStacks then
    return nil, validationError, "io"
  end
  local staged = stagingStacks[stagingSlot]
  if hardware.isEmpty(staged)
      or tonumber(staged.size) ~= 1
      or staged.name ~= expectedName
      or hardware.remainingFraction(staged) < minimumRemaining then
    return nil, "provider changed before transfer; unexpected item or stack size was isolated in staging", "invalid"
  end
  return stagingSlot
end

function Controller:replaceCoolant(runtime, issue)
  local stagingSlot, reason = self:stageFresh(
    runtime,
    "coolant",
    issue.expected.name,
    self.config.coolantFreshRemaining
  )
  if not stagingSlot then
    return false, reason
  end

  local ok, swapError = hardware.swap(
    runtime.transposer,
    runtime.sides.reactor,
    runtime.sides.staging,
    issue.slot,
    stagingSlot,
    issue.kind ~= "missing"
  )
  if not ok then
    return false, swapError
  end
  runtime.stagingDirty = true
  local flushed, flushError = self:flushOneStagingSlot(runtime)
  if not flushed then
    return false, flushError
  end
  self:log("INFO", string.format("%s: atomically replaced coolant in slot %d via staging", runtime.config.name, issue.slot))
  return true
end

function Controller:maintainFuel(runtime, issue)
  local stagingSlot, reason, kind = self:stageFresh(
    runtime,
    "fuel",
    issue.expected.name,
    self.config.fuelFreshRemaining
  )

  if stagingSlot then
    local ok, swapError = hardware.swap(
      runtime.transposer,
      runtime.sides.reactor,
      runtime.sides.staging,
      issue.slot,
      stagingSlot,
      issue.kind ~= "missing"
    )
    if not ok then
      return false, swapError
    end
    runtime.stagingDirty = true
    local flushed, flushError = self:flushOneStagingSlot(runtime)
    if not flushed then
      return false, flushError
    end
    self:log("INFO", string.format("%s: atomically restored fuel slot %d via staging", runtime.config.name, issue.slot))
    return true, true
  end

  if kind == "io" then
    return false, reason
  end
  if kind ~= "unavailable" or issue.kind == "missing" then
    runtime.state = "NO_FUEL"
    runtime.reason = reason or string.format("waiting for %s for slot %d", issue.expected.name, issue.slot)
    return true
  end

  local emptySlot, stagingError, stagingKind = self:emptyStagingSlot(runtime)
  if not emptySlot then
    if stagingKind == "io" then
      return false, stagingError
    end
    runtime.state = "NO_FUEL"
    runtime.reason = stagingError
    return true
  end

  local ok, swapError = hardware.swap(
    runtime.transposer,
    runtime.sides.reactor,
    runtime.sides.staging,
    issue.slot,
    emptySlot,
    false
  )
  if not ok then
    return false, swapError
  end
  runtime.stagingDirty = true
  local flushed, flushError = self:flushOneStagingSlot(runtime)
  if not flushed then
    return false, flushError
  end
  runtime.state = "NO_FUEL"
  runtime.reason = string.format("removed spent fuel from slot %d; replacement unavailable", issue.slot)
  self:log("WARN", string.format("%s: fuel slot %d left empty until stock arrives", runtime.config.name, issue.slot))
  return true
end

function Controller:stepReactor(runtime, now)
  if not self.armed then
    local ok, reason = self:setRun(runtime, false)
    if not ok then
      self:fault(runtime, reason)
      return
    end
    runtime.state = "DISARMED"
    runtime.reason = "not armed"
    runtime.nextDue = now + self.config.scanInterval
    return
  end

  if runtime.fault then
    self:setRun(runtime, false)
    runtime.nextDue = now + self.config.scanInterval
    return
  end

  local stacks, scanError = self:scanReactor(runtime)
  if not stacks then
    self:fault(runtime, scanError)
    runtime.nextDue = now + self.config.scanInterval
    return
  end

  if runtime.maxHeat <= 0 then
    self:fault(runtime, "reactor reported invalid maximum heat")
    runtime.nextDue = now + self.config.scanInterval
    return
  end
  if runtime.heat / runtime.maxHeat >= self.config.maximumHeatFraction then
    self:fault(runtime, string.format("reactor heat %.1f%% exceeded limit", 100 * runtime.heat / runtime.maxHeat))
    runtime.nextDue = now + self.config.scanInterval
    return
  end

  local coolantIssue, fuelIssue, fatal = self:analyze(runtime, stacks)
  if fatal then
    self:fault(runtime, fatal)
    runtime.nextDue = now + self.config.scanInterval
    return
  end

  if coolantIssue then
    local ok, reason = self:setRun(runtime, false)
    if not ok then
      self:fault(runtime, reason)
      return
    end

    if not runtime.offSince then
      runtime.offSince = now
      runtime.state = "STOPPING"
      runtime.reason = string.format("coolant slot %d requires replacement", coolantIssue.slot)
      runtime.nextDue = now + self.config.shutdownDelay
      return
    end

    if now - runtime.offSince < self.config.shutdownDelay or runtime.producesEnergy then
      runtime.state = "STOPPING"
      runtime.reason = "waiting for confirmed reactor shutdown"
      runtime.nextDue = now + 0.25
      return
    end

    local replaced, replaceError = self:replaceCoolant(runtime, coolantIssue)
    if not replaced then
      runtime.state = "BLOCKED"
      runtime.reason = replaceError
      runtime.nextDue = now + self.config.scanInterval
      return
    end

    runtime.state = "COOLANT"
    runtime.reason = string.format("replaced coolant slot %d; verifying", coolantIssue.slot)
    runtime.nextDue = now + 0.05
    return
  end

  runtime.offSince = nil

  local fuelChanged = false
  if fuelIssue then
    local maintained, changedOrError = self:maintainFuel(runtime, fuelIssue)
    if not maintained then
      self:fault(runtime, changedOrError)
      runtime.nextDue = now + self.config.scanInterval
      return
    end
    fuelChanged = changedOrError == true
  end

  local flushed, flushError = self:flushOneStagingSlot(runtime)
  if not flushed then
    self:fault(runtime, flushError)
    runtime.nextDue = now + self.config.scanInterval
    return
  end

  local ok, reason = self:setRun(runtime, true)
  if not ok then
    self:fault(runtime, reason)
    return
  end

  if fuelChanged then
    runtime.state = "VERIFYING"
    runtime.reason = string.format("restored fuel slot %d; verifying", fuelIssue.slot)
    runtime.nextDue = now + 0.05
  elseif not fuelIssue then
    runtime.state = "RUNNING"
    runtime.reason = "layout verified"
    runtime.nextDue = now + self.config.scanInterval
  else
    runtime.nextDue = now + self.config.scanInterval
  end
end

function Controller:step(now)
  now = now or nowOrZero(self.computer)
  self:kickWatchdog(now)
  if #self.reactors == 0 then
    return
  end

  for _ = 1, #self.reactors do
    local runtime = self.reactors[self.nextIndex]
    self.nextIndex = self.nextIndex % #self.reactors + 1
    if now >= runtime.nextDue then
      local ok, reason = pcall(self.stepReactor, self, runtime, now)
      if not ok then
        self:fault(runtime, reason)
        runtime.nextDue = now + self.config.scanInterval
      end
      return
    end
  end
end

function Controller:snapshot()
  local result = {
    armed = self.armed,
    watchdogLevel = self.watchdogLevel,
    reactors = {},
    logs = self.logs,
  }
  for _, runtime in ipairs(self.reactors) do
    result.reactors[#result.reactors + 1] = {
      name = runtime.config.name,
      state = runtime.state,
      reason = runtime.reason,
      heat = runtime.heat,
      maxHeat = runtime.maxHeat,
      output = runtime.output,
      running = runtime.runLevel == 15,
      fault = runtime.fault,
    }
  end
  return result
end

function Controller:shutdown()
  self.armed = false
  self:disableAll()
  if self.watchdog and self.config.watchdog then
    pcall(self.watchdog.setOutput, self.config.watchdog.side, 0)
  end
  self.watchdogLevel = 0
end

return Controller
