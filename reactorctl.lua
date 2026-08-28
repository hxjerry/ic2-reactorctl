package.path = "/home/?.lua;/home/?/init.lua;" .. package.path

local component = require("component")
local computer = require("computer")
local event = require("event")

local configStore = require("reactorctl.config")
local Controller = require("reactorctl.controller")
local UI = require("reactorctl.ui")

local configPath = (...) or configStore.DEFAULT_PATH
local configuration, configError = configStore.load(configPath)
if not configuration then
  io.stderr:write(configError .. "\n")
  io.stderr:write("Run reactorctl_setup.lua before starting the controller.\n")
  return
end
configuration = configStore.applyDefaults(configuration)

local controller = Controller.new(configuration, {
  component = component,
  computer = computer,
})
local initialized, initializeError = controller:initialize()
if not initialized then
  controller:shutdown()
  io.stderr:write("Initialization failed: " .. tostring(initializeError) .. "\n")
  return
end

local uiOk, ui = pcall(UI.new, component)
if not uiOk then
  controller:log("WARN", "dashboard disabled: " .. tostring(ui))
  ui = {
    render = function() end,
    close = function() end,
  }
end
local uiEnabled = uiOk
local running = true
local nextRender = 0

if configuration.autoArm then
  controller:setArmed(true)
end

local function handleEvent(name, ...)
  if name == "interrupted" or name == "reactorctl_stop" then
    running = false
    return
  end
  if name ~= "key_down" then
    return
  end
  local _, character = ...
  if character == string.byte("q") or character == string.byte("Q") then
    running = false
  elseif character == string.byte("a") or character == string.byte("A") then
    controller:setArmed(not controller.armed)
  elseif character == string.byte("r") or character == string.byte("R") then
    controller:resetFaults()
  end
end

local function run()
  while running do
    local now = computer.uptime()
    controller:step(now)
    if now >= nextRender then
      if uiEnabled then
        local rendered, renderError = pcall(ui.render, ui, controller:snapshot())
        if not rendered then
          uiEnabled = false
          controller:log("WARN", "dashboard disabled: " .. tostring(renderError))
        end
      end
      nextRender = now + 0.5
    end
    handleEvent(event.pull(0.05))
  end
end

local ok, reason = xpcall(run, debug.traceback)
controller:shutdown()
pcall(ui.close, ui)

if not ok then
  io.stderr:write(tostring(reason) .. "\n")
end
