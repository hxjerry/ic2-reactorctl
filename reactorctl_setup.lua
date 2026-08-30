package.path = "/home/?.lua;/home/?/init.lua;" .. package.path

local component = require("component")
local hardware = require("reactorctl.hardware")
local configStore = require("reactorctl.config")

local configPath = (...) or configStore.DEFAULT_PATH

local function prompt(text, default)
  if default ~= nil then
    io.write(string.format("%s [%s]: ", text, tostring(default)))
  else
    io.write(text .. ": ")
  end
  io.flush()
  local value = io.read()
  if value == nil then
    error("input closed")
  end
  value = value:gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" and default ~= nil then
    return tostring(default)
  end
  return value
end

local function yesNo(text, default)
  local suffix = default and "Y/n" or "y/N"
  while true do
    local value = prompt(text .. " (" .. suffix .. ")", "")
    if value == "" then
      return default
    end
    value = value:lower()
    if value == "y" or value == "yes" then
      return true
    elseif value == "n" or value == "no" then
      return false
    end
  end
end

local function choose(text, choices, display)
  if #choices == 0 then
    error("no choices available for " .. text)
  end
  print(text)
  for index, choice in ipairs(choices) do
    print(string.format("  %d) %s", index, display and display(choice) or tostring(choice)))
  end
  while true do
    local selected = tonumber(prompt("Selection"))
    if selected and choices[selected] then
      return choices[selected]
    end
    print("Invalid selection.")
  end
end

local function chooseSide(text)
  return choose(text, hardware.SIDES, function(side)
    return string.format("%s (%d)", hardware.SIDE_NAMES[side], side)
  end)
end

local function short(address)
  return tostring(address):sub(1, 8)
end

