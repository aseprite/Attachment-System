-- Aseprite Immediate Mode GUI library
-- Copyright (c) 2022  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

local imi = {
  dlg = nil,
  mousePos = Point(0, 0),
  mouseButton = 0,
  widgets = {},
  capturedWidget = nil,
  drawList = {},
  lineHeight = 0,
}

----------------------------------------------------------------------
-- Internal Implementation Details
----------------------------------------------------------------------

local WidgetFlags = {
  PRESSED = 1,
  DISABLED = 2,
  FOCUSED = 4,
  CHECKED = 8,
  HOVER = 16,
}

local function clamp(value, min, max)
  return math.max(min, math.min(value, max))
end

-- Reset these variables before calling ongui()
local function initVars(ctx)
  imi.ctx = ctx
  imi.lineHeight = ctx:measureText(" ").height
  imi.mouseCursor = MouseCursor.ARROW
  imi.cursor = Point(0, 0)
  imi.rowHeight = 0
  imi.sameLine = false
  imi.breakLines = true
  imi.viewport = Rectangle(0, 0, ctx.width, ctx.height)
  imi.idStack = {}
  imi.layoutStack = {}
  imi.lastID = nil -- Last inserted widget ID

  -- List of widget IDs inside mousePos, useful to send mouse events
  -- in order, the order in this table is from from the backmost
  -- widget to the frontmost one, but it's iterated reversely to go
  -- from front to back.
  imi.mouseWidgets = {}
end

local function hasFlags(widget, flags)
  return widget.flags and ((widget.flags & flags) == flags)
end

local function setFlags(widget, flags)
  if widget.flags == nil then
    widget.flags = flags
  else
    widget.flags = widget.flags | flags
  end
end

local function resetFlags(widget, flags)
  if widget.flags == nil then
    widget.flags = 0
  else
    widget.flags = widget.flags & ~flags
  end
end

local function xorFlags(widget, flags)
  if widget.flags == nil then
    widget.flags = flags
  else
    widget.flags = widget.flags ~ flags
  end
end

-- Last inserted widget getters/setters accessible through imi.widget
local flagNames = {
  pressed=WidgetFlags.PRESSED,
  disabled=WidgetFlags.DISABLED,
  focused=WidgetFlags.FOCUSED,
  checked=WidgetFlags.CHECKED,
  hover=WidgetFlags.HOVER,
}
local widgetMt = {
  __index=function(t, field)
    local widget = imi.widgets[imi.lastID]
    local flag = flagNames[field]
    return hasFlags(widget, flag)
  end,
  __newindex=function(t, field, value)
    local widget = imi.widgets[imi.lastID]
    local flag = flagNames[field]
    if flag then
      if value then
        setFlags(widget, flag)
      else
        resetFlags(widget, flag)
      end
    elseif field == "color" then
      widget.color = value
    end
  end
}

local function advanceCursor(size, func)
  if imi.alignRight then
    imi.cursor.x = imi.cursor.x - size.width
  end

  if not imi.sameLine or
     (imi.breakLines and
      imi.cursor.x > 0 and
      imi.cursor.x + size.width > imi.viewport.x+imi.viewport.width) then
    imi.cursor.y = imi.cursor.y + imi.rowHeight
    imi.cursor.x = imi.viewport.x
    imi.rowHeight = 0
  end

  local bounds = Rectangle(imi.cursor, size)
  func(bounds)

  if imi.scrollableBounds then
    imi.scrollableBounds = imi.scrollableBounds:union(bounds)
  end

  if imi.rowHeight < size.height then
    imi.rowHeight = size.height
  end
  imi.cursor.x = imi.cursor.x + size.width
end

local function addDrawListFunction(callback)
  table.insert(imi.drawList,
    { type="callback",
      callback=callback })
end

local function pointInsideWidgetHierarchy(widget, pos)
  while widget.bounds and
        widget.bounds:contains(imi.mousePos) do
    if widget.parent then
      widget = widget.parent
    else
      return true
    end
  end
  return false
end

