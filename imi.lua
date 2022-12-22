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

local WidgetFlags = {
  SELECTED = 1,
  DISABLED = 2,
  FOCUSED = 4,
  HOVER = 8,
  PRESSED = 16,
}

-- Reset these variables before calling ongui()
local function initVars(ctx)
  imi.ctx = ctx
  imi.lineHeight = ctx:measureText(" ").height
  imi.cursor = Point(0, 0)
  imi.rowHeight = 0
  imi.newLine = true
  imi.viewport = Rectangle(0, 0, ctx.width, ctx.height)
  imi.idStack = {}
  imi.layoutStack = {}
end

imi.init = function(values)
  imi.dlg = values.dialog
  imi.ongui = values.ongui
end

imi.hasFlags = function(widget, flags)
  return widget.flags and ((widget.flags & flags) == flags)
end

imi.setFlags = function(widget, flags)
  if widget.flags == nil then widget.flags = 0 end
  widget.flags = widget.flags | flags
end

imi.resetFlags = function(widget, flags)
  if widget.flags == nil then widget.flags = 0 end
  widget.flags = widget.flags & ~flags
end

imi.advanceCursor = function(size, func)
  if imi.cursor.x > 0 and
     (imi.newLine or
      imi.cursor.x + size.width > imi.viewport.x+imi.viewport.width) then
    imi.cursor.y = imi.cursor.y + imi.rowHeight
    imi.cursor.x = imi.viewport.x
    imi.rowHeight = 0
  end

  func(Rectangle(imi.cursor, size))
  if imi.rowHeight < size.height then
    imi.rowHeight = size.height
  end
  imi.cursor.x = imi.cursor.x + size.width
end

imi.forEachWidgetInPoint = function(point, func)
  for id,widget in pairs(imi.widgets) do
    if widget.bounds:contains(point) then
      func(widget)
    end
  end
end

imi.updateWidget = function(id, values)
  if imi.widgets[id] then
    for k,v in pairs(values) do
      imi.widgets[id][k] = v
    end
  else
    imi.widgets[id] = values
  end
end

imi.onpaint = function(ev)
  local ctx = ev.context
  initVars(ctx)

  if imi.ongui then
    imi.ongui()
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
      if widget.bounds:contains(imi.mousePos) then
        if not imi.hasFlags(widget, WidgetFlags.HOVER) then
          imi.setFlags(widget, WidgetFlags.HOVER)
          repaint = true
        end
      elseif imi.hasFlags(widget, WidgetFlags.HOVER) then
        imi.resetFlags(widget, WidgetFlags.HOVER)
        repaint = true
      end
    end
  end
  if repaint then
    imi.dlg:repaint()
  end
end

imi.onmousedown = function(ev)
  imi.mousePos = Point(ev.x, ev.y)
  imi.mouseButton = ev.button
  imi.forEachWidgetInPoint(
    imi.mousePos,
    function(widget)
      if imi.hasFlags(widget, WidgetFlags.HOVER) then
        imi.setFlags(widget, WidgetFlags.SELECTED)
        imi.dlg:repaint()
      end
      imi.capturedWidget = widget
    end)
end

imi.onmouseup = function(ev)
  imi.mousePos = Point(ev.x, ev.y)
  imi.mouseButton = 0
  if imi.capturedWidget then
    local widget = imi.capturedWidget
    if imi.hasFlags(widget, WidgetFlags.SELECTED) then
      imi.resetFlags(widget, WidgetFlags.SELECTED)

      if not imi.hasFlags(widget, WidgetFlags.PRESSED) then
        imi.setFlags(widget, WidgetFlags.PRESSED)
      else
        imi.resetFlags(widget, WidgetFlags.PRESSED)
      end
      imi.dlg:repaint()
    end
    imi.capturedWidget = nil
  end
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
  return id
end

imi.label = function(text)
  local id = imi.getID()
  local textSize = imi.ctx:measureText(text)
  imi.advanceCursor(
    textSize,
    function(bounds)
      table.insert(
        imi.drawList,
        { type="callback",
          callback=function(ctx)
            ctx:fillText(text, bounds.x, bounds.y)
          end })
    end)
end

imi.toggle = function(text)
  local id = imi.getID()
  local textSize = imi.ctx:measureText(text)
  local size = Size(textSize.width+32, textSize.height+8)
  imi.advanceCursor(
    size,
    function(bounds)
      imi.updateWidget(id, { bounds=bounds })
      table.insert(
        imi.drawList,
        { type="callback",
          callback=function(ctx)
            local widget = imi.widgets[id]
            local partId
            if imi.hasFlags(widget, WidgetFlags.SELECTED) or
               imi.hasFlags(widget, WidgetFlags.PRESSED) then
              partId = 'button_selected'
            elseif imi.hasFlags(widget, WidgetFlags.HOVER) then
              partId = 'button_hot'
            else
              partId = 'button_normal'
            end
            ctx:drawThemeRect(partId, bounds)
            ctx:fillText(text,
                         bounds.x+(bounds.width-textSize.width)/2,
                         bounds.y+(bounds.height-textSize.height)/2)
          end })
  end)
  return imi.hasFlags(imi.widgets[id], WidgetFlags.PRESSED)
end

imi.image = function(image, srcRect, dstSize)
  local id = imi.getID()
  imi.advanceCursor(
    dstSize,
    function(bounds)
      imi.updateWidget(id, { bounds=bounds })
      table.insert(
        imi.drawList,
        { type="callback",
          callback=function()
            imi.ctx:drawImage(image, srcRect, bounds)
          end })
    end)
end

imi.beginViewport = function(size)
  local id = imi.getID()
  imi.advanceCursor(
    size,
    function(bounds)
      imi.updateWidget(id, { bounds=bounds })
      imi.viewportWidget = imi.widgets[id]
      imi.viewport = Rectangle(bounds.x+2, bounds.y+2,
                               bounds.width-4, bounds.height-4)
    end)

  table.insert(
    imi.layoutStack,
    { cursor=Point(imi.cursor),
      drawList=imi.drawList,
      rowHeight=imi.rowHeight })

  imi.cursor = imi.viewport.origin
  imi.drawList = {}
  imi.rowHeight = 0
end

imi.endViewport = function()
  local bounds = imi.viewportWidget.bounds
  local subDrawList = imi.drawList
  imi.viewport = Rectangle(0, 0, imi.ctx.width, imi.ctx.height)

  local pop = imi.layoutStack[#imi.layoutStack]
  imi.cursor = pop.cursor
  imi.drawList = pop.drawList
  imi.rowHeight = pop.rowHeight
  table.remove(imi.layoutStack)

  table.insert(
    imi.drawList,
    { type="callback",
      callback=function()
        imi.ctx:drawThemeRect('sunken_normal', bounds)
  end })

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
end

return imi