local transposerAddresses = hardware.list(component, "transposer")
local reactorAddresses = {}
for _, address in ipairs(hardware.list(component, "reactor")) do
  reactorAddresses[#reactorAddresses + 1] = address
end
for _, address in ipairs(hardware.list(component, "reactor_chamber")) do
  reactorAddresses[#reactorAddresses + 1] = address
end
table.sort(reactorAddresses)
local redstoneAddresses = hardware.list(component, "redstone")

if #transposerAddresses == 0 then
  error("no transposers are connected")
end
if #reactorAddresses == 0 then
  error("no reactor or reactor_chamber components are connected")
end
if #redstoneAddresses == 0 then
  error("no redstone components are connected")
end

for _, address in ipairs(transposerAddresses) do
  if not hardware.hasMethod(component, address, "swap") then
    error(string.format(
      "transposer %s has no swap method; this controller requires GTNH OpenComputers 1.12.30-GTNH or newer",
      address
    ))
  end
  if not hardware.hasMethod(component, address, "transferItem") then
    error(string.format(
      "transposer %s has no transferItem method; this controller requires item transfer support",
      address
    ))
  end
end

print("Reactor Controller commissioning")
print("All reactor run outputs must be physically inhibited while commissioning.")
print("Only atomic transposer.swap operations will be configured.")

local templateAddress = choose("Select a template transposer", transposerAddresses, function(address)
  return short(address) .. "  " .. address
end)
local template = component.proxy(templateAddress)
local probes = hardware.probeInventories(template)
if #probes < 4 then
  error("template transposer exposes fewer than four inventories")
end

print("Inventories visible from the template transposer:")
for _, probe in ipairs(probes) do
  print(string.format(
    "  side %-5s (%d): name=%s size=%d",
    hardware.SIDE_NAMES[probe.side],
    probe.side,
    tostring(probe.name),
    probe.size
  ))
end

local inventoryTypes = {}
local selectedSignatures = {}
for _, role in ipairs({"reactor", "fuel", "coolant", "staging"}) do
  local probe = choose("Select the " .. role .. " inventory", probes, function(candidate)
    return string.format(
      "%s (%d): %s / %d slots",
      hardware.SIDE_NAMES[candidate.side],
      candidate.side,
      candidate.name,
      candidate.size
    )
  end)
  local key = tostring(probe.name) .. "\0" .. tostring(probe.size)
  if selectedSignatures[key] then
    error(string.format(
      "%s and %s use the same inventory signature; fixed-type discovery requires unique name/size pairs",
      role,
      selectedSignatures[key]
    ))
  end
  selectedSignatures[key] = role
  inventoryTypes[role] = {name = probe.name, size = probe.size}
end

local matchingTransposers = {}
for _, address in ipairs(transposerAddresses) do
  local proxy = component.proxy(address)
  local sides, reason = hardware.discoverInventorySides(proxy, inventoryTypes)
  if sides then
    matchingTransposers[#matchingTransposers + 1] = {address = address, proxy = proxy, sides = sides}
  else
    print(string.format("Ignoring transposer %s: %s", short(address), reason))
  end
end
if #matchingTransposers == 0 then
  error("no transposer matches all four fixed inventory types")
end

local usedReactors = {}
local usedOutputs = {}
local reactors = {}
local roleByItemName = {}

local function availableReactors()
  local values = {}
  for _, address in ipairs(reactorAddresses) do
    if not usedReactors[address] then
      values[#values + 1] = address
    end
  end
  return values
end

local function outputKey(address, side)
  return address .. ":" .. tostring(side)
end

local function captureSchematic(entry)
  local staging, stagingError = hardware.scanInventory(entry.proxy, entry.sides.staging)
  if not staging then
    error(stagingError)
  end
  if hardware.findStack(staging, function() return true end) then
    error(entry.name .. ": staging inventory must be empty during commissioning")
  end

  local stacks, scanError = hardware.scanInventory(entry.proxy, entry.sides.reactor)
  if not stacks then
    error(scanError)
  end
  local schematic = {}

  for slot = 1, #stacks do
    local stack = stacks[slot]
    if hardware.isEmpty(stack) then
      schematic[slot] = {role = "empty"}
    else
      local role = roleByItemName[stack.name]
      if not role then
        print(string.format(
          "%s slot %d contains %s (%s), damage=%s/%s",
          entry.name,
          slot,
          tostring(stack.label),
          tostring(stack.name),
          tostring(stack.damage),
          tostring(stack.maxDamage)
        ))
        role = choose("Classify this item", {"fuel", "coolant", "fixed"})
        roleByItemName[stack.name] = role
      end
      schematic[slot] = {role = role, name = stack.name}
    end
  end
  return schematic
end

for index, transposer in ipairs(matchingTransposers) do
  print(string.format("\nConfiguring transposer %s", transposer.address))
  local name = prompt("Reactor display name", string.format("R%02d", index))
  local reactorAddress = choose("Select the matching reactor peripheral", availableReactors(), function(address)
    return string.format("%s  type=%s", address, component.type(address))
  end)
  usedReactors[reactorAddress] = true

  local redstoneAddress = choose("Select the reactor run-request redstone component", redstoneAddresses, function(address)
    return address
  end)
  local redstoneSide
  while true do
    redstoneSide = chooseSide("Select its run-request output side")
    local key = outputKey(redstoneAddress, redstoneSide)
    if not usedOutputs[key] then
      usedOutputs[key] = true
      break
    end
    print("That redstone output is already assigned.")
  end
  pcall(component.proxy(redstoneAddress).setOutput, redstoneSide, 0)

  local entry = {
    name = name,
    transposer = transposer.address,
    reactor = reactorAddress,
    redstone = {address = redstoneAddress, side = redstoneSide},
    proxy = transposer.proxy,
    sides = transposer.sides,
  }
  entry.schematic = captureSchematic(entry)
  entry.proxy = nil
  entry.sides = nil
  reactors[#reactors + 1] = entry
end

local watchdogAddress = choose("Select the global watchdog heartbeat redstone component", redstoneAddresses, function(address)
  return address
end)
local watchdogSide
while true do
  watchdogSide = chooseSide("Select the watchdog heartbeat output side")
  local key = outputKey(watchdogAddress, watchdogSide)
  if not usedOutputs[key] then
    break
  end
  print("That redstone output is already assigned to a reactor.")
end
pcall(component.proxy(watchdogAddress).setOutput, watchdogSide, 0)

local configuration = configStore.applyDefaults({
  format = 1,
  target = "GTNH 2.9.0-beta-2 / OpenComputers 1.12.48-GTNH or newer",
  inventoryTypes = inventoryTypes,
  watchdog = {address = watchdogAddress, side = watchdogSide},
  reactors = reactors,
  autoArm = yesNo("Arm automatically after a successful boot-time verification", false),
})

local saved, saveError = configStore.save(configuration, configPath)
if not saved then
  error(saveError)
end

print(string.format("Saved %d reactor definitions to %s", #reactors, configPath))
print("Review the external watchdog and manual inhibit before running reactorctl.lua.")
