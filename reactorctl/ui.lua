local UI = {}
UI.__index = UI

local RGB = {
  background = 0x101318,
  foreground = 0xD8DEE9,
  muted = 0x7F8C9F,
  good = 0x7BD88F,
  warning = 0xFFD866,
  bad = 0xFF6188,
  accent = 0x78DCE8,
}

local PALETTE_INDEX = {
  background = 0,
  foreground = 15,
  muted = 8,
  good = 10,
  warning = 14,
  bad = 12,
  accent = 11,
}

local STATE_COLORS = {
  RUNNING = "good",
  NO_FUEL = "warning",
  STOPPING = "warning",
  COOLANT = "warning",
  BLOCKED = "bad",
  FAULT = "bad",
  DISARMED = "muted",
  VERIFYING = "accent",
}

local function clip(text, width)
  text = tostring(text or "")
  if #text > width then
    return text:sub(1, math.max(0, width - 1)) .. "~"
  end
  return text
end

local function formatColumns(self, name, state, heat, output, reason)
  local fixedWidth = self.nameWidth + self.stateWidth + self.heatWidth + self.outputWidth + 4
  local reasonWidth = math.max(1, self.width - fixedWidth)
  local format = string.format(
    "%%-%ds %%-%ds %%%ds %%%ds %%s",
    self.nameWidth,
    self.stateWidth,
    self.heatWidth,
    self.outputWidth
  )
  return string.format(
    format,
    clip(name, self.nameWidth),
    clip(state, self.stateWidth),
    clip(heat, self.heatWidth),
    clip(output, self.outputWidth),
    clip(reason, reasonWidth)
  )
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
  if self.width < 30 or self.height < 8 then
    error(string.format("screen is too small: %dx%d", self.width, self.height))
  end
  self.gpu.setResolution(self.width, self.height)

  self.depth = self.gpu.maxDepth()
  if self.depth >= 8 then
    self.depth = 8
  elseif self.depth >= 4 then
    self.depth = 4
  else
    self.depth = 1
  end
  self.gpu.setDepth(self.depth)

  self.colors = {}
  if self.depth == 4 then
    for name, index in pairs(PALETTE_INDEX) do
      self.gpu.setPaletteColor(index, RGB[name])
      self.colors[name] = {value = index, palette = true}
    end
  elseif self.depth == 1 then
    self.colors.background = {value = 0x000000, palette = false}
    for name in pairs(RGB) do
      self.colors[name] = self.colors[name] or {value = 0xFFFFFF, palette = false}
    end
  else
    for name, value in pairs(RGB) do
      self.colors[name] = {value = value, palette = false}
    end
  end

  self.nameWidth = self.width >= 70 and 10 or 8
  self.stateWidth = self.width >= 70 and 11 or 8
  self.heatWidth = self.width >= 70 and 7 or 6
  self.outputWidth = self.width >= 70 and 10 or 7

  self:setColors("foreground", "background")
  self.gpu.fill(1, 1, self.width, self.height, " ")
  return self
end

function UI:setColors(foreground, background)
  local foregroundColor = self.colors[foreground or "foreground"]
  local backgroundColor = self.colors[background or "background"]
  self.gpu.setBackground(backgroundColor.value, backgroundColor.palette)
  self.gpu.setForeground(foregroundColor.value, foregroundColor.palette)
end

function UI:setLine(row, text, foreground, background)
  if not self.enabled or row < 1 or row > self.height then
    return
  end
  text = clip(text, self.width)
  foreground = foreground or "foreground"
  background = background or "background"
  local key = foreground .. ":" .. background .. ":" .. text
  if self.previous[row] == key then
    return
  end
  self.previous[row] = key
  self:setColors(foreground, background)
  self.gpu.fill(1, row, self.width, 1, " ")
  self.gpu.set(1, row, text)
end

function UI:setSegments(row, segments)
  if not self.enabled or row < 1 or row > self.height then
    return
  end

  local remaining = self.width
  local parts = {}
  local keyParts = {}
  for _, segment in ipairs(segments) do
    if remaining > 0 then
      local text = clip(segment.text, remaining)
      parts[#parts + 1] = {text = text, color = segment.color or "foreground"}
      keyParts[#keyParts + 1] = parts[#parts].color .. ":" .. text
      remaining = remaining - #text
    end
  end
  local key = table.concat(keyParts, "|")
  if self.previous[row] == key then
    return
  end
  self.previous[row] = key

  self:setColors("foreground", "background")
  self.gpu.fill(1, row, self.width, 1, " ")
  local column = 1
  for _, part in ipairs(parts) do
    self:setColors(part.color, "background")
    self.gpu.set(column, row, part.text)
    column = column + #part.text
  end
end

function UI:render(snapshot)
  if not self.enabled then
    return
  end

  self:setSegments(1, {
    {text = "ReactorCtl "},
    {text = snapshot.armed and "[A]ON" or "[A]OFF", color = snapshot.armed and "good" or "warning"},
    {text = " [R]eset [Q]uit ", color = "muted"},
    {text = snapshot.watchdogLevel ~= 0 and "*" or " ", color = "accent"},
  })
  self:setLine(
    2,
    formatColumns(self, "Reactor", "State", "Heat", "EU/t", "Reason"),
    "accent"
  )

  local separatorRow = self.height - 2
  local row = 3
  for _, reactor in ipairs(snapshot.reactors) do
    if row >= separatorRow then
      break
    end
    local heat = "--"
    if reactor.maxHeat and reactor.maxHeat > 0 then
      heat = string.format("%.1f%%", 100 * reactor.heat / reactor.maxHeat)
    end
    local output = string.format("%.1f", tonumber(reactor.output) or 0)
    self:setLine(
      row,
      formatColumns(self, reactor.name, reactor.state, heat, output, reactor.reason or ""),
      STATE_COLORS[reactor.state] or "foreground"
    )
    row = row + 1
  end

  while row < separatorRow do
    self:setLine(row, "")
    row = row + 1
  end

  self:setLine(separatorRow, string.rep("-", self.width), "muted")
  local logRows = 2
  local logStart = math.max(1, #snapshot.logs - logRows + 1)
  local targetRow = separatorRow + 1
  for index = logStart, #snapshot.logs do
    local entry = snapshot.logs[index]
    local color = entry.level == "ERROR" and "bad" or (entry.level == "WARN" and "warning" or "muted")
    self:setLine(
      targetRow,
      string.format("%6.1f %s %s", entry.time, entry.level:sub(1, 1), entry.message),
      color
    )
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
  self:setColors("foreground", "background")
  self.gpu.fill(1, 1, self.width, self.height, " ")
end

return UI
