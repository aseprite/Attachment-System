-- Aseprite Attachment System
-- Copyright (c) 2022-2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.
----------------------------------------------------------------------
-- Extension Properties:
--
-- Layer = {
--   categories={
--     { id=0,
--       name="Default",
--       folders={
--         { name="Folder Name"
--           items={ tileIndex1, tileIndex2, ... }
--         }
--       },
--     },
--     ...
--   },
-- }
--
-- Tile = {
--   category=nil or categoryID,
--   pivot=Point(0, 0),
-- }
----------------------------------------------------------------------

local imi = dofile('./imi.lua')

-- Plugin-key to access extension properties in layers/tiles/etc.
-- E.g. layer.properties(PK)
local PK = "aseprite/Attachment-System"

-- The main window/dialog
local dlg
local title = "Attachment Window"
local observedSprite
local activeLayer
local shrunkenBounds = {} -- Minimal bounds between all tiles of the active layer
local tilesHistogram = {} -- How many times each tile is used in the active layer
local activeTileImageInfo = {} -- Used to re-calculate info when the tile image changes
local showTilesID = false
local showTilesUsage = false
local zoom = 1.0

-- Default category visible for each layer (key=layer.id, value=index of the category)
local defaultVisibleCategory = {}

-- Indicate if we should show all tiles (value=0) or only the ones
-- from a specific category
local showCategoryRadio = { value=1 }

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

local function get_layer_properties(layer)
  local properties = layer.properties(PK)
  if not properties.categories then
    -- Don't modify properties.categories = { ... } do avoid creating
    -- an undoable transaction here, here we just return a table.
    properties = {
      categories={
        { id=0, name="Default", folders={ } }
      }
    }
  end
  return properties
end

-- TODO replace this with built-in tile properties
local tile_properties = {}
local function get_tile_properties(tile)
  if not tile_properties[tile] then
    tile_properties[tile] = { hasProperties=true }
  end
  return tile_properties[tile]
end

local function calculate_new_category_id(layers)
  local maxId = 0
  if layers == nil then
    layers = app.activeSprite.layers
  end
  for _,layer in ipairs(layers) do
    for _,category in ipairs(get_layer_properties(layer).categories) do
      maxId = math.max(maxId, category.id)
    end
    if layer.layers then
      maxId = math.max(maxId, calculate_new_category_id(layer.layers))
    end
  end
  return maxId
end

local function set_active_tile(ti)
  if activeLayer and activeLayer.isTilemap then
    local cel = activeLayer:cel(app.activeFrame)

    -- Change tilemap tile if are not showing categories
    -- We use Image:drawImage() to get undo information
    if activeLayer and cel and cel.image then
      local tilemapCopy = Image(cel.image)
      tilemapCopy:putPixel(0, 0, ti)

      -- This will trigger a Sprite_change() where we
      -- re-calculate shrunkenBounds, tilesHistogram, etc.
      cel.image:drawImage(tilemapCopy)
    else
      local image = Image(1, 1, ColorMode.TILEMAP)
      image:putPixel(0, 0, ti)

      cel = app.activeSprite:newCel(activeLayer, app.activeFrame, image, Point(0, 0))
    end

    imi.repaint = true
    app.refresh()
  end
end

local function create_tile_view(index, ti, ts, inRc, outSize,
                                activeCategory)
  imi.pushID(index)
  local tileImg = ts:getTile(ti)
  imi.image(tileImg, inRc, outSize)
  if imi.beginDrag() then
    imi.setDragData("tile", { index=index, ti=ti })
  end
  if imi.beginDrop() then
    -- TODO reorder tiles in category
    local data = imi.getDropData("tile")
    if data then
      get_tile_properties(ti).category = activeCategory.id
    end
  end

  if imi.widget.checked then
    imi.widget.checked = false
  end

  if showTilesID then
    imi.alignFunc = function(cursor, size, lastBounds)
      return Point(lastBounds.x,
		   lastBounds.y+lastBounds.height-size.height)
    end
    imi.label(string.format("[%d]", ti))
    imi.widget.color = Color(255, 255, 0)
    imi.alignFunc = nil
  end
  if showTilesUsage then
    local label
    if tilesHistogram[ti] == nil then
      label = "Unused"
    else
      label = tostring(tilesHistogram[ti])
    end
    imi.alignFunc = function(cursor, size, lastBounds)
      return lastBounds.origin
    end
    imi.label(label)
    imi.widget.color = Color(255, 255, 0)
    imi.alignFunc = nil
  end

  imi.popID()
