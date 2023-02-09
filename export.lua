-- Aseprite Attachment System
-- Copyright (c) 2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.
--
-- You can just use this from the CLI as:
--
--   aseprite -b sprite.aseprite -script export.lua
--
-- Which will generate the sprite.png and sprite.json files in the
-- same folder where sprite.aseprite is located.
--
-- Or
--
--   aseprite -b sprite.aseprite \
--            -script-param sheet=output.png \
--            -script-param data=output.json \
--            -script export.lua
--
-- To indicate explicitly the output files.

local spr = app.activeSprite
if not spr then return print "No active sprite" end

-- Modules
local db = dofile('./db.lua')
local fs = app.fs

-- Constants
local PK = db.PK

-- Output file names, can be specified with:
-- -script-param sheet=filename.png
-- -script-param data=filename.json
local outputSheetFn
if app.params.sheet then
  outputSheetFn = app.params.sheet
else
  outputSheetFn = fs.filePathAndTitle(spr.filename) .. ".png"
end

local outputDataFn
if app.params.data then
  outputDataFn = app.params.data
else
  outputDataFn = fs.filePathAndTitle(spr.filename) .. ".json"
end

local function for_layers(layers, f)
  for i=1,#layers do
    local layer = layers[i]
    f(layer)
    if layer.isGroup then
      for_layers(layer.layers)
    end
  end
end

-- Assign "attachment" in the layer user data (this might be enough to
-- identify the kind of layer from the JSON file)
for_layers(spr.layers, function(layer)
  local layerType
  if layer.isTilemap then
    layer.data = "attachment"
  end
end)

-- Duplicate each tilemap for each category
local tilemaps = {}
for_layers(spr.layers, function(layer)
  if layer.isTilemap then
    table.insert(tilemaps, layer)
  end
end)

for _,layer in ipairs(tilemaps) do
  app.activeLayer = layer

  local name = layer.name

  local categories = layer.properties(PK).categories
  if categories and #categories then
    for i=1,#categories do
      local ts = db.findTilesetByCategoryID(spr, categories[i])
      layer.name = name .. '/' .. ts.name
      layer.tileset = ts
      if i < #categories then
        app.command.DuplicateLayer()
        layer = app.activeLayer
      end
    end
  end
end

app.command.ExportSpriteSheet{
  ui=false,
  type=SpriteSheetType.PACKED,
  textureFilename=outputSheetFn,
  dataFilename=outputDataFn,
  dataFormat=SpriteSheetDataFormat.JSON_ARRAY,
  filenameFormat="{title} ({layer}) {frame}.{extension}",
  splitLayers=true,
  mergeDuplicates=true,
  trim=true,
  listLayers=true,
}
