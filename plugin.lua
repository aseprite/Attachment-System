-- Aseprite Attachment System
-- Copyright (c) 2022-2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.
----------------------------------------------------------------------
-- Extension Properties:
--
-- Sprite = {
--   version = 1
-- }
--
-- Tileset = {            -- A tileset represents a category for one layer
--   id = categoryID,     -- Tileset/category ID, referenced by layers that can use this category/tileset
-- }
--
-- Layer = {
--   categories={ categoryID1, categoryID2, etc. },
--   folders={
--     { name="Folder Name",
--       items={ tileIndex1, tileIndex2, ... },
--       viewport=Size(columns, rows) }
--   },
-- }
--
-- Tile 1st approach (used on git branch: issue-18-1)
-- Tile = {
--   pivot=Point(0, 0),
-- }
-- Tile 2nd approach (used on git branch: issue-18-2)
-- Tile = {
--   referencePoint=Point(0, 0),
--   anchors={ { name="name 1", position=Point(0, 0)},
--             { name="name 2", position=Point(0, 0)},
--              ... }
--   },
-- }
----------------------------------------------------------------------

local imi = dofile('./imi.lua')

-- Plugin-key to access extension properties in layers/tiles/etc.
-- E.g. layer.properties(PK)
local PK = "aseprite/Attachment-System"

-- Constants names
local kBaseSetName = "Base Set"
local kUnnamedCategory = "(Unnamed)"

