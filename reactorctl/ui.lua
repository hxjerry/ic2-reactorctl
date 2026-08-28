local UI = {}
UI.__index = UI

local COLORS = {
  background = 0x101318,
  foreground = 0xD8DEE9,
  muted = 0x7F8C9F,
  good = 0x7BD88F,
  warning = 0xFFD866,
  bad = 0xFF6188,
  accent = 0x78DCE8,
}

local STATE_COLORS = {
  RUNNING = COLORS.good,
  NO_FUEL = COLORS.warning,
  STOPPING = COLORS.warning,
  COOLANT = COLORS.warning,
  BLOCKED = COLORS.bad,
  FAULT = COLORS.bad,
  DISARMED = COLORS.muted,
  VERIFYING = COLORS.accent,
}

local function clip(text, width)
  text = tostring(text or "")
  if #text > width then
    return text:sub(1, math.max(0, width - 1)) .. "~"
  end
  return text
end

function UI.new(component)
  local self = setmetatable({}, UI)
  self.enabled = component.isAvailable("gpu") and component.isAvailable("screen")
  self.previous = {}
  if not self.enabled then
    return self
  end

  self.gpu = component.gpu
  local maxWidth, maxHeight = self.gpu.maxResolution()
  self.width = math.min(maxWidth, 100)
  self.height = math.min(maxHeight, 32)
  pcall(self.gpu.setResolution, self.width, self.height)
  local maxDepth = self.gpu.maxDepth()
  if maxDepth >= 8 then
    pcall(self.gpu.setDepth, 8)
  elseif maxDepth >= 4 then
    pcall(self.gpu.setDepth, 4)
  end
  self.gpu.setBackground(COLORS.background)
  self.gpu.setForeground(COLORS.foreground)
  self.gpu.fill(1, 1, self.width, self.height, " ")
  return self
end

function UI:setLine(row, text, foreground, background)
  if not self.enabled or row < 1 or row > self.height then
    return
  end
  text = clip(text, self.width)
  foreground = foreground or COLORS.foreground
  background = background or COLORS.background
  local key = string.format("%06x:%06x:%s", foreground, background, text)
  if self.previous[row] == key then
    return
  end
  self.previous[row] = key
  self.gpu.setBackground(background)
  self.gpu.setForeground(foreground)
  self.gpu.fill(1, row, self.width, 1, " ")
  self.gpu.set(1, row, text)
end

function UI:render(snapshot)
  if not self.enabled then
    return
  end

  self:setLine(
    1,
    string.format(
      " Reactor Controller   armed=%s   watchdog=%s   [A] arm/disarm [R] reset faults [Q] quit",
      snapshot.armed and "YES" or "NO",
      snapshot.watchdogLevel ~= 0 and "pulse" or "idle"
    ),
    snapshot.armed and COLORS.good or COLORS.warning
  )
  self:setLine(2, string.rep("-", self.width), COLORS.muted)
  self:setLine(
    3,
    string.format(" %-10s %-11s %8s %12s  %s", "Reactor", "State", "Heat", "EU/t", "Reason"),
    COLORS.accent
  )

  local row = 4
  for _, reactor in ipairs(snapshot.reactors) do
    if row > self.height - 5 then
      break
    end
    local heat = "--"
    if reactor.maxHeat and reactor.maxHeat > 0 then
      heat = string.format("%6.1f%%", 100 * reactor.heat / reactor.maxHeat)
    end
    local output = string.format("%10.1f", tonumber(reactor.output) or 0)
    local line = string.format(
      " %-10s %-11s %8s %12s  %s",
      clip(reactor.name, 10),
      clip(reactor.state, 11),
      heat,
      output,
      reactor.reason or ""
    )
    self:setLine(row, line, STATE_COLORS[reactor.state] or COLORS.foreground)
    row = row + 1
  end

  while row <= self.height - 5 do
    self:setLine(row, "")
    row = row + 1
  end

  self:setLine(self.height - 4, string.rep("-", self.width), COLORS.muted)
  self:setLine(self.height - 3, " Recent events", COLORS.accent)
  local logStart = math.max(1, #snapshot.logs - 1)
  local targetRow = self.height - 2
  for index = logStart, #snapshot.logs do
    local entry = snapshot.logs[index]
    local color = entry.level == "ERROR" and COLORS.bad or (entry.level == "WARN" and COLORS.warning or COLORS.muted)
    self:setLine(targetRow, string.format(" %7.2f %-5s %s", entry.time, entry.level, entry.message), color)
    targetRow = targetRow + 1
  end
  while targetRow <= self.height do
    self:setLine(targetRow, "")
    targetRow = targetRow + 1
  end
end

function UI:close()
  if not self.enabled then
    return
  end
  self.gpu.setBackground(0x000000)
  self.gpu.setForeground(0xFFFFFF)
  self.gpu.fill(1, 1, self.width, self.height, " ")
end

return UI
