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
local shrunkenBounds = {} -- Minimal bounds between all tiles of the active layer
local tilesHistogram = {} -- How many times each tile is used in the active layer
local activeTileImageInfo = {} -- Used to re-calculate info when the tile image changes

local imi = dofile('./imi.lua')

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

local function calculate_tiles_histogram(tilemapLayer)
  local histogram = {}
  for _,cel in ipairs(tilemapLayer.cels) do
    local ti = cel.image:getPixel(0, 0)
    if histogram[ti] == nil then
      histogram[ti] = 1
    else
      histogram[ti] = histogram[ti] + 1
    end
  end
  return histogram
end

local function get_active_tile_image()
  if activeLayer and activeLayer.isTilemap then
    local cel = activeLayer:cel(app.activeFrame)
    if cel and cel.image then
      local ti = cel.image:getPixel(0, 0)
      return activeLayer.tileset:getTile(ti)
    end
  end
  return nil
end

-- Used to remove all checked images after adding the tiles to a new category
local removeAllChecks = false
-- Indicate if we should show all tiles or only the ones from a specific category
local showCategoryRadio = { value=0 }
local categories = { }
local editCategory = false
local editCategoryItems = { }

local function create_tile_view(index, ti, ts, inRc, outSize,
                                cel, selectedTilesToAdd)
  imi.pushID(index)
  local tileImg = ts:getTile(ti)
  imi.image(tileImg, inRc, outSize)

  if imi.widget.hover then
    hoverItems = true
  end

  if removeAllChecks then
    imi.widget.checked = false
  end

  if imi.widget.checked then -- When the image is clicked
    if not editCategory then
      imi.widget.checked = false

      -- Change tilemap tile if are not showing categories
      -- We use Image:drawImage() to get undo information
      if cel and cel.image then
        local tilemapCopy = Image(cel.image)
        tilemapCopy:putPixel(0, 0, ti)

        -- This will trigger a Sprite_change() where we
        -- re-calculate shrunkenBounds, tilesHistogram, etc.
        cel.image:drawImage(tilemapCopy)
      else
        local image = Image(1, 1, ColorMode.TILEMAP)
        image:putPixel(0, 0, ti)

        print('app.activeFrame=', app.activeFrame, 'ti=', ti)
        cel = app.activeSprite:newCel(activeLayer, app.activeFrame, image, Point(0, 0))
      end

      imi.repaint = true
      app.refresh()
    elseif cel and cel.image then
      table.insert(selectedTilesToAdd, ti)
    end
  end

  imi.alignRight = true
  if tilesHistogram[ti] == nil then
    imi.label("Unused")
  else
    imi.label(tostring(tilesHistogram[ti]))
  end
  imi.widget.color = Color(255, 255, 0)
  imi.alignRight = false

  imi.popID()
end

