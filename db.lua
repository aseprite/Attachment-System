-- Aseprite Attachment System
-- Copyright (c) 2022-2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.
----------------------------------------------------------------------
-- Extension Properties:
--
-- Sprite = {
--   version = 3
-- }
--
-- Tileset = {            -- A tileset represents a category for one layer
--   id = categoryID,     -- Tileset/category ID, referenced by layers that can use this category/tileset
-- }
--
-- Layer = {
--   id=layerID,          -- ID for this layer (only for tilemap layers!)
--   categories={ categoryID1, categoryID2, etc. },
--   folders={
--     { name="Folder Name",
--       items={ { tile=tileIndex1, position=Point(column, row) }, ... },
--       viewport=Size(columns, rows) }
--   },
-- }
--
-- Tile = {
--   ref=Point(x, y), -- this reference point is present only in the categoryID1 tileset
--   anchors={
--     { layerId=layerID,
--       position=Point(x1, y1)},
--   }
-- }
----------------------------------------------------------------------

local db = {
  -- Plugin-key to access extension properties ("the DB") in
  -- layers/tiles/etc.  E.g. layer.properties(PK)
  PK = "aseprite/Attachment-System",

  -- Version of the database (DB)
  kLatestDBVersion = 3,
  kBaseSetName = "Base Set",
}

local PK = db.PK

local function contains(t, item)
  for _,v in pairs(t) do
    if v == item then
      return true
    end
  end
  return false
end

local function createBaseSetFolder(layer)
  local items = {}
  for ti=1,#layer.tileset-1 do
    table.insert(items, { tile=ti, position=Point(ti-1, 0) })
  end
  return { name=db.kBaseSetName, items=items }
end

-- Update layer folders from version=1 to version=2 Before this
-- folders have an array of tile indexes, and now is a tile of objects
-- (each object with a "tile" field, then a "position" is optional and
-- created only when we drop).
local function updateFoldersFromIndexesToObjects(folders)
  for i=1,#folders do
    local folder = folders[i]
    for j=1,#folder.items do
      folder.items[j] = { tile=folder.items[j], position=Point(j-1, 0) }
    end
    folders[i] = folder
  end
  return folders
end

local function setupLayers(spr, currentVersion, layers)
  for _,layer in ipairs(layers) do
    if layer.isTilemap then
      -- Add ID to the layer (this was added in DB version=2)
      if not layer.properties(PK).id then
        layer.properties(PK).id = db.calculateNewLayerID(spr)
      end

      local categories = layer.properties(PK).categories
      local folders = layer.properties(PK).folders

      local tilesetID = layer.tileset.properties(PK).id
      assert(tilesetID ~= nil)

      if not categories then
        categories = { }
      end
      if not contains(categories, tilesetID) then
        table.insert(categories, tilesetID)
        layer.properties(PK).categories = categories
      end

      if not folders or #folders == 0 then
        layer.properties(PK).folders = { createBaseSetFolder(layer) }
      elseif currentVersion < 3 then
        -- In version=3 folders items were converted from tile indexes
        -- to objects with {tile,position}
        layer.properties(PK).folders =
          updateFoldersFromIndexesToObjects(layer.properties(PK).folders)
      end
    end
    if layer.isGroup then
      setupLayers(spr, currentVersion, layer.layers)
    end
  end
end

local function calculateMaxLayerIDBetweenLayers(layers)
  local maxId = 0
  for i=1,#layers do
    local layer = layers[i]
    if layer and layer.properties(PK).id then
      maxId = math.max(maxId, layer.properties(PK).id)
    end
    if layer.isGroup then
      maxId = math.max(maxId, calculateMaxLayerIDBetweenLayers(layer.layers))
    end
  end
  return maxId
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function db.calculateNewLayerID(spr)
  return 1+calculateMaxLayerIDBetweenLayers(spr.layers)
end

function db.calculateNewCategoryID(spr)
  local maxId = 0
  for i=1,#spr.tilesets do
    local tileset = spr.tilesets[i]
    if tileset and tileset.properties(PK).id then
      maxId = math.max(maxId, tileset.properties(PK).id)
    end
  end
  return maxId+1
end

function db.findTilesetByCategoryID(spr, categoryID)
  for i=1,#spr.tilesets do
    local ts = spr.tilesets[i]
    if ts and ts.properties(PK).id == categoryID then
      return ts
    end
  end
  return nil
end

function db.isBaseSetFolder(folder)
  return (folder.name == db.kBaseSetName)
end

function db.getBaseSetFolder(layer, folders)
  for _,folder in ipairs(folders) do
    if db.isBaseSetFolder(folder) then
      return folder
    end
  end
  folder = createBaseSetFolder(layer)
  table.insert(folders, folder)
  return folder
end

-- These properties should be set in setupLayers()/setupSprite(), but
-- we can set them here just in case. Anyway if the setup functions
-- don't fully setup the properties, we'll generate undo/redo
-- information just showing the layer in the Attachment System window
function db.getLayerProperties(layer)
  local properties = layer.properties(PK)
  if not properties.id then
    properties.id = db.calculateNewLayerID(layer.sprite)
  end
  if not properties.categories then
    properties.categories = {}
  end
  local id = layer.tileset.properties(PK).id
  if not id then
    id = db.calculateNewCategoryID(layer.sprite)
    layer.tileset.properties(PK).id = id
  end
  if not contains(properties.categories, id) then
    table.insert(properties.categories, id)
  end
  if not properties.folders or #properties.folders == 0 then
    properties.folders = { createBaseSetFolder(layer) }
  end
  return properties
end

function db.setupSprite(spr)
  -- Setup the sprite DB
  local currentVersion = spr.properties(PK).version
  if currentVersion == nil then
    currentVersion = 0
  end

  -- Add ID to each tileset
  for i=1,#spr.tilesets do
    local tileset = spr.tilesets[i]
    if tileset and not tileset.properties(PK).id then
      tileset.properties(PK).id = db.calculateNewCategoryID(spr)
    end
  end

  -- Setup each tilemap layer
  setupLayers(spr, currentVersion, spr.layers)

  -- Latest version in the sprite
  spr.properties(PK).version = db.kLatestDBVersion
end

return db
