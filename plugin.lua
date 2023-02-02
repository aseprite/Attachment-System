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
--       viewport=Size(columns, rows),
--   },
--   parent="Layer Name",
--   anchorName="Anchor Name"  -- name of the anchor which the ref point of the tiles will be placed
-- }
-- Tile = {
--   ref=Point(x, y),
--   anchors={
--     { name="Anchor Name1",
--       position=Point(x1, y1)},
--   }
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
local anchorActionsDlg -- dialog for Add/Remove anchor points
local anchorListDlg = nil -- dialog por Checks and Entry widgets for anchor points
local oldAnchors = {} -- temporal buffer for saving anchors, children and dialog data
local oldAnchorCount = 0 -- temporal count of old anchors (before to eenter to 'editAnchors' function)
local tempLayerForRefPoint -- temporary layer where the reference point are drawn
local anchorCrossImage  -- crosshair to anchor points -full opacity-
local anchorCrossImageT -- crosshair to anchor points -with transparency-
local tempLayersLock = false -- tempLayers cannot be modified during App_sitechange
local black = Color(0,0,0)

local tempSprite

if anchorCrossImage == nil then
  anchorCrossImage = Image(3, 3)
  anchorCrossImage:drawPixel(1, 0, black)
  anchorCrossImage:drawPixel(0, 1, black)
  anchorCrossImage:drawPixel(2, 1, black)
  anchorCrossImage:drawPixel(1, 2, black)
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

if refCrossImage == nil then
  refCrossImage = Image(9, 9)
  refCrossImage:drawPixel(4, 0, black)
  refCrossImage:drawPixel(4, 1, black)
  refCrossImage:drawPixel(4, 3, black)
  refCrossImage:drawPixel(4, 5, black)
  refCrossImage:drawPixel(4, 7, black)
  refCrossImage:drawPixel(4, 8, black)

  refCrossImage:drawPixel(0, 4, black)
  refCrossImage:drawPixel(1, 4, black)
  refCrossImage:drawPixel(3, 4, black)
  refCrossImage:drawPixel(5, 4, black)
  refCrossImage:drawPixel(7, 4, black)
  refCrossImage:drawPixel(8, 4, black)

  refCrossImage:drawPixel(3, 3, Color(0,0,0,1))
  refCrossImage:drawPixel(3, 5, Color(0,0,0,1))
  refCrossImage:drawPixel(5, 3, Color(0,0,0,1))
  refCrossImage:drawPixel(5, 5, Color(0,0,0,1))

  refCrossImage:drawPixel(4, 4, Color(0,0,255))
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

local function show_tile_context_menu(ts, ti, folders, folder, indexInFolder)
  local popup = Dialog{ parent=imi.dlg }
  local spr = activeLayer.sprite

  -- Variables and Functions associated to editAnchors() and editTile()

  local originalLayer = activeLayer
  local originalCanvasBounds
  local layerEditableStates = {}
  local layersWereLocked = false
  local tempAttachment = nil -- temporal layer if the attchment isn't present on the sprite

  local function lockLayers()
    if not(layersWereLocked) then
      for i=1,#spr.layers, 1 do
        table.insert(layerEditableStates, { editable=spr.layers[i].isEditable,
                                            opacity=spr.layers[i].opacity,
                                            visible=spr.layers[i].isVisible })
        if spr.layers[i] ~= originalLayer then
          spr.layers[i].opacity = 64
        end
        spr.layers[i].isEditable = false
      end
      layersWereLocked = true
    end
  end

  local function unlockLayers()
    if layersWereLocked then
      for i=1,#layerEditableStates, 1 do
        spr.layers[i].isEditable = layerEditableStates[i].editable
        spr.layers[i].opacity = layerEditableStates[i].opacity
        spr.layers[i].isVisible = layerEditableStates[i].visible
      end
      layersWereLocked = false
    end
  end

  local function find_tiles_on_cel()
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
    if #tileBoundsOnSprite == 0 then
      local pos = Point((spr.width - ts:tile(ti).image.width)/2,
                        (spr.height - ts:tile(ti).image.height)/2)
      lockLayers()
      if originalLayer.properties(PK).parent ~= nil then
        -- Hide all the layers, except the parent
        for _,layer in ipairs(spr.layers) do
          if layer.name ~= originalLayer.properties(PK).parent then
            layer.isVisible = false
          end
        end
        for _,layer in ipairs(spr.layers) do
          if originalLayer.properties(PK).parent == layer.name then
            layer.opacity = 64
            break
          end
        end

      end
      tempAttachment = spr:newLayer()
      tempAttachment.name = "aux layer"
      spr:newCel(tempAttachment, app.activeFrame, ts:tile(ti).image, pos)
      tileBoundsOnSprite = { Rectangle(pos.x,
                                       pos.y,
                                       ts:tile(ti).image.width,
                                       ts:tile(ti).image.height) }
    end
    return tileBoundsOnSprite
  end

  local function editAnchors()
    app.transaction("Edit Anchors",
      function()
        originalCanvasBounds = dlg.bounds
        local tempChildren = {} -- Store the child name of each anchor
        layerEditableStates = {}
        local originalTool = app.activeTool.id
        tempLayersLock = true
        if ts:tile(ti).properties(PK).anchors ~= nil then
          oldAnchorCount = #ts:tile(ti).properties(PK).anchors
        end


        local parentOptions = { "no parent" }
        local childrenOptions = { "no child" }
        for _,layer in ipairs(spr.layers) do
          if layer.isTilemap and layer.name ~= originalLayer.name then
            table.insert(parentOptions, layer.name)
            table.insert(childrenOptions, layer.name)
          end
        end

        local function getParentAnchorNames(parentName)
          local options = { "no parent anchor" }
          for _,layer in ipairs(spr.layers) do
            if layer.isTilemap and
              layer.name == parentName and
              layer.tileset ~= nil and
              #layer.tileset > 1 and
              layer.tileset:tile(1).properties(PK).anchors ~= nil and
              #layer.tileset:tile(1).properties(PK).anchors > 0 then
              for _,anchor in ipairs(layer.tileset:tile(1).properties(PK).anchors) do
                table.insert(options, anchor.name)
              end
            end
          end
          return options
        end

        local parentAnchorNameOptions = getParentAnchorNames(originalLayer.properties(PK).parent)

        local function find_child_layer(parentLayer, anchorName)
          for _,layer in ipairs(spr.layers) do
            if layer.isTilemap and
              parentLayer.name == layer.properties(PK).parent and
              anchorName == layer.properties(PK).anchorName then
              return layer.name
            end
          end
          return "no child"
        end

        -- Give ids to old anchor to identify which anchor was deleted/created/nameChanged
        if ts:tile(ti).properties(PK).anchors ~= nil then
          for i=1, #ts:tile(ti).properties(PK).anchors, 1 do
            -- originalChildName: is to identify what children we need to remove parentship
            -- if we change the child to other different child in the acceptPoints() function.
            -- childName: the current child selected
            local originalAnchorName = ts:tile(ti).properties(PK).anchors[i].name
            local originalChildName = find_child_layer(originalLayer, originalAnchorName)
            table.insert(oldAnchors, { name=originalAnchorName,
                                       originalAnchorName=originalAnchorName,
                                       position=ts:tile(ti).properties(PK).anchors[i].position,
                                       tempLayer=nil,
                                       childName=originalChildName,
                                       originalChildName=originalChildName,
                                       check=false })
          end
        end

        local function cancel()
          if anchorListDlg ~= nil then
            anchorListDlg:close()
          end
          tempLayersLock = true
          for i=1, #oldAnchors, 1 do
            if oldAnchors[i].tempLayer ~= nil then
              app.activeSprite:deleteLayer(oldAnchors[i].tempLayer)
            end
          end
          if tempAttachment ~= nil then
            app.activeSprite:deleteLayer(tempAttachment)
          end
          if tempLayerForRefPoint ~= nil then
            app.activeSprite:deleteLayer(tempLayerForRefPoint)
          end
          app.command.AdvancedMode{}
          unlockLayers()
          anchorActionsDlg:close()
          dlg.bounds = originalCanvasBounds
          app.activeLayer = originalLayer
          app.activeTool = originalTool
          oldAnchors = {}
          tempLayersLock = false
        end

        anchorActionsDlg = Dialog()

        local function createLayersForAnchors(tileBounds)
          if #oldAnchors >= 1 then
            -- make all anchors point in separate layers
            for i=1, #oldAnchors, 1 do
              oldAnchors[i].tempLayer = spr:newLayer()
              local anchorPos = oldAnchors[i].position
              local pos = anchorPos + tileBounds.origin- Point(anchorCrossImage.width / 2, anchorCrossImage.height / 2)
              spr:newCel(oldAnchors[i].tempLayer, app.activeFrame, anchorCrossImage, pos)
              oldAnchors[i].tempLayer.name = "anchor_" .. i
            end
            anchorListDlg = Dialog()
          end
        end

        local function refreshTempLayers()
          tempLayersLock = true
          for i=1, #oldAnchors, 1 do
            if oldAnchors[i].tempLayer ~= nil then
              if oldAnchors[i].check then
                oldAnchors[i].tempLayer.cels[1].image = anchorCrossImage
              else
                oldAnchors[i].tempLayer.cels[1].image = anchorCrossImageT
              end
            end
          end
          app.refresh()
          tempLayersLock = false
        end

        local function generateAnchorListDlg(regeneration)
           if anchorListDlg == nil then
            return
          end
          tempLayersLock = true
          if regeneration then
            for i=1, #oldAnchors, 1 do
              oldAnchors[i].name = anchorListDlg.data["e_" .. i]
            end
          end

          local function findOneCheck()
            local checksMarkedCounter = 0
            local checkMarkedIndex = nil
            for i=1, #oldAnchors, 1 do
              if oldAnchors[i].check then
                checkMarkedIndex = i
                checksMarkedCounter = checksMarkedCounter+1
              end
            end
            if checksMarkedCounter == 1 then
              return checkMarkedIndex
            end
            return nil
          end

          anchorListDlg:close()
          anchorListDlg = Dialog()
          for i=1, #oldAnchors, 1 do
            if oldAnchors[i].tempLayer ~= nil then
              anchorListDlg:separator { text="Anchor " .. i }
              anchorListDlg:check{  id="c_" .. i,
                                    selected=oldAnchors[i].check,
                                    onclick=function()
                                              oldAnchors[i].check = anchorListDlg.data["c_".. i]
                                              tempLayersLock = true
                                              if not(oldAnchors[i].check) then
                                                local k = findOneCheck()
                                                if k ~= nil then
                                                  app.activeLayer = oldAnchors[k].tempLayer
                                                end
                                              else
                                                app.activeLayer = oldAnchors[i].tempLayer
                                              end
                                              tempLayersLock = false
                                              refreshTempLayers()
                                            end }
              anchorListDlg:entry{  id="e_" .. i, text=oldAnchors[i].name }
              anchorListDlg:combobox{ id="x_" .. i,
                                      option=oldAnchors[i].childName,
                                      options=childrenOptions,
                                      onchange=function()
                                        oldAnchors[i].childName = anchorListDlg.data["x_" .. i]
                                        generateAnchorListDlg(true)
                                      end }
              if oldAnchors[i].check then
                oldAnchors[i].tempLayer.cels[1].image = anchorCrossImage
              else
                oldAnchors[i].tempLayer.cels[1].image = anchorCrossImageT
              end
            end
          end
          anchorListDlg:show{ wait=false }
          anchorListDlg.bounds = Rectangle(anchorActionsDlg.bounds.x,
                                                      150*imi.uiScale,
                                                      130*imi.uiScale,
                                                      anchorListDlg.bounds.height)
          app.refresh()
          tempLayersLock = false
        end

        local function removeAnchorPoint()
          tempLayersLock = true
          for i=1, #oldAnchors, 1 do
            if oldAnchors[i].check then
              spr:deleteLayer(oldAnchors[i].tempLayer)
              oldAnchors[i].tempLayer = nil
              oldAnchors[i].check = false
              oldAnchors[i].position = nil
              oldAnchors[i].childName = "no child"
            end
          end
          tempLayersLock = false
          generateAnchorListDlg(true)
        end

        local function addAnchorPoint(tileBounds)
          tempLayersLock = true
          local anchorPos = Point(tileBounds.width/2, tileBounds.height/2)
          table.insert(oldAnchors, {  name="anchor_" .. #oldAnchors + 1,
                                      position=anchorPos,
                                      tempLayer=spr:newLayer(),
                                      childName="no child",
                                      check=true })
          oldAnchors[#oldAnchors].tempLayer.name = oldAnchors[#oldAnchors].name
          local pos = anchorPos + tileBounds.origin - Point(anchorCrossImage.width / 2, anchorCrossImage.height / 2)
          spr:newCel(oldAnchors[#oldAnchors].tempLayer, app.activeFrame, anchorCrossImage, pos)
          tempLayersLock = false
          if anchorListDlg == nil then
            anchorListDlg = Dialog()
          end
          generateAnchorListDlg(true)
        end

        local function addReferencePoint(tileBounds)
          tempLayersLock = true
          tempLayerForRefPoint = spr:newLayer()
          tempLayerForRefPoint.name = "reference point"
          local refPos = Point(tileBounds.width/2, tileBounds.height/2)
          if ts:tile(ti).properties(PK).ref ~= nil then
            refPos = ts:tile(ti).properties(PK).ref
          end
          local pos = refPos + tileBounds.origin - Point(refCrossImage.width / 2, refCrossImage.height / 2)
          spr:newCel(tempLayerForRefPoint, app.activeFrame, refCrossImage, pos)
          tempLayersLock = false
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

        local tileBoundsOnSprite = find_tiles_on_cel()
        local tileBounds
        if tileBoundsOnSprite == nil then
          return
        elseif #tileBoundsOnSprite == 0 then
          local gridSize = ts.grid.tileSize
          local pos = Point((spr.width - gridSize.width)/2, (spr.height - gridSize.height)/2)
          tileBounds = Rectangle(pos.x, pos.y, gridSize.width, gridSize.height)
          tempAttachment = spr:newLayer("temp attachment")
          spr:newCel(tempAttachment, app.activeFrame, ts:tile(ti).image, pos)
          table.insert(tileBoundsOnSprite, tileBounds)
          createLayersForAnchors(tileBounds)
          app.refresh()
        elseif #tileBoundsOnSprite >= 1 then
          tileBounds = tileBoundsOnSprite[1]
          lockLayers()
          createLayersForAnchors(tileBounds)
        --else -- multiple tileBoundsOnSprite
          --TODO: include in the New Anchor Point dialog an instance selector
        end
        addReferencePoint(tileBounds)
        turnToeditAnchorsView()
        tempLayersLock = off

        local function backToSprite()
          cancel()
        end

        local function acceptPoints()

          local function buildNewAnchors(forOtherTiles, tile)
            local newAnchors = {}
            for i=1, oldAnchorCount, 1 do
              if oldAnchors[i].tempLayer ~= nil then
                local posValue
                if forOtherTiles and
                  tile ~= nil and
                  tile.properties(PK).anchors ~= nil and
                  #tile.properties(PK).anchors >= i then
                  posValue = tile.properties(PK).anchors[i].position
                else
                  posValue = oldAnchors[i].tempLayer.cels[1].position - tileBounds.origin +
                              Point(anchorCrossImage.width / 2, anchorCrossImage.height / 2)
                end
                table.insert(newAnchors, { name = anchorListDlg.data["e_" .. i],
                                          position = posValue })
              end
            end
            for i=oldAnchorCount+1, #oldAnchors, 1 do
              if oldAnchors[i].tempLayer ~= nil then
                local posValue = oldAnchors[i].tempLayer.cels[1].position - tileBounds.origin +
                                  Point(anchorCrossImage.width / 2, anchorCrossImage.height / 2)
                table.insert(newAnchors, { name=anchorListDlg.data["e_" .. i],
                                            position=posValue })
              end
            end
            return newAnchors
          end

          generateAnchorListDlg(true)
          local tileProperty = ts:tile(ti).properties(PK)
          for i=1, #oldAnchors, 1 do
            local child = oldAnchors[i].childName
            local origChild = oldAnchors[i].originalChildName
            if child ~= origChild then
              for _,layer in ipairs(spr.layers) do
                if layer.name == child then
                  layer.properties(PK).parent = originalLayer.name
                  layer.properties(PK).anchorName = oldAnchors[i].name
                elseif layer.name == origChild then
                  layer.properties(PK).parent = "no parent"
                  layer.properties(PK).anchorName = "no parent anchor"
                end
              end
            else
              local anchorName = oldAnchors[i].name
              local originalAnchorName = oldAnchors[i].originalAnchorName
              if anchorName ~= originalAnchorName then
                for _,layer in ipairs(spr.layers) do
                  if layer.name == child then
                    layer.properties(PK).anchorName = anchorName
                  end
                end
              end
            end
          end
          tileProperty.ref = tempLayerForRefPoint.cels[1].position +
                             Point(refCrossImage.width/2, refCrossImage.height/2) - tileBounds.origin
          originalLayer.properties(PK).parent = anchorActionsDlg.data.parent
          originalLayer.properties(PK).anchorName = anchorActionsDlg.data.anchorName
          -- Update all the anchors of all tiles of all categories
          for i=1, #originalLayer.properties(PK).categories do
            local tileset = find_tileset_by_categoryID(spr, originalLayer.properties(PK).categories[i])
            -- Update the reference point in all categories:
            originalLayer.properties(PK).parent = anchorActionsDlg.data.parent
            originalLayer.properties(PK).anchorName = anchorActionsDlg.data.anchorName
            for j=1, #tileset-1, 1 do
              if j ~= ti  then
                tileset:tile(j).properties(PK).anchors = buildNewAnchors(true, tileset:tile(j))
              else
                tileset:tile(j).properties(PK).anchors = buildNewAnchors(false, nil)
              end
            end
          end
          backToSprite()
        end

        anchorActionsDlg:separator{ text="Anchor Actions" }
        anchorActionsDlg:button{ text="Add", onclick= function()
                                                        addAnchorPoint(tileBoundsOnSprite[1])
                                                      end }
        anchorActionsDlg:button{ text="Remove", onclick=removeAnchorPoint }
        anchorActionsDlg:label{ text="To move anchors:"}:newrow()
        anchorActionsDlg:label{ text="Hold CTRL, click and move" }
        anchorActionsDlg:separator{ text="Attachment Parent" }
        local parentLayer = parentOptions[1]
        if originalLayer.properties(PK).parent ~= nil then
          parentLayer = originalLayer.properties(PK).parent
        end
        anchorActionsDlg:combobox{  id="parent",
                                    option=parentLayer,
                                    options=parentOptions,
                                    onchange= function()
                                                parentAnchorNameOptions = getParentAnchorNames(anchorActionsDlg.data.parent)
                                                anchorActionsDlg:modify{ id="anchorName",
                                                                         option=parentAnchorNameOptions[1],
                                                                         options=parentAnchorNameOptions}
                                              end } :newrow()

        anchorActionsDlg:combobox{  id="anchorName",
                                    option=originalLayer.properties(PK).anchorName,
                                    options=parentAnchorNameOptions,
                                    onchange= function()
                                              -- TO DO: -- Align attachment to the new anchor
                                              end } :newrow()

        anchorActionsDlg:separator()
        anchorActionsDlg:button{ text="Cancel", onclick=cancel }
        anchorActionsDlg:button{ text="OK", onclick=acceptPoints }
        generateAnchorListDlg(false)
        anchorActionsDlg:show{
          wait=false,
          bounds=Rectangle(0, 0, 130*imi.uiScale, 150*imi.uiScale)
        }
        popup:close()
        dlg.bounds = Rectangle(0, 0, 1, 1)
      end)
  end


local function editTile()
    app.transaction(
      function()
        originalLayer = activeLayer
        originalCanvasBounds = dlg.bounds
        layerEditableStates = {}

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

  function forEachCategoryTileset(func)
    for i,categoryID in ipairs(activeLayer.properties(PK).categories) do
      local catTileset = find_tileset_by_categoryID(spr, categoryID)
      func(catTileset)
    end
  end

  function addInFolderAndBaseSet(ti)
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

  function newEmpty()
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

  function duplicate()
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

  function delete()
    table.remove(folder.items, indexInFolder)
    app.transaction("Delete Folder", function()
     activeLayer.properties(PK).folders = folders
    end)
    popup:close()
  end

  popup:menuItem{ text="Edit Anchors", onclick=editAnchors }:newrow()
  popup:menuItem{ text="Edit Tile", onclick=editTile }:newrow()
  popup:separator():newrow()
  popup:menuItem{ text="New Empty", onclick=newEmpty }:newrow()
  popup:menuItem{ text="Duplicate", onclick=duplicate }:newrow()
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

  if ts:tile(ti).properties(PK).ref == nil then
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
        local oldCursorY = imi.cursor.y
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
      imi.pushViewport(Rectangle(imi.cursor.x, imi.cursor.y,
                                 imi.viewport.width - imi.cursor.x,
                                 imi.viewport.height - imi.cursor.y-(10+app.theme.dimension.mini_scrollbar_size)*imi.uiScale))
      imi.beginViewport(Size(imi.viewport.width, imi.viewport.height), 100)

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
  if anchorListDlg ~= nil and #oldAnchors >= 1 and not(tempLayersLock) then
    for i=1, #oldAnchors, 1 do
      if oldAnchors[i].tempLayer == app.activeLayer then
        for j=1, #oldAnchors, 1 do
          if oldAnchors[j].tempLayer ~= nil then
            if j==i then
                oldAnchors[j].tempLayer.cels[1].image = anchorCrossImage
                oldAnchors[j].check = true
            else
                oldAnchors[j].tempLayer.cels[1].image = anchorCrossImageT
                oldAnchors[j].check = false
            end
              anchorListDlg:modify { id="c_" .. j,
                                     selected=oldAnchors[j].check }
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

function init(plugin)
  plugin:newCommand{
    id="AttachmentSystem_SwitchWindow",
    title="Attachment System: Switch Window",
    group="view_new",
    onclick=AttachmentWindow_SwitchWindow
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