local function updateWidget(id, values)
  -- Set the current viewport (or nil) as the parent of this widget
  -- TODO generalize this to any kind of container widget
  values.parent = imi.viewportWidget

  if imi.widgets[id] then
    for k,v in pairs(values) do
      imi.widgets[id][k] = v
    end
  else
    imi.widgets[id] = values
  end

  -- Add this widget to the list of mouseWidgets if it's in mousePos
  if pointInsideWidgetHierarchy(imi.widgets[id], imi.mousePos) then
    table.insert(imi.mouseWidgets, id)
  end
end

local dragStartMousePos = Point(0, 0)
local dragStartScrollPos = Point(0, 0)
local dragStartScrollBarPos = 0

local function getScrollInfo(widget)
  local fullLen = widget.viewportSize.width-4
  local len = fullLen
  local pos = widget.scrollPos.x
  if widget.scrollableSize.width <= widget.viewportSize.width then
    pos = 0
  elseif widget.scrollableSize.width > 0 then
    len = fullLen * widget.viewportSize.width / widget.scrollableSize.width
    len = clamp(len, app.theme.dimension.scrollbar_size, fullLen)
    pos = (fullLen-len) * pos / (widget.scrollableSize.width-widget.viewportSize.width)
    pos = clamp(pos, 0, fullLen-len)
  else
    len = 0
    pos = 0
  end
  return { fullLen=fullLen, len=len, pos=pos }
end

local function insideViewport(bounds)
  return
    not imi.viewportWidget or
    imi.viewportWidget.bounds:intersects(bounds)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

imi.widget = {}
setmetatable(imi.widget, widgetMt)

imi.init = function(values)
  imi.dlg = values.dialog
  imi.ongui = values.ongui
  imi.canvasId = values.canvas
end

imi.onpaint = function(ev)
  local ctx = ev.context
  initVars(ctx)

  if imi.ongui then
    imi.ongui()
  end

  if imi.canvasId then
    imi.dlg:modify{ id=imi.canvasId, mouseCursor=imi.mouseCursor }
  end

  for i,cmd in ipairs(imi.drawList) do
    if cmd.type == "callback" then
      cmd.callback(ctx)
    elseif cmd.type == "save" then
      ctx:save()
    elseif cmd.type == "restore" then
      ctx:restore()
    elseif cmd.type == "clip" then
      ctx:rect(cmd.bounds)
      ctx:clip()
    end
  end
  imi.drawList = {}
end

imi.onmousemove = function(ev)
  imi.mousePos = Point(ev.x, ev.y)
  imi.mouseButton = ev.button

  local repaint = false
  for id,widget in pairs(imi.widgets) do
    if widget.bounds then
      if widget.onmousemove then
        widget.onmousemove()
      end
      if pointInsideWidgetHierarchy(widget, imi.mousePos) then
        if not hasFlags(widget, WidgetFlags.HOVER) then
          setFlags(widget, WidgetFlags.HOVER)
          repaint = true
        end
      elseif hasFlags(widget, WidgetFlags.HOVER) then
        resetFlags(widget, WidgetFlags.HOVER)
        repaint = true
      end
    end
  end
  if repaint then
    imi.dlg:repaint()
  end

  imi.dlg:modify{ id="canvas", mouseCursor=imi.mouseCursor }
end

imi.onmousedown = function(ev)
  imi.mousePos = Point(ev.x, ev.y)
  imi.mouseButton = ev.button

  for _,id in ipairs(imi.mouseWidgets) do
    local widget = imi.widgets[id]
    if widget.onmousedown then
      widget.onmousedown()
    end
    if ev.button == MouseButton.LEFT then
      if hasFlags(widget, WidgetFlags.HOVER) then
        imi.capturedWidget = widget
        setFlags(widget, WidgetFlags.PRESSED)
        imi.dlg:repaint()
      end
    end
  end
end

imi.onmouseup = function(ev)
  imi.mousePos = Point(ev.x, ev.y)
  imi.mouseButton = 0
  if imi.capturedWidget then
    local widget = imi.capturedWidget
    if widget.onmouseup then
      widget.onmouseup()
    end
    if hasFlags(widget, WidgetFlags.PRESSED) then
      resetFlags(widget, WidgetFlags.PRESSED)
      xorFlags(widget, WidgetFlags.CHECKED)
      imi.dlg:repaint()
    end
    imi.capturedWidget = nil
  end

  imi.dlg:modify{ id="canvas", mouseCursor=imi.mouseCursor }
