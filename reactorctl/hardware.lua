local hardware = {}

hardware.SIDES = {0, 1, 2, 3, 4, 5}
hardware.SIDE_NAMES = {
  [0] = "down",
  [1] = "up",
  [2] = "north",
  [3] = "south",
  [4] = "west",
  [5] = "east",
}

local function call(object, method, ...)
  local fn = object and object[method]
  if fn == nil then
    return nil, "missing method " .. tostring(method)
  end
  local values = table.pack(pcall(fn, ...))
  if not values[1] then
    return nil, tostring(values[2])
  end
  return table.unpack(values, 2, values.n)
end

function hardware.call(object, method, ...)
  return call(object, method, ...)
end

function hardware.list(component, kind)
  local result = {}
  for address in component.list(kind, true) do
    result[#result + 1] = address
  end
  table.sort(result)
  return result
end

function hardware.proxy(component, address, expectedType)
  if not address then
    return nil, "component address is missing"
  end
  local actual = component.type(address)
  if actual ~= expectedType then
    return nil, string.format("component %s is %s, expected %s", address, tostring(actual), expectedType)
  end
  local ok, proxy = pcall(component.proxy, address)
  if not ok then
    return nil, tostring(proxy)
  end
  return proxy
end

function hardware.hasMethod(component, address, method)
  local ok, methods = pcall(component.methods, address)
  return ok and type(methods) == "table" and methods[method] ~= nil
end

function hardware.inventorySignature(transposer, side)
  local name, nameError = call(transposer, "getInventoryName", side)
  if name == nil then
    return nil, nameError
  end
  local size, sizeError = call(transposer, "getInventorySize", side)
  if size == nil then
    return nil, sizeError
  end
  return {name = name, size = size}
end

function hardware.sameSignature(left, right)
  return left and right and left.name == right.name and left.size == right.size
end

function hardware.probeInventories(transposer)
  local result = {}
  for _, side in ipairs(hardware.SIDES) do
    local signature = hardware.inventorySignature(transposer, side)
    if signature then
      result[#result + 1] = {
        side = side,
        name = signature.name,
        size = signature.size,
      }
    end
  end
  return result
end

function hardware.discoverInventorySides(transposer, signatures)
  local found = {}
  local probes = hardware.probeInventories(transposer)

  for role, expected in pairs(signatures) do
    local matches = {}
    for _, probe in ipairs(probes) do
      if hardware.sameSignature(probe, expected) then
        matches[#matches + 1] = probe.side
      end
    end
    if #matches ~= 1 then
      return nil, string.format(
        "inventory role %s matched %d sides; expected exactly one %s/%d inventory",
        role,
        #matches,
        tostring(expected.name),
        tonumber(expected.size) or -1
      )
    end
    found[role] = matches[1]
  end

  return found
end

function hardware.scanInventory(transposer, side)
  local size, sizeError = call(transposer, "getInventorySize", side)
  if size == nil then
    return nil, sizeError
  end
  local iterator, iteratorError = call(transposer, "getAllStacks", side)
  if iterator == nil then
    return nil, iteratorError
  end
  local function nextStack()
    return iterator()
  end

  local stacks = {}
  for slot = 1, size do
    local ok, stack = pcall(nextStack)
    if not ok then
      return nil, tostring(stack)
    end
    if type(stack) == "table" and next(stack) ~= nil then
      stacks[slot] = stack
    else
      stacks[slot] = false
    end
  end
  return stacks
end

function hardware.isEmpty(stack)
  return stack == nil or stack == false or (type(stack) == "table" and next(stack) == nil)
end

function hardware.remainingFraction(stack)
  if hardware.isEmpty(stack) then
    return 0
  end
  local maxDamage = tonumber(stack.maxDamage)
  local damage = tonumber(stack.damage)
  if not maxDamage or maxDamage <= 0 then
    return 1
  end
  damage = damage or 0
  return math.max(0, math.min(1, (maxDamage - damage) / maxDamage))
end

function hardware.findStack(stacks, predicate)
  for slot = 1, #stacks do
    local stack = stacks[slot]
    if not hardware.isEmpty(stack) and predicate(stack, slot) then
      return slot, stack
    end
  end
  return nil
end

function hardware.findEmpty(stacks)
  for slot = 1, #stacks do
    if hardware.isEmpty(stacks[slot]) then
      return slot
    end
  end
  return nil
end

function hardware.swap(transposer, sourceSide, sinkSide, sourceSlot, sinkSlot, safe)
  local ok, result, reason = pcall(
    transposer.swap,
    sourceSide,
    sinkSide,
    sourceSlot,
    sinkSlot,
    safe == true
  )
  if not ok then
    return false, tostring(result)
  end
  if result ~= true then
    return false, tostring(reason or "swap rejected")
  end
  return true
end

return hardware
