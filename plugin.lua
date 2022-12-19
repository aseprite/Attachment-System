-- Aseprite Attachment System
-- Copyright (c) 2022  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

-- The main window/dialog
local dlg
local title = "Attachment Window"
local observedSprite
local activeLayer
local shrunkenBounds = {}

local function Sprite_change()
  -- TODO
end

local function unobserve_sprite()
  if observedSprite then
    observedSprite.events:off(Sprite_change)
    observedSprite = nil
  end
end

local function observe_sprite(spr)
  unobserve_sprite()
  observedSprite = spr
  if observedSprite then
    observedSprite.events:on('change', Sprite_change)
  end
end

local function calculate_shrunken_bounds(tilemapLayer)
  assert(tilemapLayer.isTilemap)
  local bounds = Rectangle()
  local ts = tilemapLayer.tileset
  local ntiles = #ts
  for i = 0,ntiles-1 do
    local tileImg = ts:getTile(i)
    bounds = bounds:union(tileImg:shrinkBounds())
  end
  return bounds
end

-- When the active site (active sprite, cel, frame, etc.) changes this
-- function will be called.
local function App_sitechange(ev)
  local newSpr = app.activeSprite
  if newSpr ~= observedSprite then
    observe_sprite(newSpr)
    dlg:repaint()
  end

  local lay = app.activeLayer
  if lay and not lay.isTilemap then
    lay = nil
  end
  if activeLayer ~= lay then
    activeLayer = lay
    if activeLayer and activeLayer.isTilemap then
      shrunkenBounds = calculate_shrunken_bounds(activeLayer)
    else
      shrunkenBounds = Rectangle()
    end
  end

  dlg:repaint()
end

local function Canvas_onpaint(ev)
  local ctx = ev.context
  local spr = app.activeSprite
  if not spr then
    dlg:modify{ title=title }
    ctx:fillText("No sprite", 0, 0)
  else
    dlg:modify{ title=title .. " - " .. app.fs.fileTitle(spr.filename) }
    local sz = ctx:measureText(" ")
    local h = sz.height

    ctx:fillText("Sprite: " .. spr.filename, 0, 0)
    if activeLayer then
      ctx:fillText("Layer: " .. activeLayer.name, 0, h)

      local inRc = shrunkenBounds
      local outSize = Size(128, 128)
      if inRc.width < outSize.width and
        inRc.height < outSize.height then
        outSize = Size(inRc.width, inRc.height)
      elseif inRc.width > inRc.height then
        outSize.height = outSize.width * inRc.height / inRc.width
      else
        outSize.width = outSize.height * inRc.width / inRc.height
      end

      local ts = activeLayer.tileset
      local cel = activeLayer:cel(app.activeFrame)
      if cel and cel.image then
        local tile = cel.image:getPixel(0, 0)
        local tileImg = ts:getTile(tile)
        ctx:drawImage(tileImg, inRc.x, inRc.y, inRc.width, inRc.height,
                      0, 2*h, outSize.width, outSize.height)
      end

      local ntiles = #ts
      for i = 0,ntiles-1 do
        local tileImg = ts:getTile(i)
        ctx:drawImage(tileImg,
                      inRc.x, inRc.y, inRc.width, inRc.height,
                      8+(i+1)*outSize.width, 2*h, outSize.width, outSize.height)
      end
    end
  end
end

local function Canvas_onmousemove(ev)
  -- TODO
end

local function Canvas_onmousedown(ev)
  -- TODO
end

local function Canvas_onmouseup(ev)
  -- TODO
end

local function AttachmentWindow_SwitchWindow()
  if dlg then
    unobserve_sprite()
    app.events:off(App_sitechange)
    dlg:close()
    dlg = nil
  else
    dlg = Dialog(title)
      :canvas{ width=400, height=300,
               onpaint=Canvas_onpaint,
               onmousemove=Canvas_onmousemove,
               onmousedown=Canvas_onmousedown,
               onmouseup=Canvas_onmouseup }
    dlg:show{ wait=false }

    app.events:on('sitechange', App_sitechange)
    observe_sprite(app.activeSprite)
  end
end

function init(plugin)
  plugin:newCommand{
    id="AttachmentSystem_SwitchWindow",
    title="Attachment System: Switch Window",
    group="view_new",
    onclick=AttachmentWindow_SwitchWindow
  }
end