end

imi.pushID = function(id)
  table.insert(imi.idStack, id)
end

imi.popID = function()
  table.remove(imi.idStack)
end

imi.getID = function()
  local id = debug.getinfo(3, "l").currentline
  if #imi.idStack > 0 then
    id = id + 100000*imi.idStack[#imi.idStack]
  end
  imi.lastID = id
  return id
end

imi.space = function(width)
  advanceCursor(
    Size(width, 1),
    function(bounds)
      -- Do nothing
    end)
end

imi.label = function(text)
  local id = imi.getID()
  local textSize = imi.ctx:measureText(text)
  advanceCursor(
    textSize,
    function(bounds)
      updateWidget(id, { bounds=bounds })

      addDrawListFunction(
        function(ctx)
          if imi.widgets[id].color then
            ctx.color = imi.widgets[id].color
          end
          ctx:fillText(text, bounds.x, bounds.y)
        end)
    end)
end

imi._toggle = function(id, text)
  local textSize = imi.ctx:measureText(text)
  local size = Size(textSize.width+32, textSize.height+8)
  advanceCursor(
    size,
    function(bounds)
      updateWidget(id, { bounds=bounds })
      addDrawListFunction(
        function(ctx)
          local widget = imi.widgets[id]
          local partId
          if hasFlags(widget, WidgetFlags.PRESSED) or
             hasFlags(widget, WidgetFlags.CHECKED) then
            partId = 'button_selected'
          elseif hasFlags(widget, WidgetFlags.HOVER) then
            partId = 'button_hot'
          else
            partId = 'button_normal'
          end
          ctx:drawThemeRect(partId, bounds)
          ctx:fillText(text,
                       bounds.x+(bounds.width-textSize.width)/2,
                       bounds.y+(bounds.height-textSize.height)/2)
        end)
  end)
  return hasFlags(imi.widgets[id], WidgetFlags.CHECKED)
end

imi.toggle = function(text)
  local id = imi.getID()
  return imi._toggle(id, text)
end

imi.button = function(text)
  local id = imi.getID()
  local result = imi._toggle(id, text)
  if result then
    imi.widget.checked = false
  end
  return result
end

imi.image = function(image, srcRect, dstSize)
  local id = imi.getID()
  advanceCursor(
    dstSize,
    function(bounds)
      updateWidget(id, { bounds=bounds })

      -- Draw this widget only if it's visible through the current
      -- viewport (if we are in a viewport)
      if insideViewport(bounds) then
        addDrawListFunction(
          function()
            local widget = imi.widgets[id]
            imi.ctx:drawImage(image, srcRect, bounds)
            if hasFlags(widget, WidgetFlags.PRESSED) or
               hasFlags(widget, WidgetFlags.CHECKED) then
              imi.ctx:drawThemeRect('colorbar_selection_hot',
                                    widget.bounds)
            elseif hasFlags(widget, WidgetFlags.HOVER) then
              imi.ctx:drawThemeRect('colorbar_selection',
                                    widget.bounds)
            end
          end)
      end
    end)
  return hasFlags(imi.widgets[id], WidgetFlags.CHECKED)
end

imi.beginViewport = function(size)
  local id = imi.getID()

  local barSize = app.theme.dimension.mini_scrollbar_size
  size.height = size.height + 8 + barSize

  local function onmousemove()
    local widget = imi.widgets[id]
    local bounds = widget.bounds

    if widget.draggingHBar then
      local maxScrollPos = widget.scrollableSize - widget.viewportSize

      if widget.hoverHBar then
        local info = getScrollInfo(widget)
        local pos = dragStartScrollBarPos + (imi.mousePos - dragStartMousePos)
        pos.y = 0
        pos.x = clamp(pos.x, 0, info.fullLen - info.len)
        widget.scrollPos.x = maxScrollPos.width * pos.x / (info.fullLen - info.len)
      else
        widget.scrollPos = dragStartScrollPos + (dragStartMousePos - imi.mousePos)
      end
      widget.scrollPos.y = 0
      widget.scrollPos.x = clamp(widget.scrollPos.x, 0, maxScrollPos.width)
      imi.dlg:repaint()

      imi.mouseCursor = MouseCursor.GRABBING
    else
      local oldHoverHBar = widget.hoverHBar
      widget.hoverHBar =
        (imi.mousePos.y >= bounds.y+bounds.height-barSize-4 and
         imi.mousePos.y <= bounds.y+bounds.height)
      if oldHoverHBar ~= widget.hoverHBar then
        imi.dlg:repaint()
      end
    end
  end

  local function onmousedown()
    local widget = imi.widgets[id]
    if widget.hoverHBar or
       imi.mouseButton == MouseButton.MIDDLE then
      widget.draggingHBar = true
      imi.capturedWidget = widget
      dragStartMousePos = Point(imi.mousePos)
      dragStartScrollPos = Point(widget.scrollPos)
      dragStartScrollBarPos = getScrollInfo(widget).pos
    end
  end

  local function onmouseup()
    local widget = imi.widgets[id]
    if widget.draggingHBar then
      widget.draggingHBar = false
    end
    imi.dlg:repaint()
  end

  advanceCursor(
    size,
    function(bounds)
      updateWidget(
        id,
        { bounds=bounds,
          onmousemove=onmousemove,
          onmousedown=onmousedown,
          onmouseup=onmouseup })

      local widget = imi.widgets[id]
      if widget.draggingHBar == nil then
        widget.draggingHBar = false
      end
      if widget.scrollPos == nil then
        widget.scrollPos = Point(0, 0)
      end

      imi.viewportWidget = widget
      imi.viewport = Rectangle(bounds.x+4, bounds.y+4,
                               bounds.width-8, bounds.height-8-barSize)
    end)

  table.insert(
    imi.layoutStack,
    { cursor=Point(imi.cursor),
      drawList=imi.drawList,
      rowHeight=imi.rowHeight })

  imi.cursor = imi.viewport.origin - imi.widgets[id].scrollPos
  imi.drawList = {}
  imi.rowHeight = 0
  imi.scrollableBounds = Rectangle(imi.cursor, Size(1, 1))
end

imi.endViewport = function()
  local widget = imi.viewportWidget
  local bounds = widget.bounds
  local hover = widget.hoverHBar
  local subDrawList = imi.drawList
  imi.viewport = Rectangle(0, 0, imi.ctx.width, imi.ctx.height)

  local pop = imi.layoutStack[#imi.layoutStack]

  local barSize = app.theme.dimension.mini_scrollbar_size
  widget.scrollableSize = imi.scrollableBounds.size
  widget.viewportSize = Size(bounds.width-4,
                             bounds.height-barSize-5)

  imi.cursor = pop.cursor
  imi.drawList = pop.drawList
  imi.rowHeight = pop.rowHeight
  table.remove(imi.layoutStack)

  addDrawListFunction(
    function()
      imi.ctx:drawThemeRect('sunken_normal', bounds)

      local bgPart, thumbPart
      if hover then
        bgPart = 'mini_scrollbar_bg_hot'
        thumbPart = 'mini_scrollbar_thumb_hot'
      else
        bgPart = 'mini_scrollbar_bg'
        thumbPart = 'mini_scrollbar_thumb'
      end

      local info = getScrollInfo(widget)

      imi.ctx:drawThemeRect(bgPart,
                            bounds.x+4, bounds.y+bounds.height-barSize-4,
                            bounds.width-8, barSize)
      imi.ctx:drawThemeRect(thumbPart,
                            bounds.x+4+info.pos, bounds.y+bounds.height-barSize-5,
                            info.len, barSize)
    end)

  table.insert(imi.drawList, { type="save" })
  table.insert(imi.drawList, { type="clip",
                               bounds=Rectangle(bounds.x+4,
                                                bounds.y+4,
                                                bounds.width-8,
                                                bounds.height-8) })
  for i,cmd in ipairs(subDrawList) do
    table.insert(imi.drawList, cmd)
  end
  table.insert(imi.drawList, { type="restore" })
  imi.viewportWidget = nil
  imi.scrollableBounds = nil
end

return imi
