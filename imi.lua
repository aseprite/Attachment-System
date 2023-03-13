-- Aseprite Immediate Mode GUI library
-- Copyright (c) 2022-2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.
----------------------------------------------------------------------
-- Reference:
--
-- Initialization of the imi library:
--
--   imi.init{
--     dialog=Dialog(...)
--            :canvas{
--               id="myCanvas",
--               onpaint=imi.onpaint,
--               onmousemove=imi.onmousemove,
--               onmousedown=imi.onmousedown,
--               onmouseup=imi.onmouseup },
--     ongui=my_ongui,
--     canvas="myCanvas" }
--
-- Widgets:
--
--   imi.label("Text")
--   imi.image(image, srcRect, dstSize)
--   imi.beginViewport(visibleAreaSize, itemSize)
--   imi.endViewport()
--
-- Drag-and-drop:
--
--   -- ...After creating a specific widget that can be dragged...
--   if imi.beginDrag() then
--     imi.setDragData("dataType", data)
--   end
--
--   -- ...After creating a specific widget where we can drop data...
--   if imi.beginDrop() then
--     local data = imi.getDropData("dataType")
--     if data then
--       ...
--     end
--     imi.endDrop()
--   end
--
----------------------------------------------------------------------

local imi = {
  dlg = nil,
  uiScale = app.preferences.general.ui_scale,
  mousePos = Point(0, 0),
  mouseButton = 0,
  widgets = {},
  focusedWidget = nil,  -- Widget with keyboard focus
  capturedWidget = nil, -- Captured widget (when we pressed and are dragging the mouse)
  draggingWidget = nil, -- Widget being dragged
  targetWidget = nil,   -- Where we drop the capturedWidget
  highlightDropItemPos = nil,  -- Column/Row position of a item dropped inside a viewport with itemSize
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
  DRAGGING = 32,
  HAS_HBAR = 64,
  HAS_VBAR = 128,
  WANTS_FOCUS = 256,
}

-- Reset these variables before calling ongui()
local function initVars(ctx)
  imi.ctx = ctx
  imi.uiScale = app.preferences.general.ui_scale
  imi.lineHeight = ctx:measureText(" ").height
  imi.mouseCursor = MouseCursor.ARROW
  imi.cursor = Point(0, 0)
  imi.rowHeight = 0
  imi.sameLine = false
  imi.breakLines = true
  imi.viewport = Rectangle(0, 0, ctx.width, ctx.height)
  imi.viewportStack = {}
  imi.idStack = {}
  imi.layoutStack = {}
  imi.groupsStack = {}
  imi.beforePaint = {}
  imi.afterPaint = {}
  imi.lastBounds = nil
  imi.repaint = false
  imi.margin = 4*imi.uiScale

  -- List of widget IDs inside mousePos, useful to send mouse events
  -- in order, the order in this table is from the backmost
  -- widget to the frontmost one, but it's iterated reversely to go
  -- from front to back.
  imi.mouseWidgets = {}
  imi.mouseWidgetCandidates = {}
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

-- Last inserted widget getters/setters accessible through imi.widget
local flagNames = {
  pressed=WidgetFlags.PRESSED,
  disabled=WidgetFlags.DISABLED,
  focused=WidgetFlags.FOCUSED,
  checked=WidgetFlags.CHECKED,
  hover=WidgetFlags.HOVER,
  dragging=WidgetFlags.DRAGGING,
  hasHBar=WidgetFlags.HAS_HBAR,
  hasVBar=WidgetFlags.HAS_VBAR,
  wantsFocus=WidgetFlags.WANTS_FOCUS,
}
local widgetMt = {
  __index=function(widget, field)
    local flag = flagNames[field]
    if flag then
      return hasFlags(widget, flag)
    else
      return rawget(widget, field)
    end
  end,
  __newindex=function(widget, field, value)
    local flag = flagNames[field]
    if flag then
      if value then
        setFlags(widget, flag)
      else
        resetFlags(widget, flag)
      end
    else
      rawset(widget, field, value)
    end
  end
}