local function imi_ongui()
  imi.mouseCursor = MouseCursor.ARROW

  local spr = app.activeSprite
  if not spr then
    dlg:modify{ title=title }
    imi.label("No sprite")
  else
    dlg:modify{ title=title .. " - " .. app.fs.fileTitle(spr.filename) }
    if activeLayer then
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

      -- All or Categories

      imi.sameLine = true
      local allTiles = imi.radio("All", showCategoryRadio, 0)
      local showCategoryItems = nil
      for i,category in ipairs(categories) do
        imi.pushID(i)
        if imi.radio(category.name, showCategoryRadio, i) then
          showCategoryItems = { table.unpack(category.items) }
        end
        imi.popID()
      end

      imi.sameLine = false

      -- List of tiles/attachments of the active layer
      local selectedTilesToAdd = {}
      local hoverItems = false

      local ts = activeLayer.tileset
      local cel = activeLayer:cel(app.activeFrame)
      if cel and cel.image then
        local ti = cel.image:getPixel(0, 0)
        local tileImg = ts:getTile(ti)
        imi.image(tileImg, inRc, outSize)
        imi.sameLine = true
       end

      imi.beginViewport(Size(imi.ctx.width - imi.cursor.x,
                             outSize.height))
      imi.sameLine = true
      imi.breakLines = false
      if allTiles then
        for i=1,#ts do
          create_tile_view(i, i, ts, inRc, outSize,
                           cel, selectedTilesToAdd)
        end
      else
        for i,ti in ipairs(showCategoryItems) do
          create_tile_view(i, ti, ts, inRc, outSize,
                           cel, selectedTilesToAdd)
        end
      end
      imi.endViewport()

      if removeAllChecks then
        removeAllChecks = false
      end

      -- Categories

      imi.sameLine = false
      editCategory = imi.toggle("Edit Category")
      imi.sameLine = true
      imi.breakLines = true
      if editCategory then
        imi.space(2)
        local add = imi.button("Add")
        local remove = imi.button("Remove")
        local outSize2 = Size(outSize.width*3/4, outSize.height*3/4)
        imi.sameLine = false
        imi.beginViewport(Size(imi.ctx.width,
                               outSize2.height))
        imi.sameLine = true
        imi.breakLines = false
        local editSelectedItems = {}
        for index,ti in ipairs(editCategoryItems) do
          imi.pushID(index)
          local tileImg = ts:getTile(ti)
          if imi.image(tileImg, inRc, outSize2) then
            table.insert(editSelectedItems, index)
          end
          imi.popID()
        end
        imi.endViewport()

        imi.sameLine = false
        if #editCategoryItems > 0 and
          imi.button("Save Category") then
          local d =
            Dialog("New Category Name")
            :entry{ id="name", label="Name:", focus=true }
            :button{ id="ok", text="OK", focus=true }
            :button{ id="cancel", text="Cancel" }

          dlg:repaint()

          d:show()
          local data = d.data
          if data.ok then
            local category = {
              name=data.name,
              items={ table.unpack(editCategoryItems) },
            }
            table.insert(categories, category)
            imi.repaint = true
          end
        end

        if add then
          removeAllChecks = true
          for _,ti in ipairs(selectedTilesToAdd) do
            table.insert(editCategoryItems, ti)
          end
          imi.repaint = true
        end
        if remove then
          for i=#editSelectedItems,1,-1 do
            table.remove(editCategoryItems,
                         editSelectedItems[i])
            imi.repaint = true
          end
        end
      end
    end

    if hoverItems and not newCategory then
      imi.mouseCursor = MouseCursor.POINTER
    end
  end
end

local function Sprite_change()
  if activeLayer and activeLayer.isTilemap then
    local tileImg = get_active_tile_image()
    if tileImg and
       (not activeTileImageInfo or
        tileImg.id ~= activeTileImageInfo.id or
        (tileImg.id == activeTileImageInfo.id and
         tileImg.version > activeTileImageInfo.version)) then
      activeTileImageInfo = { id=tileImg.id,
                              version=tileImg.version }
      shrunkenBounds = calculate_shrunken_bounds(activeLayer)
      tilesHistogram = calculate_tiles_histogram(activeLayer)
      if not imi.isongui then
        imi.dlg:repaint()
      end
    else
      activeTileImageInfo = {}
    end
  end
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

-- When the active site (active sprite, cel, frame, etc.) changes this
-- function will be called.
local function App_sitechange(ev)
  local newSpr = app.activeSprite
  if newSpr ~= observedSprite then
    observe_sprite(newSpr)
  end

  local lay = app.activeLayer
  if lay and not lay.isTilemap then
    lay = nil
  end
  if activeLayer ~= lay then
    activeLayer = lay
    if activeLayer and activeLayer.isTilemap then
      shrunkenBounds = calculate_shrunken_bounds(activeLayer)
      tilesHistogram = calculate_tiles_histogram(activeLayer)
    else
      shrunkenBounds = Rectangle()
    end
  end

  local tileImg = get_active_tile_image()
  if tileImg then
    activeTileImageInfo = { id=tileImg.id,
                            version=tileImg.version }
  else
    activeTileImageInfo = {}
  end

  if not imi.isongui then
    dlg:repaint() -- TODO repaint only when it's needed
  end
end

local function AttachmentWindow_SwitchWindow()
  if dlg then
    unobserve_sprite()
    app.events:off(App_sitechange)
    dlg:close()
    dlg = nil
  else
    dlg = Dialog(title)
      :canvas{ id="canvas",
               width=400, height=300,
               onpaint=imi.onpaint,
               onmousemove=imi.onmousemove,
               onmousedown=imi.onmousedown,
               onmouseup=imi.onmouseup }
    imi.init{ dialog=dlg,
              ongui=imi_ongui,
              canvas="canvas" }
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
