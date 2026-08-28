local event = require("event")

local thread
local worker

function start()
  if worker and worker:status() ~= "dead" then
    return
  end
  thread = thread or require("thread")
  worker = thread.create(function()
    local ok, reason = pcall(dofile, "/home/reactorctl.lua")
    if not ok then
      io.stderr:write("reactorctl service failed: " .. tostring(reason) .. "\n")
    end
  end):detach()
end

function stop()
  if worker and worker:status() ~= "dead" then
    event.push("reactorctl_stop")
    local stopped = worker:join(5)
    if not stopped and worker:status() ~= "dead" then
      return nil, "reactorctl did not stop within five seconds; outputs were not force-killed"
    end
  end
  worker = nil
  return true
end