end

local function new_category_dialog()
  local d =
    Dialog("New Category Name")
    :entry{ id="name", label="Name:", focus=true }
    :button{ id="ok", text="OK", focus=true }
    :button{ id="cancel", text="Cancel" }
  dlg:repaint()
  d:show()
  local data = d.data
  if data.ok and data.name ~= "" then
    return {
      id=calculate_new_category_id()+1,
      name=data.name,
      folders={ },
    }
  else
    return nil
  end
end

local function new_folder_dialog()
  local d =
    Dialog("New Folder Name")
    :entry{ id="name", label="Name:", focus=true }
    :button{ id="ok", text="OK", focus=true }
    :button{ id="cancel", text="Cancel" }
  dlg:repaint()
  d:show()
  local data = d.data
  if data.ok and data.name ~= "" then
    return {
      name=data.name,
      items={ },
      folders={ },
    }
  else
    return nil
  end
end

local function imi_ongui()
  local spr = app.activeSprite
  if not spr then
    dlg:modify{ title=title }

    imi.ctx.color = app.theme.color.text
    imi.label("No sprite")
  else
    dlg:modify{ title=title .. " - " .. app.fs.fileTitle(spr.filename) }
    if activeLayer then
      local layerProperties = get_layer_properties(activeLayer)
      local categories = layerProperties.categories

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
      outSize.width = outSize.width * zoom
      outSize.height = outSize.height * zoom

      -- Categories

      imi.sameLine = true
      local activeCategory = nil
      for i,category in ipairs(categories) do
        imi.pushID(i)
        if imi.radio(category.name, showCategoryRadio, i) then
          activeCategory = category
        end
        imi.popID()
      end

      if defaultVisibleCategory[activeLayer.id] ~= showCategoryRadio.value then
        defaultVisibleCategory[activeLayer.id] = showCategoryRadio.value
      end

      imi.space(4)
      if imi.button("New Category") then
        local category = new_category_dialog()
        if category then
          table.insert(categories, category)
          activeLayer.properties(PK).categories = categories
        end
        imi.repaint = true
        return
      end

      imi.space(4)
      showTilesID = imi.toggle("Show ID")
      showTilesUsage = imi.toggle("Show Usage")

      imi.sameLine = false

      -- Active tile

      local ts = activeLayer.tileset
      local cel = activeLayer:cel(app.activeFrame)
      local ti = 0
      if cel and cel.image then
        ti = cel.image:getPixel(0, 0)
      end
      do
        local tileImg = ts:getTile(ti)
        -- Show active tile in active cel
        imi.image(tileImg, inRc, outSize)
        if imi.beginDrag() then
          imi.setDragData("tile", { index=0, ti=ti })
        -- We can drop a tile here to change the tile in the activeCel
        -- tilemap
        elseif imi.beginDrop() then
          local data = imi.getDropData("tile")
          if data then
            set_active_tile(data.ti)
          end
        end

        imi.sameLine = true
       end

      -- List of tiles in current category

      imi.beginViewport(Size(imi.ctx.width - imi.cursor.x,
                             outSize.height))
      if imi.beginDrop() then
        local data = imi.getDropData("tile")
        if data then
          -- TODO reorder tiles in category
          get_tile_properties(data.ti).category = activeCategory.id
        end
      end

      imi.sameLine = true
      imi.breakLines = false
      for i=1,#ts do
        if (activeCategory and
            activeCategory.id == 0 or
            get_tile_properties(i).category == activeCategory.id) then
          create_tile_view(i, i, ts, inRc, outSize, activeCategory)
        end
      end
      imi.endViewport()

      -- Folders

      imi.sameLine = false
      if imi.button("New Folder") then
        local folder = new_folder_dialog()
        if folder then
          table.insert(activeCategory.folders, folder)
          activeLayer.properties(PK).categories = categories
        end
        imi.repaint = true
        return
      end

      if activeCategory then
        for i,folder in ipairs(activeCategory.folders) do
          imi.pushID(i)
          imi.sameLine = false
          if imi.toggle(folder.name) then
            -- One viewport for each opened folder
            local outSize2 = Size(outSize.width*3/4, outSize.height*3/4)
            imi.beginViewport(Size(imi.ctx.width,
                                   outSize2.height))

            if imi.beginDrop() then
              local data = imi.getDropData("tile")
              if data then
                -- Drag-and-drop in the same folder, move the tile to the end
                if data.folder == folder.name then
                  table.remove(folder.items, data.index)
                end
                -- Drop a new item at the end of this folder
                table.insert(folder.items, data.ti)
                activeLayer.properties(PK).categories = categories
                imi.repaint = true
              end
            end

            imi.sameLine = true
            imi.breakLines = false
            for index,ti in ipairs(folder.items) do
              imi.pushID(index)
              local tileImg = ts:getTile(ti)
              imi.image(tileImg, inRc, outSize2)

              if imi.beginDrag() then
                imi.setDragData("tile", { index=index, ti=ti, folder=folder.name })
              elseif imi.beginDrop() then
                local data = imi.getDropData("tile")
                if data then
                  -- Drag-and-drop in the same folder
                  if data.folder == folder.name then
                    table.remove(folder.items, data.index)
                    table.insert(folder.items, index, data.ti)
                  else
                    -- Drag-and-drop between folders drops a new item
                    -- in the "index" position of this folder
                    table.insert(folder.items, index, data.ti)
                  end
                  activeLayer.properties(PK).categories = categories
                  imi.repaint = true
                end
              end

              imi.widget.checked = false
              imi.popID()
            end
            imi.endViewport()
          end
          imi.popID()
        end
      end
    end
  end
