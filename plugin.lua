-- Aseprite Attachment System
-- Copyright (c) 2022-2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

-- Modules
local imi = dofile('./imi.lua')
local db = dofile('./db.lua')

-- Constants
local PK = db.PK
local kUnnamedCategory = "(Unnamed)"

-- The main window/dialog
local dlg
local title = "Attachment System"
local observedSprite
local activeLayer         -- Active tilemap (nil if the active layer isn't a tilemap)
local shrunkenBoundsCache = {} -- Cache of shrunken bounds
local shrunkenBounds = {} -- Minimal bounds between all tiles of the active layer
local shrunkenSize = Size(1, 1) -- Minimal size between all tiles of the active layer
local tilesHistogram = {} -- How many times each tile is used in the active layer
local activeTileImageInfo = {} -- Used to re-calculate info when the tile image changes
local focusedItem = nil        -- Folder + item with the keyboard focus

-- Plugin preferences
local showTilesID = false
local showTilesUsage = false
local showUnusedTilesSemitransparent = true
local zoom = 1.0

-- Dialog for Add/Remove anchor points
local anchorActionsDlg
-- Auxiliary array of layers, during editAnchors()
-- {layer=tempLayerReference, layer=tempLayerAnchor1, layer=tempLayerAnchor2, ... }
-- TODO: to refactor to a simple array.
local tempLayerStates = {}
-- Crosshair for anchor points
local anchorCrossImage
-- Crosshair for reference point
local refCrossImage
-- Flag to avoid 'onclose' actions of 'dlg' Attachment Window (to act as dlg:modify{visible=false}).
local dlgSkipOnCloseFun = false
-- Temporal sprite to edit anchors/ref or attachments images
local tempSprite = nil
-- Flag to lock the update of Ref/Anchor selector comboBox
local lockUpdateRefAnchorSelector = false
-- Helps to save only the changes, it improves performance and the undo process.
-- Array of bool elements to detect changes on the tempSprite cels, used on Sprite_change()
local changeDetectionOnCels = nil
-- Layer used to editing attachment on editAttachment(), used on Sprite_change()l
local editAttachmentLayer = nil

local function create_cross_images(colorMode)
  local black = Color(0,0,0)

  if not anchorCrossImage or anchorCrossImage.colorMode ~= colorMode then
    anchorCrossImage = Image(3, 3, colorMode)
    anchorCrossImage:drawPixel(1, 0, black)
    anchorCrossImage:drawPixel(0, 1, black)
    anchorCrossImage:drawPixel(2, 1, black)
    anchorCrossImage:drawPixel(1, 2, black)
    anchorCrossImage:drawPixel(1, 1, Color(255,0,0))
  end

  if not refCrossImage or refCrossImage.colorMode ~= colorMode then
    refCrossImage = Image(9, 9, colorMode)
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

-- As Image:shrinkBounds() can be quite slow, we cache as many calls as possible
local function get_shrunken_bounds_of_image(image)
  -- TODO This shouldn't happen, but it can happen when we convert a
  --      regular layer to a tilemap layer, something to fix in a near
  --      future.
  if not image then
    return Rectangle()
  end

  local cache = shrunkenBoundsCache[image.id]
  if not cache or cache.version ~= image.version then
    cache = { version=image.version,
              bounds=image:shrinkBounds()}
    shrunkenBoundsCache[image.id] = cache
  end
  return cache.bounds
end

local function calculate_shrunken_bounds(tilemapLayer)
  assert(tilemapLayer.isTilemap)
  local bounds = Rectangle()
  local size = Size(16, 16)
  local ts = tilemapLayer.tileset
  local ntiles = #ts
  for i = 0,ntiles-1 do
    local tileImg = ts:getTile(i)
    local shrinkBounds = get_shrunken_bounds_of_image(tileImg)
    bounds = bounds:union(shrinkBounds)
    size = size:union(shrinkBounds.size)
  end
  if bounds.width <= 1 and bounds.height <= 1 then
    bounds = Rectangle(0, 0, 8, 8)
  end
  shrunkenBounds = bounds
  shrunkenSize = size
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

local function find_layer_by_id(layers, id)
  for _,layer in ipairs(layers) do
    if layer.isGroup then
      local result = find_layer_by_id(layer.layers, id)
      if result then return result end
    elseif layer.isTilemap and
           layer.properties(PK).id == id then
      return layer
    end
  end
  return nil
end

local function find_layer_by_name(layers, name)
  for _,layer in ipairs(layers) do
    if layer.isGroup then
      local result = find_layer_by_name(layer.layers, name)
      if result then return result end
    elseif layer.name == name then
      return layer
    end
  end
  return nil
end

local function find_anchor_on_layer(parentLayer, childLayer, parentTile)
  if parentLayer.isTilemap and childLayer.isTilemap then
    local anchors = parentLayer.tileset:tile(parentTile).properties(PK).anchors
    if anchors and #anchors >= 1 then
      for i=1, #anchors, 1 do
        if anchors[i].layerId == childLayer.properties(PK).id then
          return anchors[i]
        end
      end
    end
  end
  return nil
end

local function find_parent_layer(layers, childLayer)
  for _,layer in ipairs(layers) do
    if layer.isGroup then
      local result = find_parent_layer(layer.layers, childLayer)
      if result then return result end
    elseif find_anchor_on_layer(layer, childLayer, 1) then
      return layer
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

-- Gets the base tileset (the tileset assigned to the first category
-- of the layer, or just the active tileset if the layer doesn't
-- contain categories yet). This tileset is the one used to store the
-- anchor/reference points per tile.
local function get_base_tileset(layer)
  local ts = nil
  local layerProperties = layer.properties(PK)
  if layerProperties.categories and #layerProperties.categories then
    ts = db.findTilesetByCategoryID(layer.sprite,
                                    layerProperties.categories[1])
    if not ts then
      ts = layer.tileset
    end
  else
    ts = layer.tileset
  end
  return ts
end


local function get_folder_item_index_by_position(folder, position)
  for i=1,#folder.items do
    local itemPos = folder.items[i].position
    if not itemPos then
      itemPos = Point(i-1, 0)
    end
    if itemPos == position then
      return i
    end
  end
  return nil
end

local function get_folder_position_bounds(folder)
  local bounds = Rectangle(0, 0, 1, 1)
  for i=1,#folder.items do
    bounds = bounds:union(Rectangle(folder.items[i].position, Size(1, 1)))
  end
  return bounds
end

local function find_empty_spot_position(folder, ti)
  -- TODO improve this when the viewport has more rows available
  local itemPos = Point(0, 0)
  while true do
    local existentItem = get_folder_item_index_by_position(folder, itemPos)
    if not existentItem then break end
    itemPos.x = itemPos.x+1
  end
  return itemPos
end

-- Matches defined reference points <-> anchor points from parent to
-- children
local function align_anchors()
  local spr = app.activeSprite
  if not spr then return end

  local hierarchy = {}
  local function create_layers_hierarchy(layers)
    for i=1,#layers do
      local layer = layers[i]
      if layer.isTilemap then
        local layerProperties = layer.properties(PK)
        if layerProperties.id then
          local ts = get_base_tileset(layer)
          local ti = 1          -- TODO use all tiles?
          local anchors = ts:tile(ti).properties(PK).anchors
          if anchors and #anchors >= 1 then
            for j=1,#anchors do
              local auxLayer = find_layer_by_id(spr.layers, anchors[j].layerId)
              if auxLayer then
                local childId = anchors[j].layerId
                if childId then
                  hierarchy[childId] = layerProperties.id
                end
              end
            end
          end
        end
      end
      if layer.isGroup then
        create_layers_hierarchy(layer.layers)
      end
    end
  end
  create_layers_hierarchy(spr.layers)

  local movedLayers = {}
  local function align_layer(childId, parentId, tab)
    local child = find_layer_by_id(spr.layers, childId)
    local parent = find_layer_by_id(spr.layers, parentId)

    assert(child)
    assert(parent)

    if hierarchy[parentId] then
      align_layer(parentId, hierarchy[parentId], tab+1)
    end

    if not movedLayers[childId] then
      table.insert(movedLayers, childId)

      for fr=1,#spr.frames do
        local parentCel = parent:cel(fr)
        local childCel = child:cel(fr)
        if parentCel and parentCel.image and
           childCel and childCel.image then
          local parentTs = get_base_tileset(parent)
          local parentTi = parentCel.image:getPixel(0, 0)
          local childTs = get_base_tileset(child)
          local childTi = childCel.image:getPixel(0, 0)

          local refPoint = childTs:tile(childTi).properties(PK).ref
          if refPoint then
            local anchorPoint = nil
            local anchors = parentTs:tile(parentTi).properties(PK).anchors
            if anchors and #anchors >= 1 then
              for i=1,#anchors do
                local auxLayer = find_layer_by_id(spr.layers, anchors[i].layerId)
                if auxLayer then
                  if anchors[i].layerId == childId then
                    anchorPoint = anchors[i].position
                    break
                  end
                end
              end
            end
            if anchorPoint then
              -- Align refPoint with anchorPoint
              childCel.position =
                parentCel.position + anchorPoint - refPoint
            end
          end
        end
      end
    end
  end

  app.transaction("Align Anchors",
    function()
      for childId,parentId in pairs(hierarchy) do
        align_layer(childId, parentId, 0)
      end
      app.refresh()
    end)
end

local function handle_drop_item_in_folder(folders,
                                          sourceFolderName, sourceItemIndex, sourceTileIndex,
                                          targetFolder, targetPosition)
  local dropPosition = imi.highlightDropItemPos
  assert(dropPosition ~= nil)

  local existentItem = get_folder_item_index_by_position(targetFolder, targetPosition)
  local label

  -- Drag-and-drop in the same folder
  if sourceFolderName == targetFolder.name then
    -- Drop in an existent item: swap items
    if existentItem then
      if sourceItemIndex == existentItem then
        -- Do nothing when dropping in the same index
        return
      end

      targetFolder.items[sourceItemIndex].tile = targetFolder.items[existentItem].tile
      targetFolder.items[existentItem].tile = sourceTileIndex
      label = "Swap Attachments"

    -- Drop in an empty space: move item
    else
      targetFolder.items[sourceItemIndex].position = targetPosition
      label = "Move Attachment"
    end

  -- Drag-and-drop between folders
  else
    -- Drop in an existent item: replace item
    if existentItem then
      -- Error, trying to remove/replace and attachment in the base set
      if db.isBaseSetFolder(targetFolder) and
         targetFolder.items[existentItem].tile ~= sourceTileIndex then
        return app.alert("Cannot replace an attachment in the base set")
      end

      targetFolder.items[existentItem].tile = sourceTileIndex
      label = "Replace Attachment"

    -- Drop in an empty space: copy item
    else
      table.insert(targetFolder.items,
                   { tile=sourceTileIndex, position=targetPosition })
      label = "Copy Attachment"
    end
  end

  app.transaction(label,
    function()
      activeLayer.properties(PK).folders = folders
    end)
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

local function set_active_tile(ti)
  if activeLayer and activeLayer.isTilemap then
    local ts = get_base_tileset(activeLayer)
    local cel = activeLayer:cel(app.activeFrame)
    local oldRefPoint
    local newRefPoint

    -- Change tilemap tile if are not showing categories
    -- We use Image:drawImage() to get undo information
    if activeLayer and cel and cel.image then
      local oldTi = cel.image:getPixel(0, 0)
      if oldTi then
        oldRefPoint = ts:tile(oldTi).properties(PK).ref
      end

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

    if ti then
      newRefPoint = ts:tile(ti).properties(PK).ref
    end

    -- Align ref points (between old attachment and new one)
    if oldRefPoint and newRefPoint then
      cel.position = cel.position + oldRefPoint - newRefPoint
    end

    align_anchors()

    imi.repaint = true
    app.refresh()
  end
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

local function find_folder_items_by_tile(folder, tileId)
  local items = {}
  for i=1, #folder.items, 1 do
    if folder.items[i].tile == tileId then
      table.insert(items, folder.items[i])
    end
  end
  return items
end

local function count_folder_items_with_tile(folder, tileId)
  local count = 0
  for i=1, #folder.items, 1 do
    if folder.items[i].tile == tileId then
      count = count + 1
    end
  end
  return count
end

local function find_first_item_index_in_folder_by_tile(folder, tileId)
  for i=1, #folder.items, 1 do
    if folder.items[i].tile == tileId then
      return i
    end
  end
  return -1
end

local function remove_tile_from_folder_by_index(folder, indexInFolder)
  local tiRow = folder.items[indexInFolder].position.y
  local tiColumn = folder.items[indexInFolder].position.x
  table.remove(folder.items, indexInFolder)
  for j=#folder.items,1,-1 do
    if folder.items[j].position.y == tiRow and
      folder.items[j].position.x > tiColumn then
      folder.items[j].position.x = folder.items[j].position.x - 1
    end
  end
end

local function remove_tiles_from_folders(folders, ti)
  for i=1,#folders, 1 do
    local folder = folders[i]
    local ti_items = find_folder_items_by_tile(folder, ti)
    if #ti_items == 0 then
      for j=#folder.items,1,-1 do
        if folder.items[j].tile > ti then
          folder.items[j].tile = folder.items[j].tile - 1
        end
      end
    else
      for j=1, #ti_items, 1 do
        local tiRow = ti_items[j].position.y
        local tiColumn = ti_items[j].position.x
        for k=#folder.items,1,-1 do
          if folder.items[k].position.y == tiRow and
            folder.items[k].position.x > tiColumn then
            folder.items[k].position.x = folder.items[k].position.x - 1
          end
        end
      end
      for j=#folder.items,1,-1 do
        if folder.items[j].tile == ti then
          table.remove(folder.items, j)
        elseif folder.items[j].tile > ti then
          folder.items[j].tile = folder.items[j].tile - 1
        end
      end
    end
  end
end

local function show_tile_context_menu(ts, ti, folders, folder, indexInFolder)
  local popup = Dialog{ parent=imi.dlg }
  local spr = activeLayer.sprite

  -- Variables and Functions associated to editAnchors() and editAttachment()
  local originalLayer = activeLayer
  local refTileset = get_base_tileset(originalLayer)
  local originalFrame = app.activeFrame.frameNumber
  local defaultAnchorSample = 1

  local function editAnchors()
    create_cross_images(spr.colorMode)
    tempLayers = {}
    tempLayerStates = {}
    local selectionOptions = { "reference point" }
    local newAnchorDlg = nil
    lockUpdateRefAnchorSelector = true
    tempSprite = Sprite(ts:tile(ti).image.width, ts:tile(ti).image.height, spr.colorMode)
    local originalPreferences = { auto_select_layer=app.preferences.editor.auto_select_layer,
                                  auto_select_layer_quick=app.preferences.editor.auto_select_layer_quick }
    local originalTool = app.activeTool.id
    app.activeTool = "move"
    app.preferences.editor.auto_select_layer = false
    app.preferences.editor.auto_select_layer_quick = true
    local palette = spr.palettes[1]
    tempSprite.palettes[1]:resize(#palette)
    for i=0, #palette-1, 1 do
      tempSprite.palettes[1]:setColor(i, palette:getColor(i))
    end
    for i=1, #ts-1, 1 do
      tempSprite:newCel(app.activeLayer, i, ts:tile(i).image, Point(0, 0))
      tempSprite:newEmptyFrame()
    end
    tempSprite:deleteFrame(#ts)

    local function putAnchorImage(layer, frame, anchor)
      local anchorLayer = find_layer_by_id(spr.layers, anchor.layerId)
      local anchorRefTs = get_base_tileset(anchorLayer)
      local ref = anchorRefTs:tile(defaultAnchorSample).properties(PK).ref
      if not ref then
        ref = Point(anchorRefTs.grid.tileSize.width/2,
                    anchorRefTs.grid.tileSize.height/2)
      end
      if anchorLayer then
        local anchorImage = Image(anchorLayer.tileset:tile(defaultAnchorSample).image)
        anchorImage:drawImage(anchorCrossImage,
                              ref - Point(anchorCrossImage.width/2, anchorCrossImage.height/2))
        local pos = anchor.position - ref
        tempSprite:newCel(layer, frame, anchorImage, pos)
      end

    end

    -- Load all the anchors in all the tiles
    local anchors = ts:tile(ti).properties(PK).anchors
    if anchors and #anchors >= 1 then
      -- Create the layers
      for i=1, #anchors, 1 do
        table.insert(tempLayerStates, { layer=tempSprite:newLayer() })
        local auxLayer = find_layer_by_id(spr.layers,
                                          anchors[i].layerId)
        if auxLayer ~= nil then
          tempLayerStates[#tempLayerStates].layer.name = auxLayer.name
        else
          tempLayerStates[#tempLayerStates].layer.name = "anchor " .. i
        end
      end
      for i=1, #ts-1, 1 do
        for j=1, #anchors, 1 do
          putAnchorImage(tempLayerStates[j].layer,
                         i,
                         ts:tile(i).properties(PK).anchors[j])
        end
      end
    end

    -- Create the reference point Layer, it should be always on top of the stack layers and
    -- it will be first element on the tempLayers vector
    local tempLayer = tempSprite:newLayer()
    tempLayer.name = "reference point"
    table.insert(tempLayerStates, 1, { layer=tempLayer })
    local tileset = get_base_tileset(originalLayer)
    for i=1, #tileset-1, 1 do
      local ref = tileset:tile(i).properties(PK).ref
      if ref == nil then
        ref = Point(ts:tile(i).image.width/2, ts:tile(i).image.height/2)
      else
        ref = tileset:tile(i).properties(PK).ref
      end
      local pos = ref - Point(refCrossImage.width/2, refCrossImage.height/2)
      local cel = tempSprite:newCel(tempLayer, i, refCrossImage, pos)
      cel.properties(PK).origPos = pos
    end
    app.activeFrame = ti
    lockUpdateRefAnchorSelector = false

    local function cancel()
      lockUpdateRefAnchorSelector = true
      if tempSprite ~= nil then
        tempSprite:close()
        tempSprite = nil
      end
      if newAnchorDlg ~= nil then
        newAnchorDlg:close()
      end
      app.activeSprite = spr
      app.preferences.editor.auto_select_layer = originalPreferences.auto_select_layer
      app.preferences.editor.auto_select_layer_quick = originalPreferences.auto_select_layer_quick
      app.activeTool = originalTool
      app.activeLayer = originalLayer
      lockUpdateRefAnchorSelector = false
      dlgSkipOnCloseFun = false
    end

    local function addChildrenOptions(layers, options)
      for _,layer in ipairs(layers) do
        if layer.isGroup then
          addChildrenOptions(layer.layers, options)
        elseif layer.isTilemap and layer ~= originalLayer then
          table.insert(options, layer.name)
        end
      end
    end

    local function generateUsedAnchorIds(layers, anchorLayerIds)
      for _,layer in ipairs(layers) do
        if layer ~= originalLayer then
          if layer.isGroup then
            generateUsedAnchorIds(layer.layers, anchorLayerIds)
          elseif layer.isTilemap and layer.tileset:tile(1) and
            layer.tileset:tile(1).properties(PK).anchors then
            local anchors = layer.tileset:tile(1).properties(PK).anchors
            if anchors and #anchors >= 1 then
              for i=1, #anchors, 1 do
                local auxLayer = find_layer_by_id(spr.layers, anchors[i].layerId)
                if auxLayer then
                  table.insert(anchorLayerIds, anchors[i].layerId)
                end
              end
            end
          end
        end
      end
    end

    local function generateChildrenOptions()
      local options = { "no child" }
      addChildrenOptions(spr.layers, options)
      for i=2, #tempLayerStates, 1 do
        for j=2, #options, 1 do
          if tempLayerStates[i].layer.name == options[j] then
            table.remove(options, j)
            break
          end
        end
      end
      -- Summarize child layer id's used on other tilemaps
      local anchorLayerIds = {}
      generateUsedAnchorIds(spr.layers, anchorLayerIds)
      -- Remove used child options from 'options'
      for i=1, #anchorLayerIds, 1 do
        local layerFound = find_layer_by_id(spr.layers,
                                            anchorLayerIds[i])
        for j=1, #options, 1 do
          if layerFound.name == options[j] then
            table.remove(options, j)
            break
          end
        end
      end
      return options
    end

    local function generateSelectionOptions()
      local options = {}
      for i=1, #tempLayerStates, 1 do
        table.insert(options, tempLayerStates[i].layer.name)
      end
      return options
    end

    lockUpdateRefAnchorSelector = true
    anchorActionsDlg = Dialog { title="Ref/Anchor Editor",
                                onclose=cancel }
    local blockComboOnchange = false
    newAnchorDlg = Dialog { title="Select Child"}
    lockUpdateRefAnchorSelector = false

    local function onChangeSelection()
      if not(blockComboOnchange) then
        lockUpdateRefAnchorSelector = true
        local layer = find_layer_by_name(tempSprite.layers,
                                          anchorActionsDlg.data.combo)
        app.activeLayer = layer
        lockUpdateRefAnchorSelector = false
      end
    end

    local function addAnchorPoint()
      lockUpdateRefAnchorSelector = true
      if newAnchorDlg ~= nil then
        newAnchorDlg:close()
      end
      local function addLayerToAllowNewAnchor()
        local tempLayer = tempSprite:newLayer()
        tempLayer.name = newAnchorDlg.data.childBox

        table.insert(tempLayerStates, { layer=tempLayer })
        tempLayerStates[1].layer.stackIndex = tempLayer.stackIndex

        app.activeLayer = tempLayer
        local layer = find_layer_by_name(spr.layers, tempLayer.name)
        assert(layer)
        local anchor = { layerId=layer.properties(PK).id,
                         position=Point(ts.grid.tileSize.width/2, ts.grid.tileSize.height/2) }
        for i=1,#tempSprite.frames do
          putAnchorImage(tempLayer, i, anchor)
        end

        local selectionOptions = generateSelectionOptions()
        blockComboOnchange = true
        anchorActionsDlg:modify{ id="combo",
                                  option=tempLayer.name,
                                  options=selectionOptions }
        blockComboOnchange = false
        app.refresh()
      end

      local childrenOptions = generateChildrenOptions()
      newAnchorDlg = Dialog { title="Select Child"}
      newAnchorDlg:combobox { id="childBox",
                              option="no child",
                              options=childrenOptions,
                              onchange= function()
                                          addLayerToAllowNewAnchor()
                                          newAnchorDlg:close()
                                        end }
      newAnchorDlg:show { wait=false }
      local x = anchorActionsDlg.bounds.x + anchorActionsDlg.bounds.width
      local y = anchorActionsDlg.bounds.y + 15*imi.uiScale
      newAnchorDlg.bounds = Rectangle(x, y, newAnchorDlg.bounds.width, newAnchorDlg.bounds.height)
      lockUpdateRefAnchorSelector = false
    end

    local function acceptPoints()
      lockUpdateRefAnchorSelector = true
      local origFrame = app.activeFrame
      local origLayer = app.activeLayer
      local cels = tempLayerStates[1].layer.cels

      -- Process all anchors in one array 'auxAnchorsByTile'
      local auxAnchorsByTile = {}
      local auxLayerIds = {}
      for i=2, #tempLayerStates, 1 do
        local layerId =
          find_layer_by_name(spr.layers,
                              tempLayerStates[i].layer.name).properties(PK).id
        table.insert(auxLayerIds, layerId)
      end
      for tileId=1, #refTileset-1, 1 do
        local auxAnchors = {}
        app.activeFrame = tileId
        for i=1, #auxLayerIds, 1 do
          app.activeLayer = tempLayerStates[i+1].layer
          local cel = app.activeCel
          local anchorLayer = find_layer_by_id(spr.layers, auxLayerIds[i])
          local anchorRefTs = get_base_tileset(anchorLayer)
          local ref = anchorRefTs:tile(defaultAnchorSample).properties(PK).ref
          if not ref then
            ref = Point(anchorRefTs.grid.tileSize.width/2,
                        anchorRefTs.grid.tileSize.height/2)
          end
          local pos = cel.position + ref
          table.insert(auxAnchors, {layerId=auxLayerIds[i], position=pos})
        end
        table.insert(auxAnchorsByTile, auxAnchors)
      end

      -- Saving process
      app.activeSprite = originalLayer.sprite
      app.transaction("Edit Reference/Anchor Points",
       function()
          for _,cel in ipairs(cels)  do
            if cel.position ~= cel.properties(PK).origPos then
              local tileId = cel.frameNumber
              local pos = cel.position + Point(refCrossImage.width/2, refCrossImage.height/2)
              refTileset:tile(tileId).properties(PK).ref = pos
            end
          end
          for i=1, #originalLayer.properties(PK).categories, 1 do
            local tileset = db.findTilesetByCategoryID(spr, originalLayer.properties(PK).categories[i])
            for tileId=1, #refTileset-1, 1 do
              tileset:tile(tileId).properties(PK).anchors = auxAnchorsByTile[tileId]
            end
          end
        end)
      app.activeFrame = origFrame
      app.activeLayer = origLayer
      tempLayerStates = nil
      lockUpdateRefAnchorSelector = false
      anchorActionsDlg:close()
    end

    local function removeAnchorPoint()
      lockUpdateRefAnchorSelector = true
      local layerToRemove =
        find_layer_by_name(tempSprite.layers,
                            anchorActionsDlg.data.combo)
      if tempLayerStates[1].layer == layerToRemove then return end
      for i=2, #tempLayerStates, 1 do
        if tempLayerStates[i].layer == layerToRemove then
          tempSprite:deleteLayer(layerToRemove)
          table.remove(tempLayerStates, i)
          break
        end
      end
      local selectionOptions = generateSelectionOptions()
      blockComboOnchange = true
      anchorActionsDlg:modify{ id="combo",
                                option=selectionOptions[1],
                                options= selectionOptions }
      blockComboOnchange = false
      app.refresh()
      lockUpdateRefAnchorSelector = false
    end

    lockUpdateRefAnchorSelector = true
    local selectionOptions = generateSelectionOptions()
    anchorActionsDlg:separator{ text="Anchor Actions" }
    anchorActionsDlg:button{ text="Add", focus=true, onclick=addAnchorPoint }
    anchorActionsDlg:button{ text="Remove", focus=false, onclick=removeAnchorPoint }
    anchorActionsDlg:separator{ text="Ref/Anchor selector" }
    anchorActionsDlg:combobox{ id="combo",
                                option=selectionOptions[1],
                                options=selectionOptions,
                                onchange=onChangeSelection } :newrow()

    anchorActionsDlg:separator()
    anchorActionsDlg:button{ text="OK", onclick=acceptPoints }
    anchorActionsDlg:button{ text="Cancel", onclick=function() anchorActionsDlg:close() end }
    anchorActionsDlg:show{ wait=false }
    anchorActionsDlg.bounds = Rectangle(0, 0, anchorActionsDlg.bounds.width, anchorActionsDlg.bounds.height)
    popup:close()
    dlgSkipOnCloseFun = true
    lockUpdateRefAnchorSelector = false
  end

  local function is_unused_tile(tileIndex)
    return tilesHistogram[tileIndex] == nil
  end

  local function editAttachment()
    dlgSkipOnCloseFun = true
    local defaultAnchorSample = 1

    local function cancel()
      if tempSprite ~= nil then
        tempSprite:close()
        tempSprite = nil
      end
      changeDetectionOnCels = nil
      editAttachmentLayer = nil
      dlgSkipOnCloseFun = false
      app.activeFrame = originalFrame
    end

    local editAttachmentDlg = Dialog{ title="Edit Attachment", onclose=cancel }
    editAttachmentDlg:label{ text="When finish press OK" }
    local tileSize = refTileset.grid.tileSize
    tempSprite = Sprite(spr.width, spr.height, spr.colorMode)
    local attachmentOriginalPositions = {}
    app.transaction("New Sprite for attachment edition",
      function()
        local palette = spr.palettes[1]
        tempSprite.palettes[1]:resize(#palette)
        for i=0, #palette-1, 1 do
          tempSprite.palettes[1]:setColor(i, palette:getColor(i))
        end
        for i=1, #ts-2, 1 do
          tempSprite:newEmptyFrame()
        end

        local tilePosOnTempSprite = Point((tempSprite.width - tileSize.width)/2,
                                          (tempSprite.height - tileSize.height)/2)

        -- Add faded parent tiles layer for reference
        local parentLayer = find_parent_layer(spr.layers, originalLayer)
        if parentLayer then
          local defaultParentAnchor = find_anchor_on_layer(parentLayer, originalLayer, defaultAnchorSample)
          assert(defaultParentAnchor)
          local parentLayerOnTempSprite = tempSprite.layers[1]
          parentLayerOnTempSprite.name = parentLayer.name
          for i=1, #ts-1, 1 do
            app.activeSprite = spr
            app.activeFrame = originalFrame
            app.activeLayer = originalLayer
            local parentAnchorPos
            local parentImageIndex
            if not is_unused_tile(i) then
              find_next_attachment_usage(i, 0)
              if parentLayer:cel(app.activeFrame.frameNumber) then
                parentImageIndex = parentLayer:cel(app.activeFrame.frameNumber).image:getPixel(0, 0)
                local parentAnchor = find_anchor_on_layer(parentLayer, originalLayer, parentImageIndex)
                if parentAnchor then
                  parentAnchorPos = parentAnchor.position
                end
              else
                parentImageIndex = defaultAnchorSample
                parentAnchorPos = defaultParentAnchor.position
              end
            else
              parentImageIndex = defaultAnchorSample
              parentAnchorPos = defaultParentAnchor.position
            end
            local ref = refTileset:tile(i).properties(PK).ref
            if not ref then
              ref = Point(tileSize.width/2, tileSize.height/2)
            end
            local parentPos = tilePosOnTempSprite + ref - parentAnchorPos
            tempSprite:newCel(parentLayerOnTempSprite,
                              i,
                              Image(parentLayer.tileset:tile(parentImageIndex).image),
                              parentPos)
          end
          app.activeSprite = tempSprite
          app.command.LayerOpacity {
            opacity = 128
          }
          app.activeLayer.isEditable = false
        end

        -- Add Attachment editing layer
        if parentLayer then
          editAttachmentLayer = tempSprite:newLayer()
        else
          -- Recycle first layer if no parent found
          editAttachmentLayer = tempSprite.layers[1]
        end
        editAttachmentLayer.name = originalLayer.name

        -- Filling with attachmnts images the Attachment editing layer
        for i=1, #tempSprite.frames, 1 do
          tempSprite:newCel(editAttachmentLayer,
                            i,
                            ts:tile(i).image,
                            tilePosOnTempSprite)
          table.insert(attachmentOriginalPositions, tilePosOnTempSprite)
        end

        app.activeLayer = editAttachmentLayer
        app.activeFrame = ti

        changeDetectionOnCels = {}
        for i=1, #tempSprite.frames, 1 do
          table.insert(changeDetectionOnCels, false)
        end
      end)

    local function accept()
      local changes = changeDetectionOnCels
      changeDetectionOnCels = nil
      app.activeSprite = spr
      if tempSprite ~= nil then
        for i=1, #tempSprite.frames, 1 do
          if changes[i] and editAttachmentLayer:cel(i) then
            local celImage = editAttachmentLayer:cel(i).image
            if not celImage:isEmpty() then
              local image = Image(ts:tile(i).image.spec)
              local pos = editAttachmentLayer:cel(i).position - attachmentOriginalPositions[i]
              image:drawImage(celImage, pos)
              app.transaction("Attachments modified",
                function()
                  ts:tile(i).image = image
                  if not refTileset:tile(i).properties(PK).ref then
                    refTileset:tile(i).properties(PK).ref = Point(tileSize.width/2, tileSize.height/2)
                  end
                end)
            end
          end
        end
        if originalLayer then
          calculate_shrunken_bounds(originalLayer)
        end
      end
      changeDetectionOnCels = nil
      editAttachmentLayer = nil
      editAttachmentDlg:close()
      app.activeFrame = originalFrame
    end

    editAttachmentDlg:button{ text="OK", onclick=accept }
    editAttachmentDlg:button{ text="Cancel", onclick=function() editAttachmentDlg:close() end }
    editAttachmentDlg:show{ wait=false }
    editAttachmentDlg.bounds = Rectangle(60*imi.uiScale,
                                         60*imi.uiScale,
                                         editAttachmentDlg.bounds.width,
                                         editAttachmentDlg.bounds.height)
    popup:close()
    app.refresh()
  end

  local function forEachCategoryTileset(func)
    for i,categoryID in ipairs(activeLayer.properties(PK).categories) do
      local catTileset = db.findTilesetByCategoryID(spr, categoryID)
      func(catTileset)
    end
  end

  local function addInFolderAndBaseSet(ti)
    if folder then
      table.insert(folder.items, { tile=ti, position=find_empty_spot_position(folder, ti) })
    end
    -- Add the tile in the Base Set folder (always)
    if not folder or not db.isBaseSetFolder(folder) then
      local baseSet = db.getBaseSetFolder(activeLayer, folders)
      table.insert(baseSet.items, { tile=ti, position=find_empty_spot_position(baseSet, ti) })
    end
    activeLayer.properties(PK).folders = folders
  end

  local function newEmpty()
    local auxAnchors = {}
    local defaultPos = Point(ts.grid.tileSize.width/2, ts.grid.tileSize.height/2)
    local anchors = ts:tile(1).properties(PK).anchors
    if anchors and #anchors >= 1 then
      for i=1, #anchors, 1 do
        table.insert(auxAnchors, {layerId=anchors[i].layerId,
                                  position=defaultPos})
      end
    end
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
            t.properties(PK).anchors = auxAnchors
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
            tile.properties(PK).anchors = ts:tile(ti).properties(PK).anchors
        end)
        local refTileset = get_base_tileset(activeLayer)
        refTileset:tile(#refTileset-1).properties(PK).ref = refTileset:tile(ti).properties(PK).ref
        if tile then
          addInFolderAndBaseSet(tile.index)
        end
      end)
    popup:close()
  end

  local function delete(repeatedTiOnBaseFolder)
    app.transaction(
      function()
        if db.isBaseSetFolder(folder) and
           not repeatedTiOnBaseFolder and is_unused_tile(ti) then
          forEachCategoryTileset(
            function(ts)
              spr:deleteTile(ts, ti)
            end)

          -- Remap tiles in all tilemaps
          remap_tiles_in_tilemap_layer_delete_index(activeLayer, ti)

          remove_tiles_from_folders(folders, ti)
        else
          remove_tile_from_folder_by_index(folder, indexInFolder)
        end
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
    app.range.frames = frames
  end

  popup:menuItem{ text="Edit &Anchors", onclick=editAnchors }
  popup:menuItem{ text="Align Anchors", onclick=align_anchors }
  popup:separator()
  popup:menuItem{ text="&Edit Attachment", onclick=editAttachment }
  popup:separator()
  popup:menuItem{ text="&New Empty", onclick=newEmpty }
  popup:menuItem{ text="Dupli&cate", onclick=duplicate }
  popup:separator()
  popup:menuItem{ text="Highlight &Usage", onclick=selectFrames }
  popup:menuItem{ text="Find &Next Usage", onclick=function() find_next_attachment_usage(ti, MODE_FORWARD) end }
  popup:menuItem{ text="Find &Prev Usage", onclick=function() find_next_attachment_usage(ti, MODE_BACKWARDS) end }
  local repeatedTiOnBaseFolder = false
  if folder and db.isBaseSetFolder(folder) then
    repeatedTiOnBaseFolder = (count_folder_items_with_tile(folder, ti) > 1)
  end
  if folder and (not db.isBaseSetFolder(folder) or
                 repeatedTiOnBaseFolder or
                 is_unused_tile(ti)) then
    popup:separator()
    popup:menuItem{ text="&Delete", onclick=function() delete(repeatedTiOnBaseFolder) end }
  end
  popup:showMenu()
  imi.repaint = true
end

local function show_tile_info(ti)
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

  -- As the reference point is only in the base category, we have to
  -- check its existence in the base category
  local baseTileset = get_base_tileset(activeLayer)
  if baseTileset:tile(ti).properties(PK).ref == nil then
    imi.alignFunc = function(cursor, size, lastBounds)
      return Point(lastBounds.x+lastBounds.width-size.width-2,
                   lastBounds.y+2)
    end
    imi.label("R")
    imi.widget.color = Color(255, 0, 0)
    imi.alignFunc = nil
  end
end

local function create_tile_view(folders, folder,
                                index, ts, ti,
                                inRc, outSize, itemPos)
  imi.pushID(index)
  local tileImg = ts:getTile(ti)

  local paintAlpha = 255
  if showUnusedTilesSemitransparent and
     tilesHistogram[ti] == nil then
    paintAlpha = 128
  end

  imi.alignFunc = function(cursor, size, lastBounds)
    return Point(imi.viewport.x + itemPos.x*outSize.width - imi.viewportWidget.scrollPos.x,
                 imi.viewport.y + itemPos.y*outSize.height - imi.viewportWidget.scrollPos.y)
  end
  imi.image(tileImg, get_shrunken_bounds_of_image(tileImg), outSize, zoom, paintAlpha)
  imi.alignFunc = nil
  imi.lastBounds = imi.widget.bounds -- Update lastBounds forced
  local imageWidget = imi.widget

  -- focusFolderItem has a value when a keyboard arrow was pressed to
  -- navigate through folder items using the keyboard
  if focusFolderItem and
     focusFolderItem.folder == folder.name and
     focusFolderItem.index == index then
    imi.focusWidget(imi.widget)
    focusFolderItem = nil
  end

  -- focusedItem will contain the active focused folder item (used to
  -- start the keyboard navigation between folder items)
  if imi.focusedWidget and imi.focusedWidget.id == imi.widget.id then
    focusedItem = { folder=folder.name, index=index, tile=ti, position=itemPos }
  end

  imi.widget.onmousedown = function(widget)
    -- Context menu
    if imi.mouseButton == MouseButton.RIGHT then
      show_tile_context_menu(ts, ti, folders, folder, index)
    end
  end

  imi.widget.ondblclick = function(ev)
    set_active_tile(ti)
  end

  if imi.widget.checked then
    imi.widget.checked = false
  end

  -- Show information about the tile (index, usage, R)
  show_tile_info(ti)

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

      local id = db.calculateNewCategoryID(spr)
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
        local newTileset = db.findTilesetByCategoryID(spr, categories[1])
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
      local catTileset = db.findTilesetByCategoryID(spr, categoryID)
      if catTileset == nil then assert(false) end

      local checked = (categoryID == activeTileset.properties(PK).id)
      local name = catTileset.name
      if name == "" then name = kUnnamedCategory end
      popup:menuItem{ text=name, focus=checked,
                      onclick=function()
                        popup:close()
                        app.transaction("Select Category",
                          function()
                            activeLayer.tileset = db.findTilesetByCategoryID(spr, categoryID)
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
    table.sort(folder.items, function(a, b) return a.tile < b.tile end)
    for i=1,#folder.items do
      folder.items[i].position = Point(i-1, 0)
    end
    app.transaction("Sort Folder", function()
      activeLayer.properties(PK).folders = folders
    end)
    imi.dlg:repaint()
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
  if not db.isBaseSetFolder(folder) then
    popup:separator()
    popup:menuItem{ text="Rename Folder", onclick=rename }
    popup:menuItem{ text="Delete Folder", onclick=delete }
  end
  popup:showMenu()
end

local function AttachmentSystem_ShowTilesID()
  if not dlg then return end
  showTilesID = not showTilesID
  imi.repaint = true
end

local function AttachmentSystem_ShowUsage()
  if not dlg then return end
  showTilesUsage = not showTilesUsage
  imi.repaint = true
end

local function AttachmentSystem_ShowUsage()
  if not dlg then return end
  showTilesUsage = not showTilesUsage
  imi.repaint = true
end

local function AttachmentSystem_ShowUnusedTilesSemitransparent()
  if not dlg then return end
  showUnusedTilesSemitransparent = not showUnusedTilesSemitransparent
  imi.repaint = true
end

local function AttachmentSystem_ResetZoom()
  if not dlg then return end
  zoom = 1.0
  imi.repaint = true
end

local function show_options(rc)
  local popup = Dialog{ parent=imi.dlg }
  popup:menuItem{ text="Show Unused Attachment as Semitransparent",
                  onclick=AttachmentSystem_ShowUnusedTilesSemitransparent,
                  selected=showUnusedTilesSemitransparent }
  popup:menuItem{ text="Show Usage",
                  onclick=AttachmentSystem_ShowUsage,
                  selected=showTilesUsage }
  popup:menuItem{ text="Show Tile ID/Index",
                  onclick=AttachmentSystem_ShowTilesID,
                  selected=showTilesID }
  popup:separator()
  popup:menuItem{ text="Reset Zoom", onclick=AttachmentSystem_ResetZoom }
  popup:showMenu()
  imi.repaint = true
end

local function AttachmentSystem_NewFolder()
  if not activeLayer then return end

  local folder = new_or_rename_folder_dialog()
  if folder then
    app.transaction("New Folder", function()
      local layerProperties = db.getLayerProperties(activeLayer)
      folders = layerProperties.folders
      table.insert(folders, folder)
      activeLayer.properties(PK).folders = folders
    end)
  end
  imi.repaint = true
end

local function imi_ongui()
  local spr = app.activeSprite
  local folders

  function new_layer_button()
    if imi.button("New Layer") then
      app.transaction(
        "New Layer",
        function()
          -- Create a new tilemap with the grid bounds as the canvas
          -- bounds and a tileset with one empty tile to start
          -- painting.
          local oldGrid = spr.gridBounds
          spr.gridBounds = spr.bounds
          app.command.NewLayer{ tilemap=true }
          activeLayer = app.activeLayer
          folders = db.getLayerProperties(activeLayer).folders
          spr:newTile(activeLayer.tileset)
          db.setupSprite(spr)
          set_active_tile(1)
          spr.gridBounds = oldGrid
        end)
    end
  end

  if not spr then
    dlg:modify{ title=title }

    if imi.button("New Sprite") then
      app.command.NewFile()
      spr = app.activeSprite
      if spr then
        app.transaction("Setup Attachment System",
                        function() db.setupSprite(spr) end)
        imi.repaint = true
      end
    end
  elseif spr == tempSprite then
    --do nothing
  elseif not spr.properties(PK).version or
         spr.properties(PK).version < db.kLatestDBVersion then
    local label
    if not spr.properties(PK).version then
      label = "Setup Sprite"
    else
      label = "Update Sprite Structure"
    end

    imi.sameLine = true
    if imi.button(label) then
      app.transaction("Setup Attachment System",
                      function() db.setupSprite(spr) end)
      imi.repaint = true
    end
  else
    dlg:modify{ title=title .. " - " .. app.fs.fileTitle(spr.filename) }
    if activeLayer then
      local layerProperties = db.getLayerProperties(activeLayer)
      local categories = layerProperties.categories
      folders = layerProperties.folders

      local inRc = shrunkenBounds
      local outSize = Size(shrunkenSize)
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
        imi.afterGui(AttachmentSystem_NewFolder)
      end

      new_layer_button()
      if imi.button("Options") then
        imi.afterGui(show_options)
      end

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
        imi.sameLine = false
        imi.image(tileImg, get_shrunken_bounds_of_image(tileImg), outSize, zoom)
        if ti > 0 then
          local imageWidget = imi.widget
          do
            imi.sameLine = true
            show_tile_info(ti)
          end
          imi.widget = imageWidget
        end

        -- Context menu for active tile
        imi.widget.onmousedown = function(widget)
          if imi.mouseButton == MouseButton.RIGHT then
            show_tile_context_menu(ts, ti, activeLayer.properties(PK).folders)
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
          imi.endDrop()
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

      -- The focusedItem will be calculated depending on the widget
      -- that has the keyboard focus (imi.focusedWidget)
      focusedItem = nil

      local forceBreak = false
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
          imi.beginViewport(Size(imi.viewport.width,
                                 outSize.height),
                            outSize)

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
            if data and imi.highlightDropItemPos then
              handle_drop_item_in_folder(folders,
                                         data.folder, data.index, data.ti,
                                         folder, imi.highlightDropItemPos)
              imi.repaint = true
            end
            imi.endDrop()
          end

          imi.sameLine = true
          imi.breakLines = false
          imi.margin = 0
          for index=1,#folder.items do
            local folderItem = folder.items[index]
            local ti = folderItem.tile
            local itemPos = folderItem.position

            imi.pushID(index)
            create_tile_view(folders, folder,
                             index, activeLayer.tileset,
                             ti, inRc, outSize, itemPos)

            if imi.beginDrag() then
              imi.setDragData("tile", { index=index, ti=ti, folder=folder.name })
            elseif imi.beginDrop() then
              local data = imi.getDropData("tile")
              if data and imi.highlightDropItemPos then
                handle_drop_item_in_folder(folders,
                                           data.folder, data.index, data.ti,
                                           folder, imi.highlightDropItemPos)
                imi.repaint = true
                forceBreak = true -- because the folder.items was modified
              end
              imi.endDrop()
            end

            imi.widget.checked = false
            imi.popID()

            if forceBreak then
              break
            end
          end

          imi.endViewport()
          imi.margin = 4*imi.uiScale
        end
        imi.endGroup()
        imi.popID()

        if forceBreak then
          break
        end
      end

      imi.endViewport()
      imi.popViewport()
    else
      new_layer_button()
    end
  end
end

local function Sprite_change(ev)
  local repaint = ev.fromUndo

  if activeLayer and activeLayer.isTilemap then
    tilesHistogram = calculate_tiles_histogram(activeLayer)
    local tileImg = get_active_tile_image()
    if tileImg and
       (not activeTileImageInfo or
        tileImg.id ~= activeTileImageInfo.id or
        (tileImg.id == activeTileImageInfo.id and
         tileImg.version > activeTileImageInfo.version)) then
      activeTileImageInfo = { id=tileImg.id,
                              version=tileImg.version }
      calculate_shrunken_bounds(activeLayer)
      if not imi.isongui then
        repaint = true
      end
    else
      activeTileImageInfo = {}
    end
  end

  if changeDetectionOnCels and
     app.activeLayer == editAttachmentLayer then
    changeDetectionOnCels[app.activeFrame.frameNumber] = true
  end

  if repaint then
    imi.dlg:repaint()
  end
end

local function focus_active_attachment()
  local folders = activeLayer.properties(PK).folders
  if not folders then
    return false
  end

  local folder = db.getBaseSetFolder(activeLayer, folders)
  if not folder or not folder.items or #folder.items < 1 then
    return false
  end

  local index = 1
  local cel = app.activeCel
  if cel then
    local ti = cel.image:getPixel(0, 0)
    index = find_first_item_index_in_folder_by_tile(folder, ti)
    if index < 1 then
      index = 1
    end
  end

  local item = folder.items[index]
  focusedItem = { folder=folder.name,
                  index=index,
                  tile=item.tile,
                  position=item.position }
  return true
end

-- Moves the keyboard focus from "focusedItem" to the given "delta"
-- direction in the active viewport, to select the closest attachment
-- in that direction.
local function move_focused_item(delta)
  if not activeLayer then
    return
  end

  -- If there is no focused attachment/item: We focus the active
  -- attachment in the active cel in the base folder. If there is no
  -- active cel, we just select the first attachment in the base
  -- folder.
  if not focusedItem and
     not focus_active_attachment() then
    return
  end
  assert(focusedItem)

  local folders = activeLayer.properties(PK).folders
  local folder
  for i=1,#folders do
    if folders[i].name == focusedItem.folder then
      folder = folders[i]
      break
    end
  end

  if folder then
    local positionBounds = get_folder_position_bounds(folder)
    local position = Point(focusedItem.position)

    -- Navigate to the next item
    while positionBounds:contains(position) do
      position = position + delta
      local newItem = get_folder_item_index_by_position(folder, position)
      if newItem then
        -- Make "position" of new focused item "newItem" visible in
        -- the focused viewport.
        local viewport
        if imi.focusedWidget and
           imi.focusedWidget.parent and
           imi.focusedWidget.parent.scrollPos then
          viewport = imi.focusedWidget.parent
        end
        if viewport then
          local scrollPos = Point(viewport.scrollPos)
          local itemSize = viewport.itemSize
          local itemPos = Point(position.x * itemSize.width,
                                position.y * itemSize.height)
          if itemPos.x < scrollPos.x then
            scrollPos.x = itemPos.x
          elseif itemPos.x > scrollPos.x + viewport.viewportSize.width - itemSize.width then
            scrollPos.x = itemPos.x - viewport.viewportSize.width + itemSize.width
          end
          if itemPos.y < scrollPos.y then
            scrollPos.y = itemPos.y
          elseif itemPos.y > scrollPos.y + viewport.viewportSize.height - itemSize.height then
            scrollPos.y = itemPos.y - viewport.viewportSize.height + itemSize.height
          end
          viewport.setScrollPos(scrollPos)
        end

        focusFolderItem = { folder=folder.name, index=newItem }
        dlg:repaint()
        break
      end
    end
  end
end

local function AttachmentSystem_FocusPrevAttachment()
  move_focused_item(Point(-1, 0))
end

local function AttachmentSystem_FocusNextAttachment()
  move_focused_item(Point(1, 0))
end

local function AttachmentSystem_FocusAttachmentAbove()
  move_focused_item(Point(0, -1))
end

local function AttachmentSystem_FocusAttachmentBelow()
  move_focused_item(Point(0, 1))
end

local function AttachmentSystem_SelectFocusedAttachment()
  -- Select the new tile pressing Enter key
  if focusedItem then
    set_active_tile(focusedItem.tile)
  end
end

local function canvas_onkeydown(ev)
  if not activeLayer or
     not imi.focusedWidget then
    return
  end

  local delta
  if ev.code == "ArrowLeft" then
    delta = Point(-1, 0)
  elseif ev.code == "ArrowRight" then
    delta = Point(1, 0)
  elseif ev.code == "ArrowUp" then
    delta = Point(0, -1)
  elseif ev.code == "ArrowDown" then
    delta = Point(0, 1)
  elseif ev.code == "Enter" or ev.code == "NumpadEnter" then
    AttachmentSystem_SelectFocusedAttachment()
    ev.stopPropagation()
    dlg:repaint()
  elseif ev.code == "Escape" then
    imi.focusedWidget.focused = false
    imi.focusedWidget = nil
    dlg:repaint()
  end

  if delta then
    -- Don't send key to Aseprite as we've just used it
    ev.stopPropagation()
    move_focused_item(delta)
  end
end

local function canvas_onmousedown(ev)
  if ev.ctrlKey and ev.button == MouseButton.MIDDLE then
    zoom = 1.0
    dlg:repaint()
    return
  end
  return imi.onmousedown(ev)
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

local function updateRefAnchorSelector()
  if lockUpdateRefAnchorSelector or not(tempLayerStates) then return end
  for i=1, #tempLayerStates do
    if tempLayerStates[i].layer == app.activeLayer then
      anchorActionsDlg:modify { id="combo",
                                option=tempLayerStates[i].layer.name }
      app.refresh()
      break
    end
  end
end

-- When the active site (active sprite, cel, frame, etc.) changes this
-- function will be called.
local function App_sitechange(ev)

  updateRefAnchorSelector()

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
      calculate_shrunken_bounds(activeLayer)
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

  if not imi.isongui and not ev.fromUndo then
    dlg:repaint() -- TODO repaint only when it's needed
  end
end

local function dialog_onclose()
  if dlgSkipOnCloseFun then return end
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
               onkeydown=canvas_onkeydown,
               onmousemove=imi.onmousemove,
               onmousedown=canvas_onmousedown,
               onmouseup=imi.onmouseup,
               ondblclick=imi.ondblclick,
               onwheel=canvas_onwheel,
               ontouchmagnify=canvas_ontouchmagnify }
    imi.init{ dialog=dlg,
              ongui=imi_ongui,
              canvas="canvas" }
    dlg:show{ wait=false }

    App_sitechange({ fromUndo=false })
    app.events:on('sitechange', App_sitechange)
    observe_sprite(app.activeSprite)
  end
end

local function AttachmentSystem_FindNext()
  local ti = get_active_tile_index()
  if ti then
    find_next_attachment_usage(ti, MODE_FORWARD)
  end
end

local function AttachmentSystem_FindPrev()
  local ti = get_active_tile_index()
  if ti then
    find_next_attachment_usage(ti, MODE_BACKWARDS)
  end
end

local function AttachmentSystem_AlignAnchors()
  align_anchors()
end

function init(plugin)
  local groupId, newSeparator
  if app.apiVersion >= 22 then
    groupId = "AttachmentSystem_Group"
    plugin:newMenuGroup{
      id=groupId,
      title="Attachment System",
      group="view_new"
    }
    newSeparator = function()
      plugin:newMenuSeparator{
        group=groupId
      }
    end
  else
    groupId = "view_new"
    newSeparator = function() end
  end

  plugin:newCommand{
    id="AttachmentSystem_SwitchWindow",
    title="Open/Close Window",
    group=groupId,
    onclick=AttachmentWindow_SwitchWindow
  }

  newSeparator()
  plugin:newCommand{
    id="AttachmentSystem_NextAttachmentUsage",
    title="Find Next Attachment Usage",
    group=groupId,
    onclick=AttachmentSystem_FindNext
  }

  plugin:newCommand{
    id="AttachmentSystem_PrevAttachmentUsage",
    title="Find Previous Attachment Usage",
    group=groupId,
    onclick=AttachmentSystem_FindPrev
  }

  newSeparator()
  plugin:newCommand{
    id="AttachmentSystem_AlignAnchors",
    title="Align Anchors",
    group=groupId,
    onclick=AttachmentSystem_AlignAnchors
  }

  newSeparator()
  plugin:newCommand{
    id="AttachmentSystem_FocusPrevAttachment",
    title="Focus Previous Attachment",
    group=groupId,
    onclick=AttachmentSystem_FocusPrevAttachment
  }

  plugin:newCommand{
    id="AttachmentSystem_FocusNextAttachment",
    title="Focus Next Attachment",
    group=groupId,
    onclick=AttachmentSystem_FocusNextAttachment
  }

  plugin:newCommand{
    id="AttachmentSystem_FocusAttachmentAbove",
    title="Focus Attachment Above",
    group=groupId,
    onclick=AttachmentSystem_FocusAttachmentAbove
  }

  plugin:newCommand{
    id="AttachmentSystem_FocusAttachmentBelow",
    title="Focus Attachment Below",
    group=groupId,
    onclick=AttachmentSystem_FocusAttachmentBelow
  }

  plugin:newCommand{
    id="AttachmentSystem_SelectFocusedAttachment",
    title="Select Focused Attachment",
    group=groupId,
    onclick=AttachmentSystem_SelectFocusedAttachment
  }

  newSeparator()

  plugin:newCommand{
    id="AttachmentSystem_NewFolder",
    title="New Attachments Folder",
    group=groupId,
    onclick=AttachmentSystem_NewFolder
  }

  newSeparator()

  local optionsGroupId = "AttachmentSystem_OptionsGroup"
  plugin:newMenuGroup{
    id=optionsGroupId,
    title="Options",
    group=groupId
  }


  plugin:newCommand{
    id="AttachmentSystem_ShowTilesID",
    title="Show Attachment ID/Index",
    group=optionsGroupId,
    onclick=AttachmentSystem_ShowTilesID
  }

  plugin:newCommand{
    id="AttachmentSystem_ShowUsage",
    title="Show Attachment Usage",
    group=optionsGroupId,
    onclick=AttachmentSystem_ShowUsage
  }

  plugin:newCommand{
    id="AttachmentSystem_ShowUnusedTilesSemitransparent",
    title="Show Unused Attachments as Semitransparent",
    group=optionsGroupId,
    onclick=AttachmentSystem_ShowUnusedTilesSemitransparent
  }

  plugin:newCommand{
    id="AttachmentSystem_ResetZoom",
    title="Reset Attachment Window Zoom",
    group=optionsGroupId,
    onclick=AttachmentSystem_ResetZoom
  }

  showTilesID = plugin.preferences.showTilesID
  showTilesUsage = plugin.preferences.showTilesUsage
  set_zoom(plugin.preferences.zoom)
end

function exit(plugin)
  if dlg then
    dlg:close()
  end

  plugin.preferences.showTilesID = showTilesID
  plugin.preferences.showTilesUsage = showTilesUsage
  plugin.preferences.zoom = zoom
end
