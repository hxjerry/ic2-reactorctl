local config = {}

config.DEFAULT_PATH = "/home/reactorctl.cfg"

local function dependencies()
  return require("filesystem"), require("serialization")
end

function config.load(path)
  path = path or config.DEFAULT_PATH
  local filesystem, serialization = dependencies()
  if not filesystem.exists(path) then
    local backup = path .. ".bak"
    if filesystem.exists(backup) then
      path = backup
    else
      return nil, "configuration not found: " .. path
    end
  end

  local file, openError = io.open(path, "r")
  if not file then
    return nil, openError
  end
  local text = file:read("*a")
  file:close()

  local value, parseError = serialization.unserialize(text)
  if type(value) ~= "table" then
    return nil, parseError or "configuration did not contain a table"
  end
  return value
end

function config.save(value, path)
  path = path or config.DEFAULT_PATH
  local filesystem, serialization = dependencies()
  local temporary = path .. ".new"
  local backup = path .. ".bak"

  local file, openError = io.open(temporary, "w")
  if not file then
    return nil, openError
  end
  file:write(serialization.serialize(value))
  file:write("\n")
  file:close()

  if filesystem.exists(backup) then
    filesystem.remove(backup)
  end
  if filesystem.exists(path) then
    local backedUp, backupError = filesystem.rename(path, backup)
    if not backedUp then
      filesystem.remove(temporary)
      return nil, backupError
    end
  end

  local ok, reason = filesystem.rename(temporary, path)
  if not ok then
    if filesystem.exists(backup) then
      filesystem.rename(backup, path)
    end
    filesystem.remove(temporary)
    return nil, reason
  end
  if filesystem.exists(backup) then
    filesystem.remove(backup)
  end
  return true
end

function config.applyDefaults(value)
  value.scanInterval = tonumber(value.scanInterval) or 2
  value.shutdownDelay = tonumber(value.shutdownDelay) or 1.1
  value.coolantMinimumRemaining = tonumber(value.coolantMinimumRemaining) or 0.25
  value.coolantFreshRemaining = tonumber(value.coolantFreshRemaining) or 0.95
  value.fuelFreshRemaining = tonumber(value.fuelFreshRemaining) or 0.99
  value.maximumHeatFraction = tonumber(value.maximumHeatFraction) or 0.50
  value.watchdogInterval = tonumber(value.watchdogInterval) or 1
  value.autoArm = value.autoArm == true
  value.reactors = value.reactors or {}
  return value
end

return config