end

local function Sprite_change(ev)
  local repaint = ev.fromUndo

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
        repaint = true
      end
    else
      activeTileImageInfo = {}
    end
  end

  if repaint then
    imi.dlg:repaint()
  end
end

local function canvas_onwheel(ev)
  if ev.ctrlKey then
    if ev.shiftKey then
      zoom = zoom - ev.deltaY/2.0
    else
      zoom = zoom - ev.deltaY/32.0
    end
    if zoom < 0.5 then zoom = 0.5 end
    dlg:repaint()
  else
    if #imi.mouseWidgets > 0 then
      local widget = imi.mouseWidgets[1]
      if widget.scrollPos then
        local dx = ev.deltaY
        if ev.shiftKey then
          dx = widget.bounds.width*3/4*dx
        else
          dx = 64*dx
        end
        widget.scrollPos.x = widget.scrollPos.x + dx
        if widget.scrollPos.x < 0 then
          widget.scrollPos.x = 0
        end
        dlg:repaint()
      end
    end
  end
end

local function canvas_ontouchmagnify(ev)
  zoom = zoom + zoom*ev.magnification
  if zoom < 0.5 then zoom = 0.5 end
  dlg:repaint()
end

local function Sprite_remaptileset(ev)
  -- If the action came from an undo/redo, the properties are restored
  -- automatically to the old/new value, we don't have to readjust
  -- them.
  if not ev.fromUndo and activeLayer then
    local layerProperties = get_layer_properties(activeLayer)
    local categories = layerProperties.categories

    for _,category in ipairs(categories) do
      for _,folder in ipairs(category.folders) do
        local newItems = {}
        for k=1,#folder.items do
          newItems[k] = ev.remap[folder.items[k]]
        end
        folder.items = newItems
      end
    end

    -- This generates the undo information for first time in the
    -- current transaction (within the Remap command)
    activeLayer.properties(PK).categories = categories
    dlg:repaint()
  end
end

local function unobserve_sprite()
  if observedSprite then
    observedSprite.events:off(Sprite_change)
    observedSprite.events:off(Sprite_remaptileset)
    observedSprite = nil
  end
end

local function observe_sprite(spr)
  unobserve_sprite()
  observedSprite = spr
  if observedSprite then
    observedSprite.events:on('change', Sprite_change)
    observedSprite.events:on('remaptileset', Sprite_remaptileset)
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
      do
        local index = defaultVisibleCategory[activeLayer.id]
        if index == nil then
          index = 1
        end
        showCategoryRadio = { value=index }
      end

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

local function dialog_onclose()
  unobserve_sprite()
  app.events:off(App_sitechange)
  dlg = nil
end

local function AttachmentWindow_SwitchWindow()
  if app.apiVersion < 21 then return app.alert "The Attachment System plugin needs Aseprite v1.3.0-rc1" end

  if dlg then
    dlg:close()
  else
    dlg = Dialog{
        title=title,
        onclose=dialog_onclose
      }
      :canvas{ id="canvas",
               width=400, height=300,
               onpaint=imi.onpaint,
               onmousemove=imi.onmousemove,
               onmousedown=imi.onmousedown,
               onmouseup=imi.onmouseup,
               onwheel=canvas_onwheel,
               ontouchmagnify=canvas_ontouchmagnify }
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
