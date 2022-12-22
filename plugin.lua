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
local imi = dofile('./imi.lua')

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

local function imi_ongui()
  local spr = app.activeSprite
  if not spr then
    dlg:modify{ title=title }
    imi.label("No sprite")
  else
    dlg:modify{ title=title .. " - " .. app.fs.fileTitle(spr.filename) }
    imi.label("Sprite: " .. spr.filename)
    if activeLayer then
      imi.label("Layer: " .. activeLayer.name)

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

      imi.sameLine = false

      local ts = activeLayer.tileset
      local cel = activeLayer:cel(app.activeFrame)
      if cel and cel.image then
        local tile = cel.image:getPixel(0, 0)
        local tileImg = ts:getTile(tile)
        imi.image(tileImg, inRc, outSize)
       end

      local ntiles = #ts

      imi.sameLine = true
      imi.beginViewport(Size(imi.ctx.width - imi.cursor.x,
                             outSize.height))
      imi.breakLines = false
      for i=1,ntiles do
        imi.pushID(i)
        local tileImg = ts:getTile(i)
        imi.image(tileImg, inRc, outSize)
        if imi.widget.checked then
          imi.widget.checked = false
          -- Change tilemap tile -- TODO undo info
          if cel and cel.image then
            cel.image:putPixel(0, 0, i)
            app.refresh()
          end
        end
        imi.popID()
      end
      imi.endViewport()
    end
  end
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

local function AttachmentWindow_SwitchWindow()
  if dlg then
    unobserve_sprite()
    app.events:off(App_sitechange)
    dlg:close()
    dlg = nil
  else
    dlg = Dialog(title)
      :canvas{ width=400, height=300,
               onpaint=imi.onpaint,
               onmousemove=imi.onmousemove,
               onmousedown=imi.onmousedown,
               onmouseup=imi.onmouseup }
    imi.init{ dialog=dlg,
              ongui=imi_ongui }
    dlg:show{ wait=false }

    App_sitechange()
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
