-- Aseprite Attachment System
-- Copyright (c) 2022-2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

local imi = require 'imi'
local db = require 'db'
local pref = require 'pref'
local commands = require 'commands'
local usage = require 'usage'
local editAttachment = require 'edit-attachment'
local main = {}

-- The main window/dialog
local dlg
local title = "Attachment System"
local observedSprite
local activeTilemap -- Active tilemap (nil if the active layer isn't a tilemap)
local shrunkenBoundsCache = {} -- Cache of shrunken bounds
local shrunkenBounds = {} -- Minimal bounds between all tiles of the active layer
local shrunkenSize = Size(1, 1) -- Minimal size between all tiles of the active layer
local activeTileImageInfo = {} -- Used to re-calculate info when the tile image changes
local focusedItem = nil        -- Folder + item with the keyboard focus
local focusFolderItem = nil
local folderWidgets = {}  -- Visible widgets (viewports) representing folders

-- Aliases
local tileI = app.pixelColor.tileI
local tileF = app.pixelColor.tileF

-- Constants
local PK = db.PK
local WindowState = {
  NORMAL = 1,
  SELECT_JOINT_POINT = 2,
}

-- Main window state
local windowState = WindowState.NORMAL
local possibleJoint = nil
local activeAskPoint = nil -- Just to detect if we press the same button again
local showGuessPartsButton = false -- True after inserting an attachment where we can try to guess its parts

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

local function get_all_tilemap_layers()
  local spr = app.sprite
  local output = {}
  local function for_layers(layers)
    for _,layer in ipairs(layers) do
      if layer.isGroup then
        for_layers(layer.layers)
      elseif layer.isTilemap then
        table.insert(output, layer)
      end
    end
  end
  for_layers(spr.layers)
  return output
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

local function remap_tiles_in_tilemap_layer_delete_index(tilemapLayer, deleteTi)
  for _,cel in ipairs(tilemapLayer.cels) do
    local ti = tileI(cel.image:getPixel(0, 0))
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

local function find_tileset_by_name(spr, name)
  -- Special case:
  -- 'name' matches the default name of BaseTileset
  if activeTilemap and activeTilemap.name == name and
     db.getBaseTileset(activeTilemap).name == "" then
    return db.getBaseTileset(activeTilemap)
  end
  -- Other cases:
  for i=1,#spr.tilesets do
    local tileset = spr.tilesets[i]
    if tileset and tileset.name == name then
      return tileset
    end
  end
  return nil
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

local function find_empty_spot_position(folder)
  -- TODO improve this when the viewport has more rows available
  local itemPos = Point(0, 0)
  while true do
    local existentItem = get_folder_item_index_by_position(folder, itemPos)
    if not existentItem then break end
    itemPos.x = itemPos.x+1
  end
  return itemPos
end

local function get_anchor_point_for_layer(ts, ti, layerId)
  local anchors = ts:tile(ti).properties(PK).anchors
  if anchors then
    for _,a in ipairs(anchors) do
      if a.layerId == layerId then
        return a.position
      end
    end
  end
  return nil
end

local function clear_anchor_point(ts, ti, layerId)
  local anchors = ts:tile(ti).properties(PK).anchors
  if not anchors then anchors = {} end
  for i=1,#anchors do
    if anchors[i].layerId == layerId then
      table.remove(anchors, i)
      ts:tile(ti).properties(PK).anchors = anchors
      return
    end
  end
end

local function set_anchor_point(ts, ti, layerId, point)
  local done = false
  local anchors = ts:tile(ti).properties(PK).anchors
  if not anchors then anchors = {} end
  for i=1,#anchors do
    if anchors[i].layerId == layerId then
      anchors[i].position = point
      done = true
      break
    end
  end
  if not done then
    table.insert(anchors, { layerId=layerId, position=point })
  end
  ts:tile(ti).properties(PK).anchors = anchors
end

local function set_ref_point(ts, ti, point)
  ts:tile(ti).properties(PK).ref = point
end

local function create_layers_hierarchy(layers, hierarchy)
  for i=1,#layers do
    local layer = layers[i]
    if layer.isTilemap then
      local layerProperties = layer.properties(PK)
      if layerProperties.id then
        local ts = db.getBaseTileset(layer)
        for ti=1,#ts-1 do
          local anchors = ts:tile(ti).properties(PK).anchors
          if anchors then
            for j=1,#anchors do
              local auxLayer = find_layer_by_id(layers, anchors[j].layerId)
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
    end
    if layer.isGroup then
      create_layers_hierarchy(layer.layers, hierarchy)
    end
  end
end

-- Matches defined reference points <-> anchor points from parent to
-- children in the active frame (app.frame).
--
-- * fromThisLayer: Can be nil to align all attachments/layers or can
--   be a specific layer to align its children (not the layer itself)
--
function main.alignAnchors(fromThisLayerId)
  local spr = app.activeSprite
  if not spr then return end

  local hierarchy = {}
  create_layers_hierarchy(spr.layers, hierarchy)

  local movedLayers = {}
  local function align_layer(childId, parentId, tab, hierarchy_control)
    local child = find_layer_by_id(spr.layers, childId)
    local parent = find_layer_by_id(spr.layers, parentId)

    assert(child)
    assert(parent)

    if hierarchy[parentId] then
      for i=1,#hierarchy_control do
        if hierarchy[parentId] == hierarchy_control[i] then
          app.alert("Hierarchy loop error. Try to fix Parent > Child chain of the next layers: " ..
                    find_layer_by_id(spr.layers, hierarchy_control[i]).name ..
                    " & " ..
                    find_layer_by_id(spr.layers, parentId).name)
          return false
        end
      end
      table.insert(hierarchy_control, parentId)
      if not align_layer(parentId, hierarchy[parentId], tab+1, hierarchy_control) then
        return false
      end
    end

    if not movedLayers[childId] then
      table.insert(movedLayers, childId)

      local fr = app.frame
      do
        local parentCel = parent:cel(fr)
        local childCel = child:cel(fr)
        if parentCel and parentCel.image and
           childCel and childCel.image then
          local parentTs = db.getBaseTileset(parent)
          local parentTi = tileI(parentCel.image:getPixel(0, 0))
          local childTs = db.getBaseTileset(child)
          local childTi = tileI(childCel.image:getPixel(0, 0))

          local refPoint = childTs:tile(childTi).properties(PK).ref
          if refPoint then
            local anchorPoint = get_anchor_point_for_layer(parentTs, parentTi, childId)
            if anchorPoint then
              -- Align refPoint with anchorPoint
              childCel.position =
                parentCel.position + anchorPoint - refPoint
            end
          end
        end
      end
    end
    return true
  end

  -- Break hierarchy to avoid aligning more parents that weren't
  -- requested to be aligned
  if fromThisLayerId and hierarchy[fromThisLayerId] then
    hierarchy[fromThisLayerId] = nil
  end

  app.transaction("Align Anchors", function()
    for childId,parentId in pairs(hierarchy) do
      local hierarchy_control = { childId }
      if not align_layer(childId, parentId, 0, hierarchy_control) then
        break
      end
    end
    app.refresh()
  end)
end

-- 'endChildren' is an in/out vector of layerId's without children
local function find_end_children(layers, endChildren)
  for _,child in ipairs(layers) do
    if child.isTilemap then
      local ts = db.getBaseTileset(child)
      local anchorsFound = false
      for i=1, #ts-1 do
        if ts:tile(i).properties(PK).anchors and
          #ts:tile(i).properties(PK).anchors > 0  then
          anchorsFound = true
          break
        end
      end
      if not anchorsFound then
        table.insert(endChildren, child.properties(PK).id)
      end
    elseif child.isGroup then
      find_end_children(child.layers, endChildren)
    end
  end
end

-- Returns a vector of layerId's with ascending hierarchy.
local function create_ascendant_chain(hierarchy, ascendant_chain)
  local endChild = hierarchy[ascendant_chain[#ascendant_chain]]
  if endChild then
    table.insert(ascendant_chain, endChild)
    ascendant_chain = create_ascendant_chain(hierarchy, ascendant_chain)
  end
  return ascendant_chain
end

-- Returns a vector of layer id's ascending hierarchy vectors.
local function create_ascendant_chains(hierarchy)
  local endChildren = {}
  find_end_children(app.sprite.layers, endChildren)
  local ascendants = {}
  for i=1, #endChildren, 1 do
    table.insert(ascendants,
      create_ascendant_chain(hierarchy, { endChildren[i] }))
  end
  return ascendants
end

-- Dual parenting check
local function will_be_dual_parent(layers, parent, childCandidate)
  for _,otherParent in ipairs(layers) do
    if otherParent.isTilemap and
        otherParent.properties(PK).id ~= parent.properties(PK).id then
      local ts = db.getBaseTileset(otherParent)
      if ts then
        for j=1, #ts-1, 1 do
          if db.findAnchorOnLayer(otherParent, childCandidate, j) then
            return true
          end
        end
      end
    elseif otherParent.isGroup and
            will_be_dual_parent(otherParent.layers, parent, childCandidate) then
      return true
    end
  end
  return false
end

-- Hierarchy loop check
local function is_hierarchy_loop(parent, childCandidate)
  local hierarchy = {}
  create_layers_hierarchy(app.sprite.layers, hierarchy)
  local ascendants = create_ascendant_chains(hierarchy)
  for i=1, #ascendants do
    local ascendant = ascendants[i]
    local ascendantBelongsToChain = false
    local ascendantIndex = 0
    for j=1, #ascendant do
      local layerId = ascendant[j]
      if layerId == parent.properties(PK).id then
        ascendantBelongsToChain = true
        ascendantIndex = j
      end
    end
    if ascendantBelongsToChain then
      for j=1, #ascendant do
        if j ~= ascendantIndex-1 then
          local layerId = ascendant[j]
          if layerId == childCandidate.properties(PK).id then
            return true
          end
        end
      end
    end
  end
  return false
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
      activeTilemap.properties(PK).folders = folders
    end)
end


local function handle_drop_folder(folders, draggedData, insertionPos)
  local movedFolder = table.remove(folders, draggedData.index)
  table.insert(folders, insertionPos, movedFolder)
  app.transaction("Move Folder",
    function()
      activeTilemap.properties(PK).folders = folders
    end)
end

local function get_active_tile_image()
  if activeTilemap then
    local cel = activeTilemap:cel(app.activeFrame)
    if cel and cel.image then
      local ti = tileI(cel.image:getPixel(0, 0))
      return activeTilemap.tileset:getTile(ti)
    end
  end
  return nil
end

-- Returns the active tile index (ti) to apply a command (e.g. Find
-- Prev/Next Usage) or the active item in the given layer.
--
-- When no layer is specified, it will try to return the focusedItem
-- or the activeTilemap tile.
local function get_active_tile_index(layer, frame)
  if not layer then
    -- If there is a focused item, we'll return that one
    if focusedItem then
      return focusedItem.tile
    end
    layer = activeTilemap
  end
  if not frame then
    frame = app.frame
  end
  if layer and layer.isTilemap then
    local cel = layer:cel(frame)
    if cel and cel.image then
      return tileI(cel.image:getPixel(0, 0))
    end
  end
  return nil
end

-- Returns all folders of the active tilemap + the active (focused) folder.
-- Usage:
--   folders, folder = get_active_folder()
local function get_active_folder()
  if activeTilemap then
    local folders = activeTilemap.properties(PK).folders
    local folder
    if focusedItem then
      for i=1,#folders do
        if folders[i].name == focusedItem.folder then
          folder = folders[i]
          break
        end
      end
    else
      folder = db.getBaseSetFolder(activeTilemap, folders)
    end
    return folders, folder
  else
    return nil, nil
  end
end

-- layer can be nil to use the activeTilemap by default
local function set_active_tile(ti, layer)
  if not layer then
    layer = activeTilemap
    if not layer then return end
  end
  assert(layer)
  assert(layer.isTilemap)

  -- Go to normal state
  --
  -- TODO we could create some special UI in such a way that
  --      askPoint() allows to change the active attachment, but it
  --      needs some thought, at the moment if we don't go back to
  --      normal it's confusing
  main.cancelJoint()

  app.transaction("Put Attachment", function()
    local spr = app.sprite
    local layerId = layer.properties(PK).id
    local ts = db.getBaseTileset(layer)
    local cel = layer:cel(app.frame)
    local oldRefPoint
    local newRefPoint

    -- Change tilemap tile if are not showing categories
    -- We use Image:drawImage() to get undo information
    if cel and cel.image then
      local oldTi = tileI(cel.image:getPixel(0, 0))
      if oldTi then
        oldRefPoint = ts:tile(oldTi).properties(PK).ref
      end

      local tilemapCopy = Image(cel.image)
      tilemapCopy:putPixel(0, 0, ti)

      -- This will trigger a Sprite_change() where we
      -- re-calculate shrunken bounds, tiles histogram, etc.
      cel.image:drawImage(tilemapCopy)
    else
      local image = Image(1, 1, ColorMode.TILEMAP)
      image:putPixel(0, 0, ti)

      cel = spr:newCel(layer, app.frame, image, Point(0, 0))
    end

    if ti then
      newRefPoint = ts:tile(ti).properties(PK).ref
    end

    -- Align ref points (between old attachment and new one)
    if oldRefPoint and newRefPoint then
      cel.position = cel.position + oldRefPoint - newRefPoint
    end

    -- Align children of the new attachment layer only
    main.alignAnchors(layerId)

    -- First guess: if the tile is used check if it has children, then
    -- show the "Guess Parts" buttons
    if layer == activeTilemap then
      showGuessPartsButton = false
      if usage.isUsedTile(ti) then
        local ts = db.getBaseTileset(layer)
        local anchors = ts:tile(ti).properties(PK).anchors
        if anchors and #anchors > 0 then
          showGuessPartsButton = true
        end
      end
    end

    imi.repaint()
    app.refresh()
  end)
end

local function flip_type_to_orientation(flipType)
  if flipType == FlipType.VERTICAL then
    return "vertical"
  else
    return "horizontal"
  end
end

local function flip_attachment(flipType, cel, ignoreRefAsPivot)
  local newImageId
  assert(cel and cel.image)
  if cel.layer.isTilemap then
    local baseTileset = db.getBaseTileset(cel.layer)
    local ti = tileI(cel.image:getPixel(0, 0))
    local tile = cel.layer.tileset:tile(ti)
    local copy = Image(tile.image)
    copy:flip(flipType)
    tile.image = copy
    local tileImg = tile.image
    newImageId = tileImg.id

    -- Flip from reference point and anchor points
    local properties = baseTileset:tile(ti).properties(PK)
    local ref = properties.ref
    local anchors = properties.anchors
    if ref then
      if flipType == FlipType.HORIZONTAL then
        ref.x = copy.width - ref.x
      else
        ref.y = copy.height - ref.y
      end
      if not ignoreRefAsPivot then
        cel.position = cel.position + properties.ref - ref
      end
      properties.ref = ref
    end

    if not ref or ignoreRefAsPivot then
      local spr = cel.sprite
      local center = Point(copy.width/2 - cel.position.x,
                           copy.height/2 - cel.position.y)
      local ref = Point(center)
      if flipType == FlipType.HORIZONTAL then
        ref.x = copy.width - ref.x
      else
        ref.y = copy.height - ref.y
      end
      cel.position = cel.position + center - ref
    end

    if anchors then
      for i = 1,#anchors do
        local anchor = anchors[i]
        if flipType == FlipType.HORIZONTAL then
          anchor.position.x = copy.width - anchor.position.x
        else
          anchor.position.y = copy.height - anchor.position.y
        end
        anchors[i] = anchor
      end
      properties.anchors = anchors
    end
    baseTileset:tile(ti).properties(PK, properties)
  else
    -- Simulate app.command.Flip
    cel.image:flip(flipType)
    newImageId = cel.image.id

    local spr = cel.sprite
    local pos = cel.position
    if flipType == FlipType.HORIZONTAL then
      pos.x = spr.width - cel.image.width - pos.x
    else
      pos.y = spr.height - cel.image.height - pos.y
    end
    cel.position = pos
  end
  return newImageId
end

local function flip_active_attachment(flipType)
  app.transaction("Flip", function()
    flip_attachment(flipType, app.cel)
  end)
  imi.repaint()
  app.refresh()
end

local function flip_range(flipType)
  app.transaction("Flip Range", function()
    local oldSite = app.site
    local range = app.range

    local alreadyFlipped = {}
    for _,editableImage in ipairs(range.editableImages) do
      local cel = editableImage.cel
      if cel.layer.isTilemap then
        local ti = tileI(cel.image:getPixel(0, 0))
        local tileImage = cel.layer.tileset:getTile(ti)
        if not tileImage or alreadyFlipped[tileImage.id] then
          -- Avoid flipping two times the same image
        else
          local newImageId = flip_attachment(
            flipType, cel,
            -- Flip ranges using the center of the
            -- canvas, instead of the ref point
            true)
          alreadyFlipped[newImageId] = true
        end
      elseif not alreadyFlipped[cel.image.id] then
        local newImageId = flip_attachment(flipType, cel)
        alreadyFlipped[newImageId] = true
      end
    end
  end)
  imi.repaint()
  app.refresh()
end

local function insert_guessed_parts(fromLayerId, ti, hierarchy)
  local spr = app.sprite
  if not hierarchy then
    hierarchy = {}
    create_layers_hierarchy(spr.layers, hierarchy)
  end

  -- Get all frame numbers where the "ti" attachment is used

  local layer = find_layer_by_id(spr.layers, fromLayerId)
  local frames = {}
  for fr=1,#spr.frames do
    if get_active_tile_index(layer, fr) == ti then
      table.insert(frames, fr)
    end
  end

  -- Guess what are the most common children parts for "ti"

  local partsHistogram = {}

  for childId,parentId in pairs(hierarchy) do
    if parentId == fromLayerId then
      local child = find_layer_by_id(spr.layers, childId)
      local histogram = {}

      for _,fr in ipairs(frames) do
        local cel = child:cel(fr)
        if cel and cel.image then
          local partTi = tileI(cel.image:getPixel(0, 0))
          if not histogram[partTi] then
            histogram[partTi] = 1
          else
            histogram[partTi] = histogram[partTi] + 1
          end
        end
      end

      partsHistogram[childId] = histogram
    end
  end

  -- Create an array of actions (sub parts to change), if there is no
  -- actions, there is no undoable transaction

  local actions = {}
  for k,v in pairs(partsHistogram) do
    local bestPartTi = nil
    for ti,n in pairs(v) do
      if bestPartTi == nil or v[bestPartTi] < n then
        bestPartTi = ti
      end
    end
    if bestPartTi then
      table.insert(actions, { childId=k, ti=bestPartTi })
    end
  end

  if #actions > 0 then
    app.transaction("Guess Parts", function()
      for _,action in ipairs(actions) do
        local child = find_layer_by_id(spr.layers, action.childId)
        set_active_tile(action.ti, child)
        insert_guessed_parts(action.childId, action.ti, hierarchy)
      end

      -- Re-align all children
      if layer == activeTilemap then
        main.alignAnchors(fromLayerId)
      end
    end)
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

local function for_each_category_tileset(func)
  assert(activeTilemap)
  local spr = activeTilemap.sprite
  for i,categoryID in ipairs(activeTilemap.properties(PK).categories) do
    local catTileset = db.findTilesetByCategoryID(spr, categoryID)
    func(catTileset)
  end
end

local function check_categories_consistency(actionName)
  assert(activeTilemap)
  local ok = true
  local ntiles = -1
  for_each_category_tileset(function(ts)
    if ntiles < 0 then
      ntiles = #ts
    elseif ntiles ~= #ts then
      ok = false
    end
  end)
  if not ok then
    local lines = { string.format("Inconsistent categories for layer \"%s\":",
                                  activeTilemap.name) }
    for_each_category_tileset(function(ts)
      table.insert(lines, string.format("* Category=\"%s\", #attachments=%d", ts.name, #ts))
    end)
    table.insert(lines, "")
    table.insert(lines, "The \"fix\" consists on adding missing attachment at the end of each category,")
    table.insert(lines, "which might break the alignment of attachment between categories anyway.")
    local result =
      app.alert{ title="Inconsistent Categories",
                 text=lines,
                 buttons={"&Fix && " .. actionName, "&Cancel"} }

    if result == 1 then
      app.transaction("Fix Categories", function()
        for_each_category_tileset(function(ts)
            while #ts < ntiles do
              app.sprite:newTile(ts)
            end
        end)
      end)
      ok = true
    end
  end
  return ok
end

local function add_in_folder_and_base_set(folders, folder, ti)
  assert(activeTilemap)
  if folder then
    table.insert(folder.items, { tile=ti, position=find_empty_spot_position(folder) })
  end
  -- Add the tile in the Base Set folder (always)
  if not folder or not db.isBaseSetFolder(folder) then
    local baseSet = db.getBaseSetFolder(activeTilemap, folders)
    table.insert(baseSet.items, { tile=ti, position=find_empty_spot_position(baseSet) })
  end
  activeTilemap.properties(PK).folders = folders
end

function main.newEmptyAttachment()
  local spr = activeTilemap.sprite
  local ts = activeTilemap.tileset
  local folders, folder = get_active_folder()

  -- TODO is it really needed to copy these anchors to the new empty attachment?
  local auxAnchors = {}
  local defaultPos = Point(ts.grid.tileSize.width/2, ts.grid.tileSize.height/2)
  local anchors = ts:tile(1).properties(PK).anchors
  if anchors and #anchors >= 1 then
    for i=1, #anchors, 1 do
      table.insert(auxAnchors, {layerId=anchors[i].layerId,
                                position=defaultPos})
    end
  end

  if not check_categories_consistency("Create Empty Attachment") then
    return
  end

  local tile
  app.transaction("New Empty Attachment", function()
    for_each_category_tileset(function(ts)
      local t = spr:newTile(ts)
      if tile == nil then
        tile = t
      else
        -- The tile index must be the same on all categories
        assert(t.index == tile.index)
      end
      t.properties(PK).anchors = auxAnchors
    end)
    if folders and folder and tile then
      add_in_folder_and_base_set(folders, folder, tile.index)
    end
  end)
  imi.repaint()

  if tile then
    return tile.index
  else
    return nil
  end
end

function main.duplicateAttachment()
  assert(activeTilemap)
  local spr = activeTilemap.sprite
  local ts = activeTilemap.tileset
  local ti = get_active_tile_index()
  local folders, folder = get_active_folder()
  local origTile = ts:tile(ti)

  if not check_categories_consistency("Duplicate Attachment") then
    return
  end

  app.transaction("Duplicate Attachment", function()
    local tile
    for_each_category_tileset(function(ts)
      tile = spr:newTile(ts)
      tile.image:clear()
      tile.image:drawImage(ts:tile(ti).image)
      tile.properties(PK).anchors = ts:tile(ti).properties(PK).anchors
    end)

    -- Copy ref point in the base tileset
    local baseTileset = db.getBaseTileset(activeTilemap)
    baseTileset:tile(#baseTileset-1).properties(PK).ref =
      baseTileset:tile(ti).properties(PK).ref

    if folders and folder and tile then
      add_in_folder_and_base_set(folders, folder, tile.index)
    end
  end)
  imi.repaint()
end

function main.editAttachment()
  local ti = get_active_tile_index()
  if editAttachment.isEditing(app.sprite) then
    editAttachment.acceptChanges()
  else
    editAttachment.startEditing(ti,
      -- After editing callback (OK or Cancel)
      function()
        if app.layer and app.layer.isTilemap then
          calculate_shrunken_bounds(app.layer)
        end
      end)
  end
end

function main.deleteAttachment()
  local spr = activeTilemap.sprite
  local ti = get_active_tile_index()
  local folders, folder = get_active_folder()
  local indexInFolder
  if focusedItem then
    indexInFolder = focusedItem.index
  end

  local repeatedTiOnBaseFolder = false
  if folder and db.isBaseSetFolder(folder) then
    repeatedTiOnBaseFolder = (count_folder_items_with_tile(folder, ti) > 1)
  end
  if folder and (not db.isBaseSetFolder(folder) or
                 repeatedTiOnBaseFolder or
                 usage.isUnusedTile(ti)) then
    -- True if we can call Sprite:deleteTile(), or false if we just
    -- remove the tile from the folder.
    local canDelete =
      (db.isBaseSetFolder(folder) and
       not repeatedTiOnBaseFolder and
       usage.isUnusedTile(ti))

    if canDelete then
      if not check_categories_consistency("Delete Attachment") then
        return
      end
    end

    app.transaction("Delete Attachment", function()
      if canDelete then
        for_each_category_tileset(function(ts)
            if ti < #ts then
              spr:deleteTile(ts, ti)
            end
        end)

        -- Remap tiles in all tilemaps
        remap_tiles_in_tilemap_layer_delete_index(activeTilemap, ti)

        remove_tiles_from_folders(folders, ti)
      else
        -- Just remove from the folder
        remove_tile_from_folder_by_index(folder, indexInFolder)
      end
      activeTilemap.properties(PK).folders = folders
    end)
    imi.repaint()
  end
end

-- Select all the active layers' frames where the selected attachment
-- is used.
function main.highlightUsage()
  local ti = get_active_tile_index()
  local frames = {}
  for _,cel in ipairs(activeTilemap.cels) do
    if cel.image then
      local celTi = tileI(cel.image:getPixel(0, 0))
      if celTi == ti then
        table.insert(frames, cel.frameNumber)
      end
    end
  end
  app.range.frames = frames
end

local function unlink_anchor(anchorLayerId)
  assert(app.layer and app.cel and app.cel.image)
  assert(find_layer_by_id(app.layer.sprite.layers, anchorLayerId))

  -- Get the tile from the base tileset to get ref/anchor points
  local layerA = app.layer
  local layerB = find_layer_by_id(layerA.sprite.layers, anchorLayerId)

  if not layerB.tileset then
    return app.alert(layerB.name .. " doesn't have a tileset. Action aborted.")
  end

  local tsA = db.getBaseTileset(layerA)
  local tsB = db.getBaseTileset(layerB)
  local idB = layerB.properties(PK).id

  for i=1, #tsA-1 do
    clear_anchor_point(tsA, i, idB)
  end
  for i=1, #tsB-1 do
    local refOnB = tsB:tile(i).properties(PK).ref
    if refOnB then
      tsB:tile(i).properties(PK).ref = nil
    end
  end
  dlg:repaint()
end

local function swap_hierarchy(anchorLayerId)
  assert(app.layer and app.cel and app.cel.image)
  assert(find_layer_by_id(app.layer.sprite.layers, anchorLayerId))

  local layerA = app.layer -- parent, future child
  local layerB = find_layer_by_id(layerA.sprite.layers, anchorLayerId) -- child, future parent

  if not layerB.tileset then
    return app.alert("Candidate parent layer " .. layerB.name .. " doesn't have a tileset. Action aborted.")
  end
  if will_be_dual_parent(app.sprite.layers, layerB, layerA) then
    local parent1 = db.findParentLayer(app.sprite.layers, layerA).name
    local parent2 = layerB.name
    return app.alert("Hierarchy cannot be swapped: candidate child '" ..
      layerA.name .. "' will have '" .. parent1 .. "' & '" .. parent2 ..
      "' as parents. Action aborted.")
  end

  local tsA = db.getBaseTileset(layerA)
  local tsB = db.getBaseTileset(layerB)
  local idA = layerA.properties(PK).id
  local idB = layerB.properties(PK).id

  for i=1, #tsA-1 do
    local anchorOnA = db.findAnchorOnLayer(layerA, layerB, i)
    if anchorOnA then
      local pos = anchorOnA.position
      clear_anchor_point(tsA, i, idB)
      tsA:tile(i).properties(PK).ref = pos
    end
  end

  for i=1, #tsB-1 do
    local refOnB = tsB:tile(i).properties(PK).ref
    if refOnB then
      tsB:tile(i).properties(PK).ref = nil
      set_anchor_point(tsB, i, idA, refOnB)
    end
  end

  dlg:repaint()
end

local function show_ref_context_menu(tile)
  local popup = Dialog{ parent=imi.dlg }

  popup:menuItem{ text="&Delete RefPoint",
                  onclick=function()
                    app.transaction("Delete RefPoint", function()
                      tile.properties(PK).ref = nil
                    end)
                  end}
  popup:showMenu()
  imi.dlg:repaint()
end

local function show_anchor_context_menu(anchorLayerId, tile, anchorI)
  local popup = Dialog{ parent=imi.dlg }

  popup:menuItem{ text="&Delete Anchor",
                  onclick=function()
                    app.transaction("Delete Anchor Point", function()
                      local anchors = tile.properties(PK).anchors
                      table.remove(anchors, anchorI)
                      tile.properties(PK).anchors = anchors
                    end)
                  end}
  popup:separator()
  popup:menuItem{ text="&Unlink",
                  onclick=function()
                    app.transaction("Unlink Anchor", function()
                      unlink_anchor(anchorLayerId)
                    end)
                  end}
  popup:menuItem{ text="&Swap Hierarchy",
                  onclick=function()
                    app.transaction("Swap Hierarchy", function()
                      swap_hierarchy(anchorLayerId)
                    end)
                  end }
  popup:showMenu()
  imi.dlg:repaint()
end

local function show_tile_context_menu(ts, ti, folders, folder, indexInFolder)
  local popup = Dialog{ parent=imi.dlg }

  local oldFocusedItem = focusedItem
  if folder then
    focusedItem = { folder=folder.name, index=indexInFolder, tile=ti }
  else
    focusedItem = nil
  end

  popup:menuItem{ text="&Align Anchors", onclick=commands.AlignAnchors }
  popup:separator()
  popup:menuItem{ text="Ne&w Empty", onclick=commands.NewEmptyAttachment }
  popup:menuItem{ text="Dupli&cate", onclick=commands.DuplicateAttachment }
  popup:separator()
  popup:menuItem{ text="&Edit Attachment", onclick=commands.EditAttachment }
  popup:separator()
  popup:menuItem{ text="&Highlight Usage", onclick=commands.HighlightUsage }
  popup:menuItem{ text="Find &Next Usage", onclick=commands.FindNext }
  popup:menuItem{ text="Find &Prev Usage", onclick=commands.FindPrev }
  local repeatedTiOnBaseFolder = false
  if folder and db.isBaseSetFolder(folder) then
    repeatedTiOnBaseFolder = (count_folder_items_with_tile(folder, ti) > 1)
  end
  if folder and (not db.isBaseSetFolder(folder) or
                 repeatedTiOnBaseFolder or
                 usage.isUnusedTile(ti)) then
    popup:separator()
    popup:menuItem{ text="&Delete", onclick=commands.DeleteAttachment }
  end
  popup:showMenu()

  focusedItem = oldFocusedItem
  imi.repaint()
end

local function show_tile_info(ti)
  if pref.showTilesID then
    imi.alignFunc = function(cursor, size, lastBounds)
      return Point(lastBounds.x+2,
                   lastBounds.y+lastBounds.height-size.height-2)
    end
    imi.label(string.format("[%d]", ti))
    imi.widget.color = app.theme.color.textbox_text
    imi.alignFunc = nil
  end
  if pref.showTilesUsage then
    local label
    if usage.isUnusedTile(ti) then
      label = "Unused"
    else
      label = tostring(usage.getTileFreq(ti))
    end
    imi.alignFunc = function(cursor, size, lastBounds)
      return Point(lastBounds.x+2,
                   lastBounds.y+2)
    end
    imi.label(label)
    imi.widget.color = app.theme.color.textbox_text
    imi.alignFunc = nil
  end

  -- As the reference point is only in the base category, we have to
  -- check its existence in the base category
  local baseTileset = db.getBaseTileset(activeTilemap)
  if baseTileset:tile(ti).properties(PK).ref == nil then
    imi.alignFunc = function(cursor, size, lastBounds)
      return Point(lastBounds.x+lastBounds.width-size.width-2,
                   lastBounds.y+2)
    end
    imi.label("R")
    imi.widget.color = app.theme.color.flag_active
    imi.alignFunc = nil
  end
end

local function create_tile_view(folders, folder,
                                index, ts, ti,
                                inRc, outSize, itemPos)
  imi.pushID(index)
  local tileImg = ts:getTile(ti)

  local paintAlpha = 255
  if pref.showUnusedTilesSemitransparent and usage.isUnusedTile(ti) then
    paintAlpha = 128
  end

  imi.alignFunc = function(cursor, size, lastBounds)
    return Point(imi.viewport.x + itemPos.x*outSize.width - imi.viewportWidget.scrollPos.x,
                 imi.viewport.y + itemPos.y*outSize.height - imi.viewportWidget.scrollPos.y)
  end
  imi.image(tileImg, get_shrunken_bounds_of_image(tileImg), outSize, pref.zoom, paintAlpha)
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

  imi.widget.oncontextmenu = function()
    show_tile_context_menu(ts, ti, folders, folder, index)
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
  local spr = activeTilemap.sprite

  if not data.ok then
    return
  elseif data.name == "" then
    return app.alert("Empty names are not allowed.")
  end

  -- Check that we cannot create two tilesets with the same name
  local ts = find_tileset_by_name(spr, data.name)
  if ts then
    if ts == categoryTileset then
      return
    end
    return app.alert("A category named '" .. data.name .. "' already exist. " ..
                     "You cannot have two categories with the same name")
  end
  if categoryTileset then
    app.transaction("Rename Category", function()
      categoryTileset.name = data.name
    end)
  else
    local id = db.calculateNewCategoryID(spr)
    app.transaction("New Category", function()
      local cloned = spr:newTileset(activeTilemap.tileset)
      cloned.properties(PK).id = id
      cloned.name = data.name

      local categories = activeTilemap.properties(PK).categories
      if not categories then categories = {} end
      table.insert(categories, id)
      activeTilemap.properties(PK).categories = categories
      activeTilemap.tileset = cloned
      app.refresh()
    end)
  end
end

local function show_categories_selector(categories, activeTileset)
  local spr = app.activeSprite
  local categories = activeTilemap.properties(PK).categories

  local function rename()
    new_or_rename_category_dialog(activeTileset)
  end

  local function delete()
    app.transaction("Delete Category", function()
      if categories then
        local catID = activeTileset.properties(PK).id
        local catIndex = find_index(categories, catID)

        -- Remove the category/tileset
        table.remove(categories, catIndex)
        activeTilemap.properties(PK).categories = categories

        -- We set the tileset of the layer to the first category available
        local newTileset = db.findTilesetByCategoryID(spr, categories[1])
        local oldTileset = activeTilemap.tileset
        activeTilemap.tileset = newTileset

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
      if name == "" then name = activeTilemap.name end

      popup:menuItem{ text=name, focus=checked,
                      onclick=function()
                        popup:close()
                        app.transaction("Select Category",
                          function()
                            activeTilemap.tileset = db.findTilesetByCategoryID(spr, categoryID)
                          end)
                        app.refresh()
                      end }:newrow()
    end
    popup:separator()
  end
  popup:menuItem{ text="&New Category",
                  onclick=function()
                    popup:close()
                    new_or_rename_category_dialog()
                    imi.repaint()
                  end }
  popup:menuItem{ text="&Rename Category", onclick=rename }
  if #categories > 1 then
    popup:menuItem{ text="&Delete Category", onclick=delete }
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
      activeTilemap.properties(PK).folders = folders
    end)
    imi.repaint()
  end

  local function sortByUsage()
    usage.calculateHistogram(activeTilemap)
    table.sort(folder.items, function(a, b)
      local ua = usage.getTileFreq(a.tile)
      local ub = usage.getTileFreq(b.tile)
      return ((ua > ub) or (ua == ub and a.tile < b.tile))
    end)
    for i=1,#folder.items do
      folder.items[i].position = Point(i-1, 0)
    end
    app.transaction("Sort Folder", function()
      activeTilemap.properties(PK).folders = folders
    end)
    imi.repaint()
  end

  local missingItems = {}
  local function countMissingItems()
    for ti = 1,#activeTilemap.tileset-1 do
      local found = false
      for i=1,#folder.items do
        if folder.items[i].tile == ti then
          found = true
          break
        end
      end
      if not found then
        table.insert(missingItems, ti)
      end
    end
  end

  local function addMissingItems()
    if #missingItems > 0 then
      local lastPos = 0
      for i=1,#folder.items do
        lastPos = math.max(lastPos, folder.items[i].position.x+1)
      end
      for i,ti in ipairs(missingItems) do
        table.insert(folder.items, { tile=ti, position=Point(lastPos, 0) })
        lastPos = lastPos+1
      end
      app.transaction("Add Missing Items to Base Set", function()
        activeTilemap.properties(PK).folders = folders
      end)
    end
  end

  local function rename()
    folder = new_or_rename_folder_dialog(folder)
    app.transaction("Rename Folder", function()
      activeTilemap.properties(PK).folders = folders
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
        activeTilemap.properties(PK).folders = folders
      end)
    end
  end

  local popup = Dialog{ parent=imi.dlg }
  popup:menuItem{ text="&Sort by Tile Index/ID", onclick=sortByIndex }
  popup:menuItem{ text="Sort by &Usage", onclick=sortByUsage }
  if db.isBaseSetFolder(folder) then
    countMissingItems()
    if #missingItems > 0 then
      popup:separator()
      popup:menuItem{ text="&Add Missing Items", onclick=addMissingItems }
    end
  else
    popup:separator()
    popup:menuItem{ text="&Rename Folder", onclick=rename }
    popup:menuItem{ text="&Delete Folder", onclick=delete }
  end
  popup:showMenu()
end

local function show_options(rc)
  local popup = Dialog{ parent=imi.dlg }
  popup:menuItem{ text="Show Unused Attachment as &Semitransparent",
                  onclick=commands.ShowUnusedTilesSemitransparent,
                  selected=pref.showUnusedTilesSemitransparent }
  popup:menuItem{ text="Show &Usage",
                  onclick=commands.ShowUsage,
                  selected=pref.showTilesUsage }
  popup:menuItem{ text="Show Tile &ID/Index",
                  onclick=commands.ShowTilesID,
                  selected=pref.showTilesID }
  popup:separator()
  popup:menuItem{ text="Capture Arrow &Keys",
                  onclick=function()
                    pref.captureArrowKeys = not pref.captureArrowKeys
                  end,
                  selected=pref.captureArrowKeys }
  popup:separator()
  popup:menuItem{ text="Reset &Zoom", onclick=commands.ResetZoom }
  popup:showMenu()
  imi.repaint()
end

local function get_possible_attachments(point)
  local output = {}
  local layers = get_all_tilemap_layers()
  local mask = app.sprite.transparentColor
  for _,layer in ipairs(layers) do
    local cel = layer:cel(app.frame)
    if cel and cel.image and cel.bounds:contains(point) then
      -- Use original layer tileset to get shruken bounds its tiles
      local ts = layer.tileset
      local ti = tileI(cel.image:getPixel(0, 0))
      local tileImg = ts:getTile(ti)
      local u = point - cel.position
      if get_shrunken_bounds_of_image(tileImg):contains(u) then
        table.insert(output, cel.layer)
      end
    end
  end
  return output
end

local function insert_joint(layerA, layerB, point)
  app.transaction("Insert Joint", function()
    local spr = app.sprite
    assert(spr)

    local idA = layerA.properties(PK).id
    local idB = layerB.properties(PK).id
    local tsA = db.getBaseTileset(layerA)
    local tsB = db.getBaseTileset(layerB)
    local celA = layerA:cel(app.frame)
    local celB = layerB:cel(app.frame)
    local tiA = tileI(celA.image:getPixel(0, 0))
    local tiB = tileI(celB.image:getPixel(0, 0))

    set_anchor_point(tsA, tiA, idB, point - celA.position)
    set_ref_point(tsB, tiB, point - celB.position)
  end)
end

local function flip_active_tile_flags(label, flipFlag)
  if not activeTilemap then return false end
  local cel = activeTilemap:cel(app.activeFrame)
  if not cel then return false end

  app.transaction(
    label,
    function()
      local t = cel.image:getPixel(0, 0)
      local ti = tileI(t)
      local tf = tileF(t)
      local img = cel.image
      local tilemapCopy = Image(img)
      tf = tf ~ flipFlag
      tilemapCopy:putPixel(0, 0, ti | tf)
      cel.image:drawImage(tilemapCopy)
    end)

  app.refresh()
  return true
end

function main.newFolder()
  if not activeTilemap then return end

  local folder = new_or_rename_folder_dialog()
  if folder then
    app.transaction("New Folder", function()
      local layerProperties = db.getLayerProperties(activeTilemap)
      local folders = layerProperties.folders
      table.insert(folders, folder)
      activeTilemap.properties(PK).folders = folders
    end)
  end
  imi.repaint()
end

local function imi_ongui()
  local spr = app.activeSprite
  local folders

  imi.sameLine = true

  local function new_layer_button()
    if imi.button("New Layer") then
      app.transaction("New Layer", function()
        -- Create a new tilemap with the grid bounds as the canvas
        -- bounds and a tileset with one empty tile to start
        -- painting.
        app.command.NewLayer{ tilemap=true, gridBounds=spr.bounds }
        activeTilemap = app.activeLayer
        folders = db.getLayerProperties(activeTilemap).folders
        db.setupSprite(spr)
        set_active_tile(1)
      end)
      imi.repaint()
    end
  end

  -- Editing attachments
  if editAttachment.isEditing(spr) then

    imi.label("Editing Attachments...")
    imi.sameLine = false
    if imi.button("OK") then
      editAttachment.acceptChanges()
    end

    imi.sameLine = true
    if imi.button("Cancel") then
      editAttachment.cancelChanges()
    end

  -- No active sprite: Show a button to create a new sprite
  elseif not spr then
    dlg:modify{ title=title }

    if imi.button("New Sprite") then
      app.command.NewFile()
      spr = app.activeSprite
      if spr then
        app.transaction("Setup Attachment System",
                        function() db.setupSprite(spr) end)
        imi.repaint()
      end
    end

  -- Old DB schema? Show a button to create the internal DB or update it
  elseif not spr.properties(PK).version or
         spr.properties(PK).version < db.kLatestDBVersion then
    local label
    if not spr.properties(PK).version then
      label = "Setup Sprite"
    else
      label = "Update Sprite Structure"
    end

    if imi.button(label) then
      app.transaction("Setup Attachment System",
                      function() db.setupSprite(spr) end)
      imi.repaint()
    end

  -- Show options to create a joint between two layers in the current frame
  elseif windowState == WindowState.SELECT_JOINT_POINT then

    imi.label("Select Joint")
    if possibleJoint then
      local pt = possibleJoint
      local attachments = get_possible_attachments(pt)

      imi.label(pt.x .. "x" .. pt.y)
      imi.sameLine = false

      local noButtonShown = true
      if #attachments >= 2 then
        for i = 1,#attachments-1 do
          local a = attachments[i]
          local b = attachments[i+1]

          local function addParentChildButton(parent, childCandidate, sameLine)
            if not will_be_dual_parent(app.sprite.layers, parent, childCandidate) and
               not is_hierarchy_loop(parent, childCandidate) then
              noButtonShown = false
              local label = parent.name .. " > " .. childCandidate.name
              imi.pushID(i .. label)
              if imi.button(label) then
                insert_joint(parent, childCandidate, pt)
                main.cancelJoint()
              end
              imi.sameLine = sameLine
              imi.popID()
            end
          end

          addParentChildButton(a, b, true)
          addParentChildButton(b, a, false)
        end
        if noButtonShown then
          imi.label("No viable anchor to assign.")
        end
      elseif #attachments == 1 then
        imi.label("One attachment: " .. attachments[1].name)
      else
        imi.label("No attachments")
      end
      imi.sameLine = false

      if imi.button("Cancel") then
        main.cancelJoint()
      end
    end

  -- Main UI to arrange and drag-and-drop attachments
  else
    dlg:modify{ title=title .. " - " .. app.fs.fileTitle(spr.filename) }
    if activeTilemap then
      local layerProperties = db.getLayerProperties(activeTilemap)
      local categories = layerProperties.categories
      folders = layerProperties.folders

      local inRc = shrunkenBounds
      local outSize = Size(shrunkenSize)
      outSize.width = outSize.width * pref.zoom
      outSize.height = outSize.height * pref.zoom

      -- Active Category / Categories
      imi.sameLine = true
      local activeTileset = activeTilemap.tileset

      local name = activeTileset.name
      if name == "" then name = activeTilemap.name end

      if imi.button(name) then
        -- Show popup to select other category
        imi.afterGui(
          function()
            show_categories_selector(categories, activeTileset)
          end)
      end
      imi.widget.oncontextmenu = function() -- TODO merge this with regular imi.button() click
        show_categories_selector(categories, activeTileset)
      end

      if imi.button("New Folder") then
        imi.afterGui(commands.NewFolder)
      end

      new_layer_button()
      if imi.button("Options") then
        imi.afterGui(show_options)
      end

      -- Active tile

      local ts = activeTilemap.tileset
      local cel = activeTilemap:cel(app.activeFrame)
      local ti = 0
      if cel and cel.image then
        ti = tileI(cel.image:getPixel(0, 0))
      end
      do
        local tileImg = ts:getTile(ti)
        -- Get the tile from the base tileset to get ref/anchor points
        local tile = db.getBaseTileset(activeTilemap):tile(ti)

        -- Tile preview + ref/anchors point buttons
        imi.sameLine = false
        imi.beginGroup()

        -- Show active tile in active cel
        imi.image(tileImg, get_shrunken_bounds_of_image(tileImg), outSize, pref.zoom)
        local imageWidget = imi.widget
        if ti > 0 then
          do
            imi.sameLine = true
            show_tile_info(ti)
          end
          imi.widget = imageWidget
        end

        -- Buttons to change flip horizontally/vertically
        imi.sameLine = false
        if imi.button("H") then
          flip_active_tile_flags("Flip H", app.pixelColor.TILE_XFLIP)
        end
        imi.margin = 0
        imi.sameLine = true
        if imi.button("V") then
          flip_active_tile_flags("Flip V", app.pixelColor.TILE_YFLIP)
        end
        imi.margin = 4*imi.uiScale

        -- Buttons to change points
        imi.sameLine = false
        if tile.properties(PK).ref then
          if imi.button("RefPoint") then
            if activeAskPoint and activeAskPoint.ref then
              app.editor:cancel()
              activeAskPoint = nil
            else
              activeAskPoint = { ref=true }
              local origin = cel.position
              app.editor:askPoint{
                title="Change Ref Point",
                point=tile.properties(PK).ref + origin,
                decorate={ rulers=true, dimmed=true },
                onclick=function(ev)
                  activeAskPoint = nil
                  app.transaction("Change Ref Point", function()
                    tile.properties(PK).ref = ev.point - origin
                  end)
                end,
                oncancel=function(ev)
                  activeAskPoint = nil
                end
              }
            end
          end
          imi.widget.oncontextmenu = function()
            show_ref_context_menu(tile)
          end
        end
        if tile.properties(PK).anchors then
          local anchors = tile.properties(PK).anchors
          for i=1,#anchors do
            local layerId = anchors[i].layerId
            local child = find_layer_by_id(spr.layers, layerId)
            if child then
              imi.pushID(layerId)
              if imi.button("> " .. child.name) then
                if activeAskPoint and activeAskPoint.anchor == layerId then
                  app.editor:cancel()
                  activeAskPoint = nil
                else
                  activeAskPoint = { anchor=layerId }
                  local origin = cel.position
                  app.editor:askPoint{
                    title="Change Anchor Point for Layer " .. child.name,
                    point=anchors[i].position + origin,
                    decorate={ rulers=true, dimmed=true },
                    onclick=function(ev)
                      activeAskPoint = nil
                      app.transaction("Change Anchor Point", function()
                        anchors[i].position = ev.point - origin
                        tile.properties(PK).anchors = anchors
                      end)
                    end,
                    oncancel=function(ev)
                      activeAskPoint = nil
                    end
                  }
                end
              end
              imi.widget.oncontextmenu = function()
                show_anchor_context_menu(layerId, tile, i)
              end
              imi.popID()
            end
          end
        end
        if showGuessPartsButton then
          imi.alignFunc = function(cursor, size, lastBounds)
            return Point(cursor.x, cursor.y + 8*imi.uiScale)
          end
          if imi.button("Guess Parts") then
            insert_guessed_parts(activeTilemap.properties(PK).id, ti)
            showGuessPartsButton = false
            usage.calculateHistogram(activeTilemap)
            imi.repaint()
          end
          imi.alignFunc = nil
        end
        imi.endGroup()

        -- Context menu for active tile
        imi.widget = imageWidget
        imi.widget.oncontextmenu = function()
          show_tile_context_menu(ts, ti, activeTilemap.properties(PK).folders)
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

      folderWidgets.clear()
      local forceBreak = false
      for i,folder in ipairs(folders) do
        imi.pushID(i .. folder.name)
        imi.sameLine = true
        imi.breakLines = true

        imi.beginGroup()
        imi.sameLine = false
        local openFolder = imi.toggle(folder.name, db.isBaseSetFolder(folder))
        if imi.beginDrag() then
          imi.setDragData("folder", { index=i, folder=folder.name })
        elseif imi.beginDrop() then
          local data = imi.popDropData("folder")
          if data then
            handle_drop_folder(folders, data, i)
            imi.repaint()
          end
          imi.endDrop()
        end

        -- Context menu for active folder
        imi.widget.oncontextmenu  = function()
          show_folder_context_menu(folders, folder)
        end

        if openFolder then
          -- One viewport for each opened folder
          imi.beginViewport(Size(imi.viewport.width,
                                 outSize.height),
                            outSize)
          folderWidgets.add(imi.widget, folder)

          -- If we are not resizing the viewport, we restore the
          -- viewport size stored in the folder
          if folder.viewport and not imi.widget.draggingResize then
            imi.widget.resizedViewport = folder.viewport
          end

          imi.widget.onviewportresized = function(size)
            app.transaction("Resize Folder", function()
              folder.viewport = Size(size.width, size.height)
              activeTilemap.properties(PK).folders = folders
              imi.repaint()
            end)
          end

          if imi.beginDrop() then
            -- We need to pop the tile data to avoid that dropping a folder toggle into
            -- a folder viewport creates the latest tile stored with setDragData.
            local data = imi.popDropData("tile")
            if data and imi.highlightDropItemPos then
              handle_drop_item_in_folder(folders,
                                         data.folder, data.index, data.ti,
                                         folder, imi.highlightDropItemPos)
              imi.repaint()
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
                             index, activeTilemap.tileset,
                             ti, inRc, outSize, itemPos)

            if imi.beginDrag() then
              imi.setDragData("tile", { index=index, ti=ti, folder=folder.name })
            elseif imi.beginDrop() then
              -- We need to pop the tile data to avoid that dropping a folder toggle into
              -- a tile image replaces it with the latest tile stored with setDragData.
              local data = imi.popDropData("tile")
              if data and imi.highlightDropItemPos then
                handle_drop_item_in_folder(folders,
                                           data.folder, data.index, data.ti,
                                           folder, imi.highlightDropItemPos)
                imi.repaint()
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

  if activeTilemap then
    usage.calculateHistogram(activeTilemap)
    local tileImg = get_active_tile_image()
    if tileImg and
       (not activeTileImageInfo or
        tileImg.id ~= activeTileImageInfo.id or
        (tileImg.id == activeTileImageInfo.id and
         tileImg.version > activeTileImageInfo.version)) then
      activeTileImageInfo = { id=tileImg.id,
                              version=tileImg.version }
      calculate_shrunken_bounds(activeTilemap)
      if not imi.isongui then
        repaint = true
      end
    else
      activeTileImageInfo = {}
    end
  end

  editAttachment.onSpriteChange()

  if repaint then
    imi.repaint()
  end
end

local function Sprite_afteraddtile(ev)
  local layer = ev.layer
  local folders = layer.properties(PK).folders
  local folder = db.getBaseSetFolder(layer, folders)
  local ti = ev.tileIndex

  local pos = find_empty_spot_position(folder)
  table.insert(folder.items, { tile=ti, position=find_empty_spot_position(folder) })

  -- We are inside a transaction in this event, so this property
  -- change will be included in the undoable transaction.
  layer.properties(PK).folders = folders

  if ev.layer == activeTilemap then
    calculate_shrunken_bounds(activeTilemap)
  end

  for_each_category_tileset(function(ts)
    if ts ~= layer.tileset then
      app.sprite:newTile(ts)
    end
  end)

  imi.repaint()
end

local function focus_active_attachment()
  local folders = activeTilemap.properties(PK).folders
  if not folders then
    return false
  end

  local folder = db.getBaseSetFolder(activeTilemap, folders)
  if not folder or not folder.items or #folder.items < 1 then
    return false
  end

  local index = 1
  local cel = app.activeCel
  if cel then
    local ti = tileI(cel.image:getPixel(0, 0))
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
function main.moveFocusedItem(delta)
  if not activeTilemap then
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

  local _, folder = get_active_folder()
  if folder then
    local focusedFolderWidget = folderWidgets.find(folder)
    local positionBounds = get_folder_position_bounds(folder)
    local position = Point(focusedItem.position)

    local newFolderWidget = nil
    local newItem
    -- Navigate to the next item
    while positionBounds:contains(position) do
      position = position + delta

      -- Determine if we have to move focus to another folder, and
      -- which item must be selected.
      if position.x < 0 then
        newFolderWidget, newItem = folderWidgets.findClosestFolder(focusedFolderWidget, focusedItem.position, "left")
      end
      if position.y < 0 then
        newFolderWidget, newItem = folderWidgets.findClosestFolder(focusedFolderWidget, focusedItem.position, "up")
      end
      if position.x >= positionBounds.width then
        newFolderWidget, newItem = folderWidgets.findClosestFolder(focusedFolderWidget, focusedItem.position, "right")
      end
      if position.y >= positionBounds.height then
        newFolderWidget, newItem = folderWidgets.findClosestFolder(focusedFolderWidget, focusedItem.position, "down")
      end

      -- If we are changing the focus to another folder, set it
      -- as the active one.
      if newFolderWidget then
        folder = newFolderWidget.folder
      else
        -- Active folder didn't change, just find the new focused
        -- item in it.
        newItem = get_folder_item_index_by_position(folder, position)
      end

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

        -- Make "position" of new focused folder containing "newItem"
        -- visible in its parent viewport.
        if newFolderWidget and
           newFolderWidget.parent and
           newFolderWidget.parent.scrollPos then
          local parentViewport = newFolderWidget.parent
          local scrollPos = Point(parentViewport.scrollPos)
          local viewportPos = newFolderWidget.bounds.origin
          local viewportSize = newFolderWidget.bounds.size
          if viewportPos.y < parentViewport.bounds.origin.y then
            scrollPos.y = viewportPos.y + scrollPos.y - parentViewport.bounds.origin.y
          end
          if viewportPos.y > parentViewport.bounds.origin.y + parentViewport.bounds.size.height - viewportSize.height then
            scrollPos.y = viewportPos.y + scrollPos.y - (parentViewport.bounds.origin.y + parentViewport.bounds.size.height - viewportSize.height)
          end
          parentViewport.setScrollPos(scrollPos)
        end

        focusFolderItem = { folder=folder.name, index=newItem }
        imi.repaint()
        break
      end
    end
  end
end

function main.selectFocusedAttachment()
  -- Select the new tile pressing Enter key
  if focusedItem then
    set_active_tile(focusedItem.tile)
  end
end

local function canvas_onkeydown(ev)
  if not pref.captureArrowKeys or
     not activeTilemap or
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
    main.selectFocusedAttachment()
    ev.stopPropagation()
    imi.repaint()
  elseif ev.code == "Escape" then
    imi.focusedWidget.focused = false
    imi.focusedWidget = nil
    imi.repaint()
  end

  if delta then
    -- Don't send key to Aseprite as we've just used it
    ev.stopPropagation()
    main.moveFocusedItem(delta)
  end
end

local function canvas_onmousedown(ev)
  if ev.ctrlKey and ev.button == MouseButton.MIDDLE then
    pref.setZoom(1.0)
    imi.repaint()
    return
  end
  return imi.onmousedown(ev)
end

local function canvas_onwheel(ev)
  if ev.ctrlKey then
    if ev.shiftKey then
      pref.setZoom(pref.zoom - ev.deltaY/2.0)
    else
      pref.setZoom(pref.zoom - ev.deltaY/32.0)
    end
    imi.repaint()
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
        imi.repaint()
        break
      end
    end
  end
end

local function canvas_ontouchmagnify(ev)
  pref.setZoom(pref.zoom + pref.zoom*ev.magnification)
  imi.repaint()
end

local function unobserve_sprite()
  if observedSprite then
    observedSprite.events:off(Sprite_change)
    observedSprite.events:off(Sprite_afteraddtile)
    observedSprite = nil
  end
end

local function observe_sprite(spr)
  unobserve_sprite()
  observedSprite = spr
  if observedSprite then
    observedSprite.events:on('change', Sprite_change)
    if app.apiVersion >= 25 then
      observedSprite.events:on('afteraddtile', Sprite_afteraddtile)
    end
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
  if activeTilemap ~= lay then
    activeTilemap = lay
    if activeTilemap then
      assert(activeTilemap.isTilemap)
      calculate_shrunken_bounds(activeTilemap)
      usage.calculateHistogram(activeTilemap)
    else
      shrunkenBounds = Rectangle()
    end

    -- Unfocus items as we've changed the active layer
    focusedItem = nil
    focusFolderItem = nil
    if imi.focusedWidget then
      imi.focusedWidget.focused = false
      imi.focusedWidget = nil
    end
  end

  activeTileImageInfo = {}
  if ev.fromUndo then
    return
  end

  local tileImg = get_active_tile_image()
  if tileImg then
    activeTileImageInfo = { id=tileImg.id,
                            version=tileImg.version }
  end

  -- Cancel any "select point" state, or any extra UI button
  main.cancelJoint()
  showGuessPartsButton = false

  if not imi.isongui and not ev.fromUndo then
    imi.repaint() -- TODO repaint only when it's needed
  end
end

local function App_beforecommand(ev)
  if ev.name == "MaskContent" and
     app.sprite and
     activeTilemap then

    app.transaction("Select Content", function()
      local tileImg = get_active_tile_image()
      if tileImg then
        local shrinkBounds = get_shrunken_bounds_of_image(tileImg)
        local sel = Selection(shrinkBounds)
        sel.origin = sel.origin + app.cel.position
        app.sprite.selection = sel
        app.refresh()
      end
    end)
    ev.stopPropagation()

  elseif ev.name == "Flip" and
     ev.params.target == "mask" and
     app.sprite and
     app.sprite.selection.isEmpty and
     (activeTilemap or
      (not app.range.isEmpty and app.sprite.tileManagementPlugin == PK)) then

    local flipType
    if ev.params.orientation == "vertical" then
      flipType = FlipType.VERTICAL
    else
      flipType = FlipType.HORIZONTAL
    end

    if app.range.isEmpty then
      flip_active_attachment(flipType)
    else
      flip_range(flipType)
    end
    ev.stopPropagation()

  elseif ev.name == "ChangeBrush" and
    (ev.params.change == "flip-x" or
     ev.params.change == "flip-y") and
    activeTilemap then

    local used
    if ev.params.change == "flip-x" then
      used = flip_active_tile_flags("Flip H", app.pixelColor.TILE_XFLIP)
    else
      used = flip_active_tile_flags("Flip V", app.pixelColor.TILE_YFLIP)
    end
    if used then
      ev.stopPropagation()
    end
  end
end

-- Deprecated: used only if app.apiVersion < 25
local function App_beforepaintemptytilemap()
  if activeTilemap then
    app.transaction("Set New Attachment", function()
      local ti = main.newEmptyAttachment()
      if ti ~= nil then
        set_active_tile(ti)
      end
    end)
  end
end

local function dialog_onclose()
  unobserve_sprite()
  app.events:off(App_sitechange)
  app.events:off(App_beforecommand)
  app.events:off(App_beforepaintemptytilemap)
  dlg = nil
end

function main.findNextAttachmentUsage()
  local ti = get_active_tile_index()
  if ti then
    local newActiveCel = usage.findNext(activeTilemap, app.frame.frameNumber, ti)
    if newActiveCel then
      app.cel = newActiveCel
    end
  end
end

function main.findPrevAttachmentUsage()
  local ti = get_active_tile_index()
  if ti then
    local newActiveCel = usage.findPrev(activeTilemap, app.frame.frameNumber, ti)
    if newActiveCel then
      app.cel = newActiveCel
    end
  end
end

function main.startSelectingJoint()
  if not dlg then
    main.openDialog()
  end

  -- Get possible point to insert the joint, first the mouse position
  -- in sprite coordinates, then we check if the active
  -- attachment/parent already have an anchor point for the active
  -- layer.
  local point = app.editor.spritePos
  if activeTilemap then
    local layer = activeTilemap
    local layerId = layer.properties(PK).id
    local attachments = get_possible_attachments(point)
    local anchorPoint = nil
    for i=1,#attachments do
      if attachments[i] ~= layer then
        -- Get base tileset to get anchor points
        local ts = db.getBaseTileset(attachments[i])
        local ti = get_active_tile_index(attachments[i])
        anchorPoint = get_anchor_point_for_layer(ts, ti, layerId)
        if anchorPoint then
          point = anchorPoint
          break
        elseif app.cel then
          local ts = db.getBaseTileset(layer)
          local ti = get_active_tile_index(layer)
          if ts:tile(ti).properties(PK).ref then
            point = ts:tile(ti).properties(PK).ref
              + app.cel.position
          end
        end
      end
    end
  end

  windowState = WindowState.SELECT_JOINT_POINT
  possibleJoint = point
  imi.repaint()

  return point
end

function main.setPossibleJoint(point)
  possibleJoint = Point(point)
  imi.repaint()
end

function main.cancelJoint()
  if app.editor then
    app.editor:cancel()
  end
  windowState = WindowState.NORMAL
  possibleJoint = nil
  activeAskPoint = nil
  imi.repaint()
end

function main.hasDialog()
  return (dlg ~= nil)
end

function main.closeDialog()
  if dlg then
    dlg:close()
  end
end

function main.openDialog()
  assert(dlg == nil)
  dlg = Dialog{
    title=title,
    onclose=dialog_onclose
  }
  :canvas{ id="canvas",
           width=400*imi.uiScale, height=300*imi.uiScale,
           autoScaling=false,
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
  if app.apiVersion >= 24 then
    app.events:on('beforecommand', App_beforecommand)
    if app.apiVersion < 25 then
      app.events:on('beforepaintemptytilemap', App_beforepaintemptytilemap)
    end
  end
  observe_sprite(app.activeSprite)
end

function folderWidgets.add(widget, folder)
  widget.folder = folder

  -- Returns the index of the closest item inside this folderWidget respect to the itemPos inside the folderWidget
  -- specified as a parameter. Also returns the distance between them.
  widget.findClosestItemIndex = function (folderWidget, itemPos)
    local p1 = folderWidget.bounds.origin - folderWidget.scrollPos + Point(itemPos.x * shrunkenSize.width, itemPos.y * shrunkenSize.height)
    local d = 99999
    local closestItemIndex = 0
    for i, item in ipairs(widget.folder.items) do
      local p2 = widget.bounds.origin - widget.scrollPos + Point(item.position.x * shrunkenSize.width, item.position.y * shrunkenSize.height)
      -- Distance vector.
      local dv = p1 - p2
      -- Calculate Manhattan distance, since it is easier than euclidean and for our purposes it is the same.
      local newd = math.abs(dv.x) + math.abs(dv.y)
      if newd < d then
        d = newd
        closestItemIndex = i
      end
    end
    return closestItemIndex, d
  end

  table.insert(folderWidgets, widget)
end

function folderWidgets.clear()
  for i=1, #folderWidgets do
    folderWidgets[i] = nil
  end
end

-- Returns the "folder widget" (viewport) representing the specified folder. Or
-- nil if there is no widget for the folder.
function folderWidgets.find(folder)
  for _,widget in ipairs(folderWidgets) do
    if widget.folder.name == folder.name then
      return widget
    end
  end
  return nil
end

function folderWidgets.findClosestFolder(folderWidget, itemPosition, side)
  local folderOnSide = {
    up = function(f)
      return folderWidget.bounds.origin.y > f.bounds.origin.y
    end,
    left = function(f)
      return folderWidget.bounds.origin.x > f.bounds.origin.x and folderWidget.bounds.origin.y == f.bounds.origin.y
    end,
    down = function(f)
      return folderWidget.bounds.origin.y < f.bounds.origin.y
    end,
    right = function(f)
      return folderWidget.bounds.origin.x < f.bounds.origin.x and folderWidget.bounds.origin.y == f.bounds.origin.y
    end
  }

  local d = 99999
  local closestFolderWidget = nil
  local closestItemIndex
  for i=1,#folderWidgets do
    -- Skip folder if it is the folder passed as a parameter
    if folderWidgets[i] == folderWidget then
      goto continue
    end

    if folderOnSide[side](folderWidgets[i]) then
      local cii, newd = folderWidgets[i].findClosestItemIndex(folderWidget, itemPosition)
      if cii and newd < d then
        d = newd
        closestFolderWidget = folderWidgets[i]
        closestItemIndex = cii
      end
    end

    ::continue::
  end

  if closestFolderWidget then
    return closestFolderWidget, closestItemIndex
  end
end

return main