local function advanceCursor(size, func)
  local oldCursor = imi.cursor
  if imi.alignFunc then
    imi.cursor = imi.alignFunc(imi.cursor, size, imi.lastBounds)
  end

  if not imi.sameLine or
     (imi.breakLines and
      imi.cursor.x > imi.viewport.x and
      imi.cursor.x + size.width > imi.viewport.x+imi.viewport.width) then
    imi.cursor.y = imi.cursor.y + imi.rowHeight + imi.margin
    imi.cursor.x = imi.viewport.x
    imi.rowHeight = 0
  end

  local bounds = Rectangle(imi.cursor, size)
  func(bounds)

  if #imi.groupsStack > 0 then
    local top = imi.groupsStack[#imi.groupsStack]
    table.insert(top.widgets, imi.widget)
  end

  if imi.scrollableBounds then
    imi.scrollableBounds = imi.scrollableBounds:union(bounds)
  end

  if imi.rowHeight < size.height then
    imi.rowHeight = size.height
  end

  -- Restore the old cursor position if we've used a customized
  -- alignment function
  if imi.alignFunc then
    imi.cursor = oldCursor
  -- In other way just advance the cursor to the next position (in the
  -- same row)
  else
    -- Update last bounds only when a custom alignment function is not
    -- used
    imi.lastBounds = bounds
    imi.cursor.x = imi.cursor.x + size.width + imi.margin
  end
end

local function addDrawListFunction(callback)
  table.insert(imi.drawList,
    { type="callback",
      callback=callback })
end

local function addBeforePaint(callback)
  table.insert(imi.beforePaint, callback)
end

local function addAfterPaint(callback)
  table.insert(imi.afterPaint, callback)
end

local function pointInsideWidgetHierarchy(widget, pos)
  while widget.bounds and
        widget.bounds:contains(pos) do
    if widget.parent then
      widget = widget.parent
    else
      return true
    end
  end
  return false
end

local function updateWidget(id, values)
  values.id = id

  -- Set the current viewport (or nil) as the parent of this widget
  -- TODO generalize this to any kind of container widget
  values.parent = imi.viewportWidget

  local widget = imi.widgets[id]
  if not widget then
    widget = {}
    -- TODO we should check the performance of using this metatable
    --      and see if it's really worth it
    setmetatable(widget, widgetMt)
    imi.widgets[id] = widget
  end
  for k,v in pairs(values) do
    widget[k] = v
  end

  -- Add this widget to the list of possible candidates for the mouseWidgets
  table.insert(imi.mouseWidgetCandidates, widget)

  imi.widget = widget
  return widget
end

local dragStartMousePos = Point(0, 0)
local dragStartScrollPos = Point(0, 0)
local dragStartScrollBarPos = 0
local dragStartViewportSize = Size(0, 0)

local function setupScrollbars(widget, barSize)
  local fullViewportSize = Size(widget.viewportSize)

  local function needHBar()
    return
      ((widget.scrollableSize.width > widget.viewportSize.width) and
       (barSize < fullViewportSize.width) and
       (barSize < fullViewportSize.height))
  end

  local function needVBar()
    return
      ((widget.scrollableSize.height > widget.viewportSize.height) and
       (barSize < fullViewportSize.width) and
       (barSize < fullViewportSize.height))
  end

  widget.hasHBar = false
  widget.hasVBar = false

  if needHBar() then
    widget.viewportSize.height = widget.viewportSize.height - barSize
    widget.hasHBar = true

    if needVBar() then
      widget.viewportSize.width = widget.viewportSize.width - barSize
      if needHBar() then
        widget.hasVBar = true
      else
        widget.hasHBar = false
        widget.viewportSize = Size(fullViewportSize)
      end
    else
    end
  elseif needVBar() then
    widget.viewportSize.width = widget.viewportSize.width - barSize
    widget.hasVBar = true

    if needHBar() then
      widget.viewportSize.height = widget.viewportSize.height - barSize
      if needVBar() then
        widget.hasHBar = true
      else
        widget.hasVBar = false
        widget.viewportSize = Size(fullViewportSize)
      end
    end
  end

  -- Clamp scroll pos with the new scrollableSize and viewportSize
  widget.setScrollPos(widget.scrollPos)
end

local function getHScrollInfo(widget)
  local fullLen = widget.viewportSize.width-3*imi.uiScale
  local len = fullLen
  local pos = widget.scrollPos.x
  if widget.scrollableSize.width <= widget.viewportSize.width then
    pos = 0
  elseif widget.scrollableSize.width > 0 then
    len = fullLen * widget.viewportSize.width / widget.scrollableSize.width
    len = imi.clamp(len, app.theme.dimension.scrollbar_size, fullLen)
    pos = (fullLen-len) * pos / (widget.scrollableSize.width-widget.viewportSize.width)
    pos = imi.clamp(pos, 0, fullLen-len)
  else
    len = 0
    pos = 0
  end
  return { fullLen=fullLen, len=len, pos=pos }
end

local function getVScrollInfo(widget)
  local fullLen = widget.viewportSize.height-3*imi.uiScale
  local len = fullLen
  local pos = widget.scrollPos.y
  if widget.scrollableSize.height <= widget.viewportSize.height then
    pos = 0
  elseif widget.scrollableSize.height > 0 then
    len = fullLen * widget.viewportSize.height / widget.scrollableSize.height
    len = imi.clamp(len, app.theme.dimension.scrollbar_size, fullLen)
    pos = (fullLen-len) * pos / (widget.scrollableSize.height-widget.viewportSize.height)
    pos = imi.clamp(pos, 0, fullLen-len)
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

function imi.clamp(value, min, max)
  if value == nil then value = min end
  return math.max(min, math.min(value, max))
end

function imi.init(values)
  imi.dlg = values.dialog
  imi.ongui = values.ongui
  imi.canvasId = values.canvas
  imi.widget = nil
  if imi.draggingWidget then
    imi.draggingWidget.dragging = false
    imi.draggingWidget = nil
  end
end

function imi.focusWidget(widget)
  if imi.focusedWidget then
    imi.focusedWidget.focused = false
    imi.focusedWidget = nil
  end
  imi.focusedWidget = widget
  if imi.focusedWidget then
    imi.focusedWidget.focused = true
  end
end

function imi.onpaint(ev)
  local ctx = ev.context

  imi.repaint = true
  while imi.repaint do
    initVars(ctx) -- set imi.repaint=false

    if imi.ongui then
      local hadTargetWidget = (imi.targetWidget ~= nil)

      imi.isongui = true
      imi.ongui()
      imi.isongui = false

      -- Build mouseWidgets collection (using its final bounds
      -- position)
      for _,widget in ipairs(imi.mouseWidgetCandidates) do
        if not widget.dragging and
           pointInsideWidgetHierarchy(widget, imi.mousePos) then
          table.insert(imi.mouseWidgets, widget)
        end
      end

      if hadTargetWidget then
        imi.targetWidget = nil
      end
    end

    for _,f in ipairs(imi.beforePaint) do
      f()
    end
    imi.beforePaint = {}

    if imi.canvasId then
      imi.dlg:modify{ id=imi.canvasId, mouseCursor=imi.mouseCursor }
    end

    if imi.repaint then
      -- Discard the whole drawList as we're going to repaint
      imi.drawList = {}
    else
      -- Process the drawList
      for i,cmd in ipairs(imi.drawList) do
        if cmd.type == "callback" then
          cmd.callback(ctx)
        elseif cmd.type == "save" then
          ctx:save()
        elseif cmd.type == "restore" then
          ctx:restore()
        elseif cmd.type == "clip" then
          ctx:beginPath()
          ctx:rect(cmd.bounds)
          ctx:clip()
        end
      end
      imi.drawList = {}
      if not imi.repaint then
        for _,f in ipairs(imi.afterPaint) do
          f()
        end
        imi.afterPaint = {}
        break
      end
    end
  end
end

function imi.onmousemove(ev)
  imi.mousePos = Point(ev.x, ev.y)
  imi.mouseButton = ev.button
  imi.mouseCursor = MouseCursor.ARROW
  imi.repaint = false

  for id,widget in pairs(imi.widgets) do
    if widget.bounds then
      if widget.onmousemove then
        widget.onmousemove(widget)
      end
      if widget.dragging then
        imi.repaint = true
        imi.draggingWidget = widget
        imi.highlightDropItemPos = nil
      end
      if pointInsideWidgetHierarchy(widget, imi.mousePos) then
        if not widget.hover then
          widget.hover = true
          imi.repaint = true
        end
      elseif widget.hover then
        widget.hover = false
        imi.repaint = true
      end
    end
  end
  if imi.repaint then
    imi.dlg:repaint()
  end

  imi.dlg:modify{ id=imi.canvasId, mouseCursor=imi.mouseCursor }
end

function imi.onmousedown(ev)
  imi.mousePos = Point(ev.x, ev.y)
  imi.mouseButton = ev.button
  imi.repaint = false

  local mouseWidgets = imi.mouseWidgets
  -- Adjust the mouseWidgets stack to fix wrong tile drag instead of
  -- scroll bar drag when tile and scroll bar overlap
  for i=#mouseWidgets, 2, -1 do
    local aboveWidget = mouseWidgets[i]
    local underWidget = mouseWidgets[i-1] -- looking for a viewport with scrollbars
    -- if widget.viewportSize ~= nil implies that
    -- the widget corresponds to a viewport with scrollbars
    if underWidget.viewportSize and not aboveWidget.viewportSize then
      local viewportBounds = Rectangle(underWidget.bounds.origin,
                                       underWidget.viewportSize)
      if not viewportBounds:contains(imi.mousePos) then
        while i <= #mouseWidgets do
          table.remove(mouseWidgets, #mouseWidgets)
        end
      end
    end
  end

  for i=#mouseWidgets,1,-1 do
    local widget = mouseWidgets[i]
    assert(widget ~= nil)
    if widget.onmousedown then
      widget.onmousedown(widget)
    end
    if ev.button == MouseButton.LEFT then
      if widget.hover then
        if widget.wantsFocus then
          imi.focusWidget(widget)
        end

        widget.pressed = true
        imi.capturedWidget = widget
        imi.repaint = true
      end
    end
    if imi.capturedWidget == widget then
      break
    end
  end

  if imi.repaint then
    imi.dlg:repaint()
  end
end

function imi.onmouseup(ev)
  imi.mousePos = Point(ev.x, ev.y)
  imi.mouseButton = 0
  imi.repaint = false

  if imi.capturedWidget then
    local widget = imi.capturedWidget
    if widget.onmouseup then
      widget.onmouseup(widget)
    end
    if widget.pressed then
      if widget.dragging then
        imi.targetWidget = imi.mouseWidgets[#imi.mouseWidgets]
        imi.draggingWidget = nil
        widget.dragging = false
      end
      widget.pressed = false
      widget.checked = not widget.checked
      imi.repaint = true
    end
    imi.capturedWidget = nil
  end

  if imi.repaint then
    imi.dlg:repaint()
  end

  imi.dlg:modify{ id=imi.canvasId, mouseCursor=imi.mouseCursor }
end

function imi.pushID(id)
  table.insert(imi.idStack, id)
end

function imi.popID()
  table.remove(imi.idStack)
end

function imi.getID()
  local id = debug.getinfo(3, "l").currentline
  for i=1,#imi.idStack do
    id = id .. "," .. imi.idStack[i]
  end
  return id
end

-- Execute something after the drawList is completely processed after imi.ongui()
function imi.afterGui(func)
  table.insert(imi.afterPaint, func)
end

----------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------

function imi.pushLayout()
  table.insert(
    imi.layoutStack,
    { cursor=Point(imi.cursor),
      drawList=imi.drawList,
      rowHeight=imi.rowHeight,
      viewportWidget=imi.viewportWidget,
      scrollableBounds=imi.scrollableBounds })

  imi.drawList = {}
  imi.rowHeight = 0
end

function imi.popLayout()
  local pop = imi.layoutStack[#imi.layoutStack]
  imi.cursor = pop.cursor
  imi.drawList = pop.drawList
  imi.rowHeight = pop.rowHeight
  imi.viewportWidget = pop.viewportWidget
  imi.scrollableBounds = pop.scrollableBounds
  table.remove(imi.layoutStack)
end

----------------------------------------------------------------------
-- Groups
----------------------------------------------------------------------

function imi.beginGroup()
  imi.pushLayout()
  table.insert(imi.groupsStack, {
    sameLine=imi.sameLine,
    breakLines=imi.breakLines,
    widgets={},
    commonParent=imi.viewportWidget
  })
end

function imi.endGroup()
  local pop = imi.groupsStack[#imi.groupsStack]
  local subDrawList = imi.drawList
  imi.sameLine = pop.sameLine
  imi.breakLines = pop.breakLines

  -- Calculate the bounds of the whole group
  local bounds = Rectangle()
  for _,w in ipairs(pop.widgets) do
    if w.parent == pop.commonParent then
      bounds = bounds:union(w.bounds)
    end
  end

  -- Try to advance from the initial position of the group (when
  -- beginGroup was called), the group of the bounds.size
  imi.popLayout()
  advanceCursor(
    bounds.size,
    function(newBounds)
      local delta = newBounds.origin - bounds.origin
      for _,w in ipairs(pop.widgets) do
        w.bounds.origin = w.bounds.origin + delta
      end
    end)

  table.remove(imi.groupsStack)

  for i,cmd in ipairs(subDrawList) do
    table.insert(imi.drawList, cmd)
  end
end

----------------------------------------------------------------------
-- Basic Widgets
----------------------------------------------------------------------

function imi.space(width)
  advanceCursor(
    Size(width, 1),
    function(bounds)
      -- Do nothing, we only needed to move imi.cursor
    end)
end

function imi.label(text)
  local id = imi.getID()
  local textSize = imi.ctx:measureText(text)
  advanceCursor(
    textSize,
    function(bounds)
      local widget = updateWidget(id, { bounds=bounds })

      addDrawListFunction(
        function(ctx)
          if widget.color then
            ctx.color = widget.color
          end
          ctx:fillText(text, widget.bounds.x, widget.bounds.y)
        end)
    end)
end

function imi._toggle(id, text)
  local textSize = imi.ctx:measureText(text)
  local size = Size(textSize.width+32*imi.uiScale,
                    textSize.height+8*imi.uiScale)
  advanceCursor(
    size,
    function(bounds)
      local widget = updateWidget(id, { bounds=bounds })
      local draggingProcessed = false

      function drawWidget(ctx)
        local bounds = widget.bounds

        if widget.dragging and not draggingProcessed then
          draggingProcessed = true
          -- Send this same widget to the end to draw it in the
          -- dragged position (and without clipping)
          addDrawListFunction(drawWidget)
        end

        local partId
        local color
        if widget.pressed or
          widget.checked then
          partId = 'buttonset_item_pushed'
          color = app.theme.color.button_selected_text
        elseif widget.hover then
          partId = 'buttonset_item_hot'
          color = app.theme.color.button_hot_text
        else
          partId = 'buttonset_item_normal'
          color = app.theme.color.button_normal_text
        end
        ctx:drawThemeRect(partId, bounds)
        ctx.color = color
        ctx:fillText(text,
                     bounds.x+(bounds.width-textSize.width)/2,
                     bounds.y+(bounds.height-textSize.height)/2)
      end

      addDrawListFunction(drawWidget)
    end)
  return imi.widget.checked
end

function imi.toggle(text)
  local id = imi.getID()
  return imi._toggle(id, text)
end

function imi.button(text)
  local id = imi.getID()
  local result = imi._toggle(id, text)
  if result then
    imi.widget.checked = false
  end
  return result
end

function imi.radio(text, t, thisValue)
  local id = imi.getID()

  addBeforePaint(
    function()
      -- Uncheck radio buttons in previous positions
      if t.value ~= thisValue then
        imi.widgets[id].checked = false
      end
    end)

  local result = imi._toggle(id, text)

  if not imi.widget.pressed and t.uncheckFollowing then
    imi.widget.checked = false
  elseif imi.widget.pressed or t.value == thisValue then
    imi.widget.checked = true
    t.value = thisValue
    if imi.widget.pressed then
      -- Uncheck radio buttons in following! positions
      t.uncheckFollowing = true
      addBeforePaint(
        function()
          t.uncheckFollowing = nil
        end)
    end
  end

  return t.value == thisValue
end

function imi.image(image, srcRect, dstSize, scale, alpha)
  if not scale then scale = 1.0 end
  if not alpha then alpha = 1.0 end
  local id = imi.getID()
  advanceCursor(
    dstSize,
    function(bounds)
      local widget = updateWidget(id, { bounds=bounds })
      widget.wantsFocus = true

      -- Draw this widget only if it's visible through the current
      -- viewport (if we are in a viewport)
      if insideViewport(bounds) then
        local draggingProcessed = false

        local function drawWidget(ctx)
          local bounds = widget.bounds

          if widget.dragging and not draggingProcessed then
            draggingProcessed = true
            -- Send this same widget to the end to draw it in the
            -- dragged position (and without clipping)
            addDrawListFunction(drawWidget)
          end

          local w,h = srcRect.width*scale, srcRect.height*scale
          local paint = nil
          if app.apiVersion >= 22 then
            paint = Paint()
            paint.alpha = alpha
          end
          ctx:drawImage(image, srcRect,
                        Rectangle(bounds.x+bounds.width/2-w/2,
                                  bounds.y+bounds.height/2-h/2,
                                  w, h),
                        paint)

          if widget.pressed or
             widget.checked or
             widget.focused then
            ctx:drawThemeRect('colorbar_selection_hot',
                              widget.bounds)
          elseif widget.hover then
            ctx:drawThemeRect('colorbar_selection',
                              widget.bounds)
          end
        end

        addDrawListFunction(drawWidget)
      end
    end)
  return imi.widget.checked
end

----------------------------------------------------------------------
-- Viewport
----------------------------------------------------------------------

-- Push a rectangle to act like a viewport/area to layout the
-- following widgets. By default the first "viewport" is the whole
-- window client area.
function imi.pushViewport(rectangle)
  table.insert(imi.viewportStack, imi.viewport)
  imi.viewport = rectangle
end

function imi.popViewport()
  imi.viewport = imi.viewportStack[#imi.viewportStack]
  table.remove(imi.viewportStack)
end

-- Creates a scrollable viewport.
-- If itemSize is nil, the viewport cannot be resized.
--
-- Fields:
--   widget.resizedViewport = Size(numberOfColumns, numberOfRows)
--
-- Events:
--   widget.onviewportresized = function(resizedViewport)
function imi.beginViewport(size, itemSize)
  local id = imi.getID()
  local widget = updateWidget(
    id, { itemSize=itemSize,
          withBorder=(itemSize ~= nil) })

  if itemSize and widget.resizedViewport then
    size = Size(widget.resizedViewport.width * itemSize.width,
                widget.resizedViewport.height * itemSize.height)
  end

  local border = 0
  if widget.withBorder then
    border = 4*imi.uiScale -- TODO access theme styles
  end

  local barSize = app.theme.dimension.mini_scrollbar_size
  size.width = size.width + 2*border + barSize
  size.height = size.height + 2*border + barSize

  function widget.setScrollPos(pos)
    local maxScrollPos = widget.scrollableSize - widget.viewportSize
    pos.x = imi.clamp(pos.x, 0, maxScrollPos.width)
    pos.y = imi.clamp(pos.y, 0, maxScrollPos.height)

    if widget.scrollPos ~= pos then
      widget.scrollPos = pos
      imi.dlg:repaint()
    end
  end

  local function onmousemove(widget)
    local bounds = widget.bounds

    if itemSize and widget.draggingResize then
      local oldResizedViewport = widget.resizedViewport

      widget.resizedViewport = Size(
        (dragStartViewportSize.width + (imi.mousePos.x - dragStartMousePos.x)+itemSize.width/2) / itemSize.width,
        (dragStartViewportSize.height + (imi.mousePos.y - dragStartMousePos.y)+itemSize.height/2) / itemSize.height)
      widget.resizedViewport.width = math.max(widget.resizedViewport.width, 1)
      widget.resizedViewport.height = math.max(widget.resizedViewport.height, 1)

      if oldResizedViewport ~= widget.resizedViewport then
        imi.dlg:repaint()
      end
      imi.mouseCursor = MouseCursor.SE_RESIZE
    elseif widget.draggingHBar then
      local maxScrollPos = widget.scrollableSize - widget.viewportSize
      local scrollPos = Point(widget.scrollPos)

      if widget.hoverHBar then
        local info = getHScrollInfo(widget)
        local pos = dragStartScrollBarPos + (imi.mousePos - dragStartMousePos)
        pos.x = imi.clamp(pos.x, 0, info.fullLen - info.len)
        scrollPos.x = maxScrollPos.width * pos.x / (info.fullLen - info.len)
      else
        scrollPos = dragStartScrollPos + (dragStartMousePos - imi.mousePos)
        imi.mouseCursor = MouseCursor.GRABBING
      end
      widget.setScrollPos(scrollPos)
    elseif widget.draggingVBar then
      local maxScrollPos = widget.scrollableSize - widget.viewportSize
      local scrollPos = Point(widget.scrollPos)

      if widget.hoverVBar then
        local info = getVScrollInfo(widget)
        local pos = dragStartScrollBarPos + (imi.mousePos - dragStartMousePos)
        pos.y = imi.clamp(pos.y, 0, info.fullLen - info.len)
        scrollPos.y = maxScrollPos.height * pos.y / (info.fullLen - info.len)
      else
        scrollPos = dragStartScrollPos + (dragStartMousePos - imi.mousePos)
        imi.mouseCursor = MouseCursor.GRABBING
      end
      widget.setScrollPos(scrollPos)
    else
      local oldHoverHBar = widget.hoverHBar
      local oldHoverVBar = widget.hoverVBar

      widget.hoverHBar =
        (widget.bounds:contains(imi.mousePos) and
         imi.mousePos.y >= bounds.y+bounds.height-barSize-4*imi.uiScale and
         imi.mousePos.y <= bounds.y+bounds.height)

      widget.hoverVBar =
        (widget.bounds:contains(imi.mousePos) and
         imi.mousePos.x >= bounds.x+bounds.width-barSize-4*imi.uiScale and
         imi.mousePos.x <= bounds.x+bounds.width)

      if oldHoverHBar ~= widget.hoverHBar or
         oldHoverVBar ~= widget.hoverVBar then
        imi.dlg:repaint()
      end

      local oldHoverResize = widget.hoverResize
      widget.hoverResize =
        (itemSize ~= nil) and
        widget.hoverHBar and
        widget.hoverVBar
      if widget.hoverResize then
        imi.mouseCursor = MouseCursor.SE_RESIZE
      end
      if oldHoverResize ~= widget.hoverResize then
        imi.dlg:repaint()
      end
    end
  end

  local function onmousedown(widget)
    if widget.hoverResize then
      widget.draggingResize = true

      imi.capturedWidget = widget
      dragStartMousePos = Point(imi.mousePos)
      if not widget.resizedViewport then
        widget.resizedViewport = Size(widget.bounds.width / itemSize.width,
                                      widget.bounds.height / itemSize.height)
      end
      dragStartViewportSize = Size(widget.bounds.size)
    elseif widget.hoverHBar or
       imi.mouseButton == MouseButton.MIDDLE then
      widget.draggingHBar = true

      imi.capturedWidget = widget
      dragStartMousePos = Point(imi.mousePos)
      dragStartScrollPos = Point(widget.scrollPos)
      dragStartScrollBarPos = getHScrollInfo(widget).pos
    elseif widget.hoverVBar then
      widget.draggingVBar = true

      imi.capturedWidget = widget
      dragStartMousePos = Point(imi.mousePos)
      dragStartScrollPos = Point(widget.scrollPos)
      dragStartScrollBarPos = getVScrollInfo(widget).pos
    end
  end

  local function onmouseup(widget)
    if widget.draggingResize then
      if widget.onviewportresized then
        widget.onviewportresized(widget.resizedViewport)
      end

      widget.draggingResize = false
    elseif widget.draggingHBar then
      widget.draggingHBar = false
    elseif widget.draggingVBar then
      widget.draggingVBar = false
    end
    imi.dlg:repaint()
  end

  advanceCursor(
    size,
    function(bounds)
      -- Limit this viewport width with the current available
      -- viewport/window size
      if bounds.x + bounds.width > imi.viewport.x + imi.viewport.width then
        bounds.width = (imi.viewport.x + imi.viewport.width) - bounds.x
      end

      local widget = updateWidget(
        id,
        { bounds=bounds,
          onmousemove=onmousemove,
          onmousedown=onmousedown,
          onmouseup=onmouseup })

      if widget.draggingHBar == nil then
        widget.draggingHBar = false
      end
      if widget.draggingVBar == nil then
        widget.draggingVBar = false
      end
      if widget.scrollPos == nil then
        widget.scrollPos = Point(0, 0)
      end

      imi.pushViewport(Rectangle(bounds.x+border,
                                 bounds.y+border,
                                 bounds.width-2*border-barSize,
                                 bounds.height-2*border-barSize))
    end)

  imi.pushLayout()
  imi.viewportWidget = widget
  imi.cursor = imi.viewport.origin - widget.scrollPos
  imi.scrollableBounds = Rectangle(imi.cursor, Size(1, 1))
end

function imi.endViewport()
  local widget = imi.viewportWidget
  local bounds = widget.bounds
  local subDrawList = imi.drawList

  local border = 0
  if widget.withBorder then
    border = 4*imi.uiScale -- TODO access theme styles
  end

  local barSize = app.theme.dimension.mini_scrollbar_size
  widget.scrollableSize = imi.scrollableBounds.size + Size(barSize, barSize)
  widget.viewportSize = Size(bounds.width-border,
                             bounds.height-border)
  setupScrollbars(widget, barSize)

  imi.popViewport()
  imi.popLayout()

  if widget.withBorder then
    addDrawListFunction(function (ctx)
      ctx:drawThemeRect('sunken_normal', bounds)
    end)
  end

  -- Draw sub items (using the current widget.bounds)
  table.insert(imi.drawList, { type="save" })

  -- TODO: We need to fix this. I had to use the addDrawListFunction here instead of inserting a
  -- "clip" cmd to imi.drawList because the bounds "upvalue" is recalculated after an endGroup
  -- call, so I needed to "defer" the bounds retrieval. If I don't do this, the clip is not
  -- positioned right and therefore the viewport content is not displayed.
  addDrawListFunction(function(ctx)
    ctx:beginPath()
    ctx:rect(Rectangle(bounds.x+border,
                       bounds.y+border,
                       bounds.width-2*border,
                       bounds.height-2*border))
    ctx:clip()
  end)

  -- Move items in a grid
  addDrawListFunction(function(ctx)
    if widget.itemSize and imi.draggingWidget and
      bounds:contains(imi.mousePos) then
      local origin = bounds.origin - widget.scrollPos + Point(border, border)

      local itemUV = imi.mousePos - origin
      itemUV.x = itemUV.x / widget.itemSize.width
      itemUV.y = itemUV.y / widget.itemSize.height
      imi.highlightDropItemPos = itemUV

      local rc = Rectangle(0, 0, widget.itemSize.width, widget.itemSize.height)
      rc.x = origin.x + itemUV.x*rc.width
      rc.y = origin.y + itemUV.y*rc.height
      ctx:drawThemeRect('sunken_normal', rc)
    end
  end)

  for _,cmd in ipairs(subDrawList) do
    table.insert(imi.drawList, cmd)
  end
  table.insert(imi.drawList, { type="restore" })

  local function getParts(hover)
    local bgPart, thumbPart
    if hover and not (widget.hoverVBar and widget.hoverHBar) then
      bgPart = 'mini_scrollbar_bg_hot'
      thumbPart = 'mini_scrollbar_thumb_hot'
    else
      bgPart = 'mini_scrollbar_bg'
      thumbPart = 'mini_scrollbar_thumb'
    end
    return bgPart, thumbPart
  end

  addDrawListFunction(function (ctx)
    local bgPart, thumbPart, info
    local hbarSize, vbarSize
    if widget.hasHBar then hbarSize = barSize else hbarSize = 0 end
    if widget.hasVBar then vbarSize = barSize else vbarSize = 0 end

    if widget.hasHBar then
      bgPart, thumbPart = getParts(widget.hoverHBar)
      info = getHScrollInfo(widget)
      ctx:drawThemeRect(bgPart,
                        bounds.x+border,
                        bounds.y+bounds.height-barSize-border-1*imi.uiScale,
                        bounds.width-2*border-vbarSize,
                        barSize+1*imi.uiScale)
      ctx:drawThemeRect(thumbPart,
                        bounds.x+border+info.pos,
                        bounds.y+bounds.height-barSize-border-1*imi.uiScale,
                        info.len, barSize)
    end

    if widget.hasVBar then
      bgPart, thumbPart = getParts(widget.hoverVBar)
      info = getVScrollInfo(widget)
      ctx:drawThemeRect(bgPart,
                        bounds.x+bounds.width-barSize-border-1*imi.uiScale,
                        bounds.y+border,
                        barSize+1*imi.uiScale,
                        bounds.height-2*border-hbarSize)
      ctx:drawThemeRect(thumbPart,
                        bounds.x+bounds.width-barSize-border-1*imi.uiScale,
                        bounds.y+border+info.pos,
                        barSize, info.len)
    end
  end)
end

----------------------------------------------------------------------
-- Drag & Drop
----------------------------------------------------------------------

function imi.beginDrag()
  local widget = imi.widget

  if widget.pressed then
    if widget.dragging then
      local pt = widget.bounds.origin
      local delta = imi.mousePos - dragStartMousePos
      pt = pt + delta
      if widget.bounds.origin ~= pt then
        addDrawListFunction(
          function()
            widget.bounds.origin =
              widget.bounds.origin + delta
          end)
      end
    else
      dragStartMousePos = imi.mousePos
      imi.widget.dragging = true
      imi.capturedWidget = imi.widget
    end
    return true
  else
    return false
  end
end

function imi.setDragData(dataType, data)
  if imi.dragData == nil then
    imi.dragData = {}
  end
  imi.dragData[dataType] = data
end

function imi.beginDrop()
  if imi.targetWidget and
     imi.targetWidget.id == imi.widget.id then
    imi.targetWidget = nil
    return true
  end
  return false
end

function imi.getDropData(dataType)
  if imi.dragData then
    return imi.dragData[dataType]
  else
    return nil
  end
end

function imi.endDrop()
  imi.highlightDropItemPos = nil
end

return imi