-- The main window/dialog
local dlg
local title = "Attachment System"
local observedSprite
local activeLayer         -- Active tilemap (nil if the active layer isn't a tilemap)
local shrunkenBounds = {} -- Minimal bounds between all tiles of the active layer
local tilesHistogram = {} -- How many times each tile is used in the active layer
local activeTileImageInfo = {} -- Used to re-calculate info when the tile image changes
local showTilesID = false
local showTilesUsage = false
local zoom = 1.0
local anchorPopup -- dialog for Add/Remove anchor points
local anchorChecksEntriesPopup = nil -- dialog por Checks and Entry widgets for anchor points
local tempLayers = {}  -- vector of temporary layers where anchor point are drawn
local anchorCrossImage  -- crosshair to anchor points -full opacity-
local anchorCrossImageT -- crosshair to anchor points -with transparency-
local tempLayersLock = false -- tempLayers cannot be modified during App_sitechange

if anchorCrossImage == nil then
  anchorCrossImage = Image(3, 3)
  anchorCrossImage:drawPixel(1, 0, Color(0,0,0))
  anchorCrossImage:drawPixel(0, 1, Color(0,0,0))
  anchorCrossImage:drawPixel(2, 1, Color(0,0,0))
  anchorCrossImage:drawPixel(1, 2, Color(0,0,0))
  anchorCrossImage:drawPixel(1, 1, Color(255,0,0))
end

if anchorCrossImageT == nil then
  anchorCrossImageT = Image(3, 3)
  local opacity = 128
  anchorCrossImageT:drawPixel(1, 0, Color(0,0,0, opacity))
  anchorCrossImageT:drawPixel(0, 1, Color(0,0,0, opacity))
  anchorCrossImageT:drawPixel(2, 1, Color(0,0,0, opacity))
  anchorCrossImageT:drawPixel(1, 2, Color(0,0,0, opacity))
  anchorCrossImageT:drawPixel(1, 1, Color(255,0,0, opacity))
end


local function contains(t, item)
  for _,v in pairs(t) do
    if v == item then
      return true
    end
  end
  return false
end

local function find_index(t, item)
  for i,v in pairs(t) do
    if v == item then
      return i
    end
  end
  return nil
end

local function set_zoom(z)
  zoom = imi.clamp(z, 0.5, 10.0)
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

local function calculate_shrunken_bounds_from_tileset(tileset)
  local bounds = Rectangle()
  local ntiles = #tileset
  for i = 0,ntiles-1 do
    local tileImg = tileset:getTile(i)
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

local function remap_tiles_in_tilemap_layer_delete_index(tilemapLayer, deleteTi)
  for _,cel in ipairs(tilemapLayer.cels) do
    local ti = cel.image:getPixel(0, 0)
    if ti >= deleteTi then
      local tilemapCopy = Image(cel.image)
      tilemapCopy:putPixel(0, 0, ti-1)
      cel.image:drawImage(tilemapCopy)
    end
  end
end

local function calculate_new_category_id(spr)
  local maxId = 0
  for i=1,#spr.tilesets do
    local tileset = spr.tilesets[i]
    if tileset and tileset.properties(PK).id then
      maxId = math.max(maxId, tileset.properties(PK).id)
    end
  end
  return maxId+1
end

local function find_tileset_by_categoryID(spr, categoryID)
  for i=1,#spr.tilesets do
    local tileset = spr.tilesets[i]
    if tileset and tileset.properties(PK).id == categoryID then
      return tileset
    end
  end
  return nil
end

local function find_tileset_by_name(spr, name)
  for i=1,#spr.tilesets do
    local tileset = spr.tilesets[i]
    if tileset and tileset.name == name then
      return tileset
    end
  end
  return nil
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

local function get_active_tile_index()
  if activeLayer and activeLayer.isTilemap then
    local cel = activeLayer:cel(app.activeFrame)
    if cel and cel.image then
      return cel.image:getPixel(0, 0)
    end
  end
  return nil
end

local function create_base_set_folder(layer)
  local items = {}
  for i=1,#layer.tileset-1 do
    table.insert(items, i)
  end
  return { name=kBaseSetName, items=items }
end

local function is_base_set_folder(folder)
  return (folder.name == kBaseSetName)
end

local function get_base_set_folder(folders)
  for _,folder in ipairs(folders) do
    if is_base_set_folder(folder) then
      return folder
    end
  end
  folder = create_base_set_folder(activeLayer)
  table.insert(folders, folder)
  return folder
end

-- These properties should be set in setup_layers()/setup_sprite(),
-- but we can set them here just in case. Anyway if the setup
-- functions don't fully setup the properties, we'll generate
-- undo/redo information just showing the layer in the Attachment
-- System window
local function get_layer_properties(layer)
  local properties = layer.properties(PK)
  if not properties.categories then
    properties.categories = {}
  end
  local id = layer.tileset.properties(PK).id
  if not id then
    id = calculate_new_category_id(layer.sprite)
    layer.tileset.properties(PK).id = id
  end
  if not contains(properties.categories, id) then
    table.insert(properties.categories, id)
  end
  if not properties.folders or #properties.folders == 0 then
    properties.folders = { create_base_set_folder(layer) }
  end
  return properties
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

local function setup_layers(layers)
  for _,layer in ipairs(layers) do
    if layer.isTilemap then
      local id = layer.tileset.properties(PK).id
      local categories = layer.properties(PK).categories
      local folders = layer.properties(PK).folders

      if not categories then
        categories = { }
      end
      if not contains(categories, id) then
        table.insert(categories, id)
        layer.properties(PK).categories = categories
      end

      if not folders or #folders == 0 then
        layer.properties(PK).folders = { create_base_set_folder(layer) }
      end
    end
    if layer.isGroup then
      setup_layers(layer.layers)
    end
  end
end

local function setup_sprite(spr)
  -- Setup the sprite DB
  spr.properties(PK).version = 1
  for i=1,#spr.tilesets do
    local tileset = spr.tilesets[i]
    if tileset then
      tileset.properties(PK).id = calculate_new_category_id(spr)
    end
  end
  setup_layers(spr.layers)
end

-- Activates the next cel in the active layer where the given
-- attachment (ti) is used.
local MODE_FORWARD = 0
local MODE_BACKWARDS = 1
local function find_next_attachment_usage(ti, mode)
  if not app.activeFrame then return end

  local iniFrame = app.activeFrame.frameNumber
  local prevMatch = nil
  local istart, iend, istep
  local isPrevious

  if mode == MODE_BACKWARDS then
    istart = #activeLayer.cels
    iend = 1
    istep = -1
    isPrevious = function(frameNum) return frameNum >= iniFrame end
  else
    istart = 1
    iend = #activeLayer.cels
    istep = 1
    isPrevious = function(frameNum) return frameNum <= iniFrame end
  end

  local cels = activeLayer.cels
  for i=istart,iend,istep do
    local cel = cels[i]
    if isPrevious(cel.frameNumber) and prevMatch then
      -- Go to next/prev frame...
    elseif cel.image then
      -- Check if this is cel is an instance of the given attachment (ti)
      local celTi = cel.image:getPixel(0, 0)
      if celTi == ti then
        if isPrevious(cel.frameNumber) then
          prevMatch = cel
        else
          app.activeCel = cel
          return
        end
      end
    end
  end
  if prevMatch then
    app.activeCel = prevMatch
  end
end

local function show_tile_context_menu(ts, ti, folders, folder, indexInFolder)
  local popup = Dialog{ parent=imi.dlg }
  local spr = activeLayer.sprite
  anchorChecksEntriesPopup = Dialog{ title="Anchors List" }

  local function find_tiles_on_sprite()
    if not(activeLayer.isTilemap) then
      app.alert("Error: active Layer isn't Tilemap or Cel is empty.")
      return nil
    elseif app.activeCel == nil then
      return {}
    end
    local cel = app.activeCel
    local tileSize = ts.grid.tileSize
    local tileBoundsOnSprite = {}
    for y=0, spr.bounds.height, 1 do
      for x=0, spr.bounds.width, 1 do
        if ti == cel.image:getPixel(x, y) then
          table.insert(tileBoundsOnSprite, Rectangle(cel.position.x + x*tileSize.width,
                                            cel.position.y + y*tileSize.height,
                                            tileSize.width, tileSize.height))
        end
      end
    end
    return tileBoundsOnSprite
  end

  -- Variables and Functions associated to editAnchors() and editTile()

  local instanceOn -- "sprite" / "new_sprite" / "multiple_tile_instances"
  local originalLayer = activeLayer
  local originalCanvasBounds
  local tempSprite
  local layerEditableStates = {}

  local function lockLayers()
    for i=1,#spr.layers, 1 do
      table.insert(layerEditableStates, { editable=spr.layers[i].isEditable,
                                          opacity=spr.layers[i].opacity })
      if spr.layers[i] ~= originalLayer then
        spr.layers[i].opacity = 64
      end
      spr.layers[i].isEditable = false
    end
  end

  local function unlockLayers()
    for i=1,#layerEditableStates, 1 do
      spr.layers[i].isEditable = layerEditableStates[i].editable
      spr.layers[i].opacity = layerEditableStates[i].opacity
    end
  end

  local function editAnchors()
    app.transaction(
      function()
        instanceOn = "new_sprite" -- "sprite" / "new_sprite" / "multiple_tile_instances"
        originalCanvasBounds = dlg.bounds
        tempLayers = {}
        layerEditableStates = {}
        oldAnchors = {}
        local originalTool = app.activeTool.id

        local function cancel()
          anchorChecksEntriesPopup:close()
          tempLayersLock = true
          for i=1, #tempLayers, 1 do
            app.activeSprite:deleteLayer(tempLayers[i])
          end
          if tempSprite ~= nil then
            tempSprite:close()
          end
          app.command.AdvancedMode{}
          unlockLayers()
          dlg.bounds = originalCanvasBounds
          app.activeLayer = originalLayer
          app.activeTool = originalTool
          tempLayersLock = false
        end

        anchorPopup = Dialog{ title="Anchor Points", onclose=cancel}

        local function addTempLayers(sprite, tileBounds)
          anchors = ts:tile(ti).properties(PK).anchors
          if anchors ~= nil then
            -- make all the anchors point in separate layers
            for i=1, #anchors, 1 do
              table.insert(tempLayers, sprite:newLayer())
              local anchorPos = anchors[i].position
              local pos = anchorPos + tileBounds.origin- Point(anchorCrossImage.width / 2, anchorCrossImage.height / 2)
              sprite:newCel(tempLayers[i], app.activeFrame, anchorCrossImage, pos)
              tempLayers[i].name = "anchor_" .. i
            end
          end
        end

        local function refreshTempLayers()
          tempLayersLock = true
          for i=1, #tempLayers, 1 do
            local key_number = string.match(tempLayers[i].name, "%d")
            local c_key = "c_" .. key_number
            if anchorChecksEntriesPopup.data[c_key] then
              tempLayers[i].cels[1].image = anchorCrossImage
            else
              tempLayers[i].cels[1].image = anchorCrossImageT
            end
          end
          app.refresh()
          tempLayersLock = false
        end

        local function regenerateAnchorChecksEntriesPopup()
          tempLayersLock = true
          local checkEntryPairs = {}
          for i=1, #tempLayers, 1 do
            local key_number = string.match(tempLayers[i].name, "%d")
            local c_key = "c_" .. key_number
            local e_key = "e_" .. key_number
            table.insert(checkEntryPairs, {c=anchorChecksEntriesPopup.data[c_key],
                                           e=anchorChecksEntriesPopup.data[e_key]} )
            tempLayers[i].name = "anchor_" .. i
           end
          anchorChecksEntriesPopup:close()
          anchorChecksEntriesPopup = Dialog()
          if #checkEntryPairs >=1 then
            for i=1, #tempLayers, 1 do
              anchorChecksEntriesPopup:check{ id="c_" .. i,
                                              selected=checkEntryPairs[i].c,
                                              onclick=refreshTempLayers }
              anchorChecksEntriesPopup:entry{ id="e_" .. i, text=checkEntryPairs[i].e }
              if checkEntryPairs[i].c then
                tempLayers[i].cels[1].image = anchorCrossImage
              else
                tempLayers[i].cels[1].image = anchorCrossImageT
              end
            end
            anchorChecksEntriesPopup:show{ wait=false }
            anchorChecksEntriesPopup.bounds = Rectangle(anchorPopup.bounds.x,
                                                        85*imi.uiScale,
                                                        200*imi.uiScale,
                                                        anchorChecksEntriesPopup.bounds.height)
          end
          app.refresh()
          tempLayersLock = false
        end

        local function removeAnchorPoint(sprite)
          tempLayersLock = true
          local new_tempLayers = {}
          local layers_to_delete = {}
          local tempLayersCopy = {}
          for i=1, #tempLayers, 1 do
            local key = "c_" .. i
            table.insert(tempLayersCopy, tempLayers[i])
            if anchorChecksEntriesPopup.data[key] then
              table.insert(layers_to_delete, i)
            else
              table.insert(new_tempLayers, i)
            end
          end
          for i=1, #layers_to_delete, 1 do
            sprite:deleteLayer(tempLayers[layers_to_delete[i]])
          end
          tempLayers = {}
          for i=1, #new_tempLayers, 1 do
            table.insert(tempLayers, tempLayersCopy[new_tempLayers[i]])
          end
          tempLayersLock = false
          regenerateAnchorChecksEntriesPopup()
        end

        local function addAnchorPoint(sprite, tileBounds)
          tempLayersLock = true
          local new_layer = sprite:newLayer()
          local layer_number
          if #tempLayers >= 1 then
            layer_number = string.match(tempLayers[#tempLayers].name, "%d") + 1
          else
            layer_number = 1
          end
          new_layer.name = "anchor_" .. layer_number
          table.insert(tempLayers, new_layer)
          local anchorPos = Point(tileBounds.width/2, tileBounds.height/2)
          local pos = anchorPos + tileBounds.origin - Point(anchorCrossImage.width / 2, anchorCrossImage.height / 2)
          sprite:newCel(tempLayers[#tempLayers], app.activeFrame, anchorCrossImage, pos)
          tempLayersLock = false
          regenerateAnchorChecksEntriesPopup()
        end

        local function turnToeditAnchorsView()
          local temp = app.preferences.advanced_mode.show_alert
          app.preferences.advanced_mode.show_alert = false
          app.command.AdvancedMode{}
          app.command.AdvancedMode{}
          app.preferences.advanced_mode.show_alert = temp
          dlg.bounds = Rectangle(0, 0, 1, 1)
          app.activeTool = "move"
        end

        local function fillEntries()
          local anchors = ts:tile(ti).properties(PK).anchors
          for i=1, #tempLayers - 1, 1 do
            local key_number = string.match(tempLayers[i].name, "%d")
            local e_key = "e_" .. key_number
            local c_key = "c_" .. key_number
            anchorChecksEntriesPopup:modify { id=e_key,
                                              text=anchors[i].name }
            anchorChecksEntriesPopup:modify { id=c_key,
                                              selected=false }
            tempLayers[i].cels[1].image = anchorCrossImageT
          end
          if #tempLayers >=1 then
            anchorChecksEntriesPopup:modify { id="e_" .. #tempLayers,
                                              text=anchors[#tempLayers].name }
            anchorChecksEntriesPopup:modify { id="c_" .. #tempLayers,
                                              selected=true }
            tempLayers[#tempLayers].cels[1].image = anchorCrossImage
          end
          app.refresh()
        end

        local tileBoundsOnSprite = find_tiles_on_sprite()
        if tileBoundsOnSprite == nil then
          return
        elseif #tileBoundsOnSprite == 0 then
          instanceOn = "new_sprite"
          local gridSize = ts.grid.tileSize
          local tileBounds = Rectangle(0, 0, gridSize.width, gridSize.height )
          tempSprite = Sprite(tileBounds.width, tileBounds.height)
          tempSprite.cels[1].image = ts:tile(ti).image
          table.insert(tileBoundsOnSprite, tempSprite.cels[1].image.bounds)
          addTempLayers(tempSprite, tileBounds)
          app.command.FitScreen{}
          app.refresh()
        elseif #tileBoundsOnSprite >= 1 then
          local tileBounds = tileBoundsOnSprite[1]
          instanceOn = "sprite"
          lockLayers()
          addTempLayers(spr, tileBounds)
        --else -- multiple tileBoundsOnSprite
          --TODO: include in the New Anchor Poin dialog an instance selector
          -- instanceOn = "multiple_tile_instances"
        end
        turnToeditAnchorsView()

        local function backToSprite()
          anchorPopup:close()
        end

        local function acceptPoints()
          local tileProperty = originalLayer.tileset:tile(ti).properties(PK)
          local tileBounds = tileBoundsOnSprite[1]
          tileProperty.anchors = {}

          local tempAnchors = {}
          for i=1, #tempLayers, 1 do
            local e_key = "e_" .. i
            local nameValue = anchorChecksEntriesPopup.data[e_key]
            local posValue = tempLayers[i].cels[1].position - tileBounds.origin +
                             Point(anchorCrossImage.width / 2, anchorCrossImage.height / 2)
            -- table.insert(tileProperty.anchors, { name = nameValue, position = posValue })
            table.insert(tempAnchors, { name = nameValue, position = posValue })
          end
          tileProperty.anchors = tempAnchors
          backToSprite()
        end

        anchorPopup:button{ text="Add Anchor", onclick= function()
                                                          if instanceOn == "new_sprite" then
                                                            addAnchorPoint(tempSprite, tileBoundsOnSprite[1])
                                                          else
                                                            addAnchorPoint(spr, tileBoundsOnSprite[1])
                                                          end
                                                        end }
        anchorPopup:button{ text="Remove Anchor", onclick=function()
                                                            if instanceOn == "new_sprite" then
                                                              removeAnchorPoint(tempSprite)
                                                            else
                                                              removeAnchorPoint(spr)
                                                            end
                                                          end }
        anchorPopup:newrow()
        anchorPopup:button{ text="Cancel", onclick=function() anchorPopup:close() end }
        anchorPopup:button{ text="OK", onclick=acceptPoints }:newrow()
        anchorPopup:label{ text="To move anchors:"}:newrow()
        anchorPopup:label{ text="Hold CTRL, click and move" }
        regenerateAnchorChecksEntriesPopup()
        fillEntries()
        anchorPopup:show{
          wait=false,
          bounds=Rectangle(0, 0, 200*imi.uiScale, 85*imi.uiScale)
        }
        popup:close()
        dlg.bounds = Rectangle(0, 0, 1, 1)
      end)
  end

  local function editTile()
    app.transaction(
      function()
        instanceOn = "new_sprite" -- "sprite" / "new_sprite" / "multiple_tile_instances"
        originalLayer = activeLayer
        originalCanvasBounds = dlg.bounds
        layerEditableStates = {}
        local originalLayersOpacity = {}

        local function cancel()
          if tempSprite ~= nil then
            tempSprite:close()
          end
          dlg.bounds = originalCanvasBounds
        end

        local editTilePopup = Dialog{ title="Edit Tile", onclose=cancel }
        editTilePopup:label{ text="When finish press OK" }
        local tileShrunkenBounds = calculate_shrunken_bounds_from_tileset(ts)
        local tileSize = ts.grid.tileSize
        tempSprite = Sprite(tileSize.width, tileSize.height)
        local palette = spr.palettes[1]
        tempSprite.palettes[1]:resize(#palette)
        for i=0, #palette-1, 1 do
          tempSprite.palettes[1]:setColor(i, palette:getColor(i))
        end
        tempSprite.cels[1].image = ts:tile(ti).image

        local function accept()
          if tempSprite ~= nil then
            local image = Image(ts:tile(ti).image.width, ts:tile(ti).image.height)
            image:drawImage(app.activeCel.image, app.activeCel.position)
            ts:tile(ti).image = image
          end
          editTilePopup:close()
        end

        editTilePopup:button{ text="Cancel", onclick=function() editTilePopup:close() end }
        editTilePopup:button{ text="OK", onclick=accept }:newrow()
        editTilePopup:show{ wait=false }
        editTilePopup.bounds = Rectangle(120*imi.uiScale,
                                         60*imi.uiScale,
                                         editTilePopup.bounds.width,
                                         editTilePopup.bounds.height)
        popup:close()
        dlg.bounds = Rectangle(0, 0, 1, 1)
        app.refresh()
      end)
  end

  local function forEachCategoryTileset(func)
    for i,categoryID in ipairs(activeLayer.properties(PK).categories) do
      local catTileset = find_tileset_by_categoryID(spr, categoryID)
      func(catTileset)
    end
  end

  local function addInFolderAndBaseSet(ti)
    if folder then
      table.insert(folder.items, ti)
    end
    -- Add the tile in the Base Set folder (always)
    if not folder or not is_base_set_folder(folder) then
      local baseSet = get_base_set_folder(folders)
      table.insert(baseSet.items, ti)
    end
    activeLayer.properties(PK).folders = folders
  end

  local function newEmpty()
    app.transaction("New Empty Attachment",
      function()
        local tile
        forEachCategoryTileset(
          function(ts)
            local t = spr:newTile(ts)
            if tile == nil then
              tile = t
            else
              assert(t.index == t.index)
            end
          end)

        if tile then
          addInFolderAndBaseSet(tile.index)
        end
      end)
    popup:close()
  end

  local function duplicate()
    local origTile = ts:tile(ti)
    app.transaction("Duplicate Attachment",
      function()
        local tile
        forEachCategoryTileset(
          function(ts)
            tile = spr:newTile(ts)
            tile.image:clear()
            tile.image:drawImage(ts:tile(ti).image)
        end)
        if tile then
          addInFolderAndBaseSet(tile.index)
        end
      end)
    popup:close()
  end

  local function delete()
    table.remove(folder.items, indexInFolder)
    app.transaction("Delete Folder", function()
     activeLayer.properties(PK).folders = folders
    end)
    popup:close()
  end

  -- Select all the active layers' frames where the selected attachment is used.
  local function selectFrames()
    local frames = {}
    for _,cel in ipairs(activeLayer.cels) do
      if cel.image then
        local celTi = cel.image:getPixel(0, 0)
        if celTi == ti then
          table.insert(frames, cel.frameNumber)
        end
      end
    end
    if #frames > 0 then
      app.range.frames = frames
    end
  end

  popup:menuItem{ text="Edit Anchors", onclick=editAnchors }:newrow()
  popup:menuItem{ text="Edit Tile", onclick=editTile }:newrow()
  popup:separator():newrow()
  popup:menuItem{ text="New Empty", onclick=newEmpty }:newrow()
  popup:menuItem{ text="Duplicate", onclick=duplicate }:newrow()
  popup:separator()
  popup:menuItem{ text="Select usage", onclick=selectFrames }:newrow()
  popup:menuItem{ text="Find next usage", onclick=function() find_next_attachment_usage(ti, MODE_FORWARD) end }:newrow()
  popup:menuItem{ text="Find prev usage", onclick=function() find_next_attachment_usage(ti, MODE_BACKWARDS) end }:newrow()
  popup:separator()
  popup:menuItem{ text="Delete", onclick=delete }
  popup:showMenu()
  imi.repaint = true
end

local function create_tile_view(folders, folder, index, ts, ti, inRc, outSize)
  imi.pushID(index)
  local tileImg = ts:getTile(ti)
  imi.image(tileImg, inRc, outSize)
  local imageWidget = imi.widget

  imi.widget.onmousedown = function(widget)
    -- Context menu
    if imi.mouseButton == MouseButton.RIGHT then
      show_tile_context_menu(ts, ti, folders, folder, index)
    end
  end

  if imi.widget.checked then
    imi.widget.checked = false
  end

  if showTilesID then
    imi.alignFunc = function(cursor, size, lastBounds)
      return Point(lastBounds.x+2,
                   lastBounds.y+lastBounds.height-size.height-2)
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
      return Point(lastBounds.x+2,
                   lastBounds.y+2)
    end
    imi.label(label)
    imi.widget.color = Color(255, 255, 0)
    imi.alignFunc = nil
  end

  if ts:tile(ti).properties(PK).referencePoint == nil then
    imi.alignFunc = function(cursor, size, lastBounds)
      return Point(lastBounds.x+lastBounds.width-size.width-2,
                   lastBounds.y+2)
    end
    imi.label("R")
    imi.widget.color = Color(255, 0, 0)
    imi.alignFunc = nil
  end

  imi.popID()
  imi.widget = imageWidget
end

local function new_or_rename_category_dialog(categoryTileset)
  local name = ""
  local title
  if categoryTileset then
    title = "Rename Category"
    name = categoryTileset.name
  else
    title = "New Category"
  end
  local popup =
    Dialog{ title=title, parent=imi.dlg }
    :entry{ id="name", label="Name:", text=name, focus=true }
    :button{ id="ok", text="OK", focus=true }
    :button{ id="cancel", text="Cancel" }
  popup:show()
  local data = popup.data
  if data.ok and data.name ~= "" then
    if categoryTileset then
      app.transaction("Rename Category", function()
        categoryTileset.name = data.name
      end)
    else
      local spr = activeLayer.sprite

      -- Check that we cannot create two tilesets with the same name
      if find_tileset_by_name(spr, data.name) then
        return app.alert("A category named '" .. data.name .. "' already exist. " ..
                         "You cannot have two categories with the same name")
      end

      local id = calculate_new_category_id(spr)
      app.transaction("New Category", function()
        local cloned = spr:newTileset(activeLayer.tileset)
        cloned.properties(PK).id = id
        cloned.name = data.name

        local categories = activeLayer.properties(PK).categories
        if not categories then categories = {} end
        table.insert(categories, id)
        activeLayer.properties(PK).categories = categories
        activeLayer.tileset = cloned
        app.refresh()
      end)
    end
  end
end

local function show_categories_selector(categories, activeTileset)
  local spr = app.activeSprite
  local categories = activeLayer.properties(PK).categories

  function rename()
    new_or_rename_category_dialog(activeTileset)
  end

  function delete()
    app.transaction("Delete Category", function()
      if categories then
        local catID = activeTileset.properties(PK).id
        local catIndex = find_index(categories, catID)

        -- Remove the category/tileset
        table.remove(categories, catIndex)
        activeLayer.properties(PK).categories = categories

        -- We set the tileset of the layer to the first category available
        local newTileset = find_tileset_by_categoryID(spr, categories[1])
        local oldTileset = activeLayer.tileset
        activeLayer.tileset = newTileset

        -- Delete tileset from the sprite
        spr:deleteTileset(oldTileset)

        app.refresh()
      end
    end)
  end

  local popup = Dialog{ parent=imi.dlg }
  if categories and #categories > 0 then
    for i,categoryID in ipairs(categories) do
      local catTileset = find_tileset_by_categoryID(spr, categoryID)
      if catTileset == nil then assert(false) end

      local checked = (categoryID == activeTileset.properties(PK).id)
      local name = catTileset.name
      if name == "" then name = kUnnamedCategory end
      popup:menuItem{ text=name, focus=checked,
                      onclick=function()
                        popup:close()
                        app.transaction("Select Category",
                          function()
                            activeLayer.tileset = find_tileset_by_categoryID(spr, categoryID)
                          end)
                        app.refresh()
                      end }:newrow()
    end
    popup:separator()
  end
  popup:menuItem{ text="New Category",
                  onclick=function()
                    popup:close()
                    new_or_rename_category_dialog()
                    imi.repaint = true
                  end }
  popup:menuItem{ text="Rename Category", onclick=rename }
  if #categories > 1 then
    popup:menuItem{ text="Delete Category", onclick=delete }
  end
  popup:showMenu()
end

local function new_or_rename_folder_dialog(folder)
  local name = ""
  local title
  if folder then
    title = "Rename Folder"
    name = folder.name
  else
    title = "New Folder"
  end
  local popup =
    Dialog{ title=title, parent=dlg }
    :entry{ id="name", label="Name:", text=name, focus=true }
    :button{ id="ok", text="OK", focus=true }
    :button{ id="cancel", text="Cancel" }
  popup:show()
  local data = popup.data
  if data.ok and data.name ~= "" then
    if folder then
      folder.name = data.name
      return folder
    else
      return {
        name=data.name,
        items={ },
      }
    end
  else
    return nil
  end
end

local function show_folder_context_menu(folders, folder)
  local function sortByIndex()
    table.sort(folder.items, function(a, b) return a < b end)
    app.transaction("Sort Folder", function()
      activeLayer.properties(PK).folders = folders
    end)
  end

  local function rename()
    folder = new_or_rename_folder_dialog(folder)
    app.transaction("Rename Folder", function()
      activeLayer.properties(PK).folders = folders
    end)
  end

  local function delete()
    local folderIndex = 0
    for i,f in ipairs(folders) do
      if f == folder then
        folderIndex = i
        break
      end
    end
    if folderIndex > 0 then
      table.remove(folders, folderIndex)
      app.transaction("Delete Folder", function()
        activeLayer.properties(PK).folders = folders
      end)
    end
  end

  local popup = Dialog{ parent=imi.dlg }
  popup:menuItem{ text="Sort by Tile Index/ID", onclick=sortByIndex }
  if not is_base_set_folder(folder) then
    popup:separator()
    popup:menuItem{ text="Rename Folder", onclick=rename }
    popup:menuItem{ text="Delete Folder", onclick=delete }
  end
  popup:showMenu()
end

local function show_options(rc)
  local popup = Dialog{ parent=imi.dlg }
  popup:menuItem{ text="Show Usage", onclick=function() showTilesUsage = not showTilesUsage end,
                  selected=showTilesUsage }:newrow()
  popup:menuItem{ text="Show tile ID/Index", onclick=function() showTilesID = not showTilesID end,
                  selected=showTilesID }
  popup:showMenu()
  imi.repaint = true
end

local function imi_ongui()
  local spr = app.activeSprite
  if not spr then
    dlg:modify{ title=title }

    imi.ctx.color = app.theme.color.text
    imi.label("No sprite")
  elseif not spr.properties(PK).version or
         spr.properties(PK).version < 1 then
    imi.sameLine = true
    if imi.button("Setup Sprite") then
      app.transaction("Setup Attachment System",
                      function() setup_sprite(spr) end)
      imi.repaint = true
    end
  else
    dlg:modify{ title=title .. " - " .. app.fs.fileTitle(spr.filename) }
    if activeLayer then
      local layerProperties = get_layer_properties(activeLayer)
      local categories = layerProperties.categories
      local folders = layerProperties.folders

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

      -- Active Category / Categories
      imi.sameLine = true
      local activeTileset = activeLayer.tileset
      local name = activeTileset.name
      if name == "" then name = kUnnamedCategory end
      if imi.button(name) then
        -- Show popup to select other category
        imi.afterGui(
          function()
            show_categories_selector(categories, activeTileset)
          end)
      end
      imi.widget.onmousedown = function(widget) -- TODO merge this with regular imi.button() click
        if imi.mouseButton == MouseButton.RIGHT then
          show_categories_selector(categories, activeTileset)
        end
      end

      if imi.button("New Folder") then
        imi.afterGui(
          function()
            local folder = new_or_rename_folder_dialog()
            if folder then
              table.insert(folders, folder)
              activeLayer.properties(PK).folders = folders
            end
            imi.repaint = true
          end)
      end

      imi.space(2*imi.uiScale)
      if imi.button("Options") then
        imi.afterGui(show_options)
      end

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

        -- Context menu for active tile
        imi.widget.onmousedown = function(widget)
          if imi.mouseButton == MouseButton.RIGHT then
            show_tile_context_menu(ts, ti)
          end
        end

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
      end

      -- Folders

      imi.rowHeight = 0


      -- TODO: Replace the 10 used here by the corresponding viewport border height+dialog bottom border height.
      local barSize = app.theme.dimension.mini_scrollbar_size
      imi.pushViewport(Rectangle(imi.cursor.x, imi.cursor.y,
                                 imi.viewport.width - imi.cursor.x,
                                 imi.viewport.height - imi.cursor.y - (10*imi.uiScale + barSize)))
      imi.beginViewport(imi.viewport.size)

      for i,folder in ipairs(folders) do
        imi.pushID(i .. folder.name)
        imi.sameLine = true
        imi.breakLines = true

        imi.beginGroup()
        imi.sameLine = false
        local openFolder = imi.toggle(folder.name)

        -- Context menu for active folder
        imi.widget.onmousedown = function(widget)
          if imi.mouseButton == MouseButton.RIGHT then
            show_folder_context_menu(folders, folder)
          end
        end

        if openFolder then
          -- One viewport for each opened folder
          local outSize2 = Size(outSize.width*3/4, outSize.height*3/4)
          imi.beginViewport(Size(imi.viewport.width,
                                 outSize2.height),
                            outSize2)

          -- If we are not resizing the viewport, we restore the
          -- viewport size stored in the folder
          if folder.viewport and not imi.widget.draggingResize then
            imi.widget.resizedViewport = folder.viewport
          end

          imi.widget.onviewportresized = function(size)
            app.transaction("Resize Folder", function()
              folder.viewport = Size(size.width, size.height)
              activeLayer.properties(PK).folders = folders
              imi.dlg:repaint()
            end)
          end

          if imi.beginDrop() then
            local data = imi.getDropData("tile")
            if data then
              if data.folder ~= folder.name then
                -- Drop a new item at the end of this folder
                table.insert(folder.items, data.ti)
                activeLayer.properties(PK).folders = folders
                imi.repaint = true
              end
            end
          end

          imi.sameLine = true
          imi.breakLines = false
          imi.margin = 0
          for index,ti in ipairs(folder.items) do
            imi.pushID(index)
            create_tile_view(folders, folder, index, activeLayer.tileset, ti, inRc, outSize2)

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
                activeLayer.properties(PK).folders = folders
                imi.repaint = true
              end
            end

            imi.widget.checked = false
            imi.popID()
          end
          imi.endViewport()
          imi.margin = 4*imi.uiScale
        end
        imi.endGroup()
        imi.popID()
      end

      imi.endViewport()
      imi.popViewport()
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
      set_zoom(zoom - ev.deltaY/2.0)
    else
      set_zoom(zoom - ev.deltaY/32.0)
    end
    dlg:repaint()
  else
    for i=#imi.mouseWidgets,1,-1 do
      local widget = imi.mouseWidgets[i]
      if widget.scrollPos and (widget.hasHBar or widget.hasVBar) then
        local dx = ev.deltaY
        local dy = 0
        if ev.shiftKey then
          dx = widget.bounds.width*3/4*dx
        else
          dx = 64*dx
        end
        if widget.hasVBar then
          dy = dx
          dx = 0
        end
        widget.setScrollPos(Point(widget.scrollPos.x + dx,
                                  widget.scrollPos.y + dy))
        dlg:repaint()
        break
      end
    end
  end
end

local function canvas_ontouchmagnify(ev)
  set_zoom(zoom + zoom*ev.magnification)
  dlg:repaint()
end

-- TODO this can be called from a background thread when we apply an
--      filter/effect to the tiles (called from Aseprite function
--      remove_unused_tiles_from_tileset())
local function Sprite_remaptileset(ev)
  -- If the action came from an undo/redo, the properties are restored
  -- automatically to the old/new value, we don't have to readjust
  -- them.
  if not ev.fromUndo and activeLayer then
    local spr = activeLayer.sprite
    local layerProperties = get_layer_properties(activeLayer)
    local categories = layerProperties.categories

    -- Remap all categories
    for _,categoryID in ipairs(categories) do
      local tileset = find_tileset_by_categoryID(spr, categoryID)
      -- TODO
    end

    -- Remap items in folders
    for _,folder in ipairs(layerProperties.folders) do
      local newItems = {}
      for k=1,#folder.items do
        newItems[k] = ev.remap[folder.items[k]]
      end
      folder.items = newItems
    end

    -- This generates the undo information for first time in the
    -- current transaction (within the Remap command)
    activeLayer.properties(PK).folders = folders
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

local function updateAnchorDialog()
  if #tempLayers >= 1 and not(tempLayersLock) then
    local selectedLayer = app.activeLayer
    for i=1, #tempLayers, 1 do
      if tempLayers[i] == selectedLayer then
        local layerIndex = string.match(selectedLayer.name, "%d")
        if layerIndex == nil then
          break
        end
        layerIndex = tonumber(layerIndex)
        for i=1, #tempLayers, 1 do
          if anchorChecksEntriesPopup.data["c_" .. i] ~= nil then
            if i==layerIndex then
                anchorChecksEntriesPopup:modify { id="c_" .. i, selected=true }
                tempLayers[i].cels[1].image = anchorCrossImage
            else
                anchorChecksEntriesPopup:modify { id="c_" .. i, selected=false }
                tempLayers[i].cels[1].image = anchorCrossImageT
            end
          end
        end
        app.refresh()
        break
      end
    end
  end
end

-- When the active site (active sprite, cel, frame, etc.) changes this
-- function will be called.
local function App_sitechange(ev)
  updateAnchorDialog()

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
               width=400*imi.uiScale, height=300*imi.uiScale,
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

local function AttachmentSystem_FindNext(mode)
  return function()
    local ti = get_active_tile_index()
    if ti then
      find_next_attachment_usage(ti, mode)
    end
  end
end

function init(plugin)
  plugin:newCommand{
    id="AttachmentSystem_SwitchWindow",
    title="Attachment System: Switch Window",
    group="view_new",
    onclick=AttachmentWindow_SwitchWindow
  }

  plugin:newCommand{
    id="AttachmentSystem_NextAttachmentUsage",
    title="Attachment System: Find next attachment usage",
    group="view_new",
    onclick=AttachmentSystem_FindNext(MODE_FORWARD)
  }

  plugin:newCommand{
    id="AttachmentSystem_PrevAttachmentUsage",
    title="Attachment System: Find previous attachment usage",
    group="view_new",
    onclick=AttachmentSystem_FindNext(MODE_BACKWARDS)
  }

  showTilesID = plugin.preferences.showTilesID
  showTilesUsage = plugin.preferences.showTilesUsage
  set_zoom(plugin.preferences.zoom)
end

function exit(plugin)
  plugin.preferences.showTilesID = showTilesID
  plugin.preferences.showTilesUsage = showTilesUsage
  plugin.preferences.zoom = zoom
end
