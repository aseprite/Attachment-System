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
-- Tileset = {             -- A tileset represents a category for one layer
--   id = categoryID       -- Tileset/category ID, referenced by layers that can use this category/tileset
-- }
--
-- Layer = {
--   categories={ categoryID1, categoryID2, etc. },
--   folders={
--     { name="Folder Name",
--       items={ tileIndex1, tileIndex2, ... } }
--   },
-- }
--
-- Tile = {
--   pivot=Point(0, 0),
-- }
----------------------------------------------------------------------

local imi = dofile('./imi.lua')

-- Plugin-key to access extension properties in layers/tiles/etc.
-- E.g. layer.properties(PK)
local PK = "aseprite/Attachment-System"

local kBaseSetName = "Base Set"

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

local function contains(t, item)
  for _,v in pairs(t) do
    if v == item then
      return true
    end
  end
  return false
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
  for _,tileset in ipairs(spr.tilesets) do
    if tileset.properties(PK).id then
      maxId = math.max(maxId, tileset.properties(PK).id)
      end
  end
  return maxId+1
end

local function find_tileset_by_categoryID(spr, categoryID)
  for _,tileset in ipairs(spr.tilesets) do
    if tileset.properties(PK).id == categoryID then
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
  local result = (folder.name == kBaseSetName)
  return result
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
  for _,tileset in ipairs(spr.tilesets) do
    tileset.properties(PK).id = calculate_new_category_id(spr)
  end
  setup_layers(spr.layers)
end

local function show_tile_context_menu(ts, ti, folders, folder, indexInFolder)
  -- TODO Probably we need a new Menu() widget
  local popup = Dialog{ title="Tile", parent=imi.dlg }
  local spr = activeLayer.sprite

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
    app.transaction(
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
    app.transaction(
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
    activeLayer.properties(PK).folders = folders
    popup:close()
  end

  popup:menuItem{ text="New Empty", onclick=newEmpty }:newrow()
  popup:menuItem{ text="Duplicate", onclick=duplicate }:newrow()
  if folder and not is_base_set_folder(folder) then
    popup:separator()
    popup:menuItem{ text="Delete", onclick=delete }
  end
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
  imi.widget = imageWidget
end

local function new_category_dialog()
  local popup =
    Dialog{ title="New Category Name", parent=imi.dlg }
    :entry{ id="name", label="Name:", focus=true }
    :button{ id="ok", text="OK", focus=true }
    :button{ id="cancel", text="Cancel" }
  popup:show()
  local data = popup.data
  if data.ok and data.name ~= "" then
    -- TODO check that the name doesn't exist
    local spr = activeLayer.sprite
    local id = calculate_new_category_id(spr)
    app.transaction(function()
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

local function show_categories_selector(categories, activeTileset)
  local spr = app.activeSprite
  local popup = Dialog{ parent=imi.dlg }
  if categories and #categories > 0 then
    for i,categoryID in ipairs(categories) do
      local catTileset = find_tileset_by_categoryID(spr, categoryID)
      if catTileset == nil then assert(false) end

      local checked = (categoryID == activeTileset.properties(PK).id)
      local name = catTileset.name
      if name == "" then name = "Base Category" end
      popup:menuItem{ text=name, focus=checked,
                      onclick=function()
                        popup:close()
                        activeLayer.tileset = find_tileset_by_categoryID(spr, categoryID)
                        app.refresh()
                      end }:newrow()
    end
    popup:separator()
  end
  popup:menuItem{ text="New Category",
                  onclick=function()
                    popup:close()
                    new_category_dialog()
                    imi.repaint = true
                  end }
  popup:showMenu()
end

local function new_folder_dialog()
  local popup =
    Dialog{ title="New Folder Name", parent=dlg }
    :entry{ id="name", label="Name:", focus=true }
    :button{ id="ok", text="OK", focus=true }
    :button{ id="cancel", text="Cancel" }
  popup:show()
  local data = popup.data
  if data.ok and data.name ~= "" then
    return {
      name=data.name,
      items={ },
    }
  else
    return nil
  end
end

local function show_folders_selector(folders)
  local popup = Dialog{ parent=imi.dlg }
  if folders and #folders > 0 then
    for i,folder in ipairs(folders) do
      local name = folder.name
      -- TODO should we convert empty folder name to base set (?)
      if name == "" then name = kBaseSetName end
      popup:entry{ id=tostring(i), text=name }:newrow()
    end
    popup:separator()
    popup:menuItem{ id="rename", text="Rename Folders", focus=true }
  end
  popup:showMenu()

  local data = popup.data
  if data.rename then
    local somethingRenamed = false
    for i,folder in ipairs(folders) do
      if folder.name ~= data[tostring(i)] then
        folder.name = data[tostring(i)]
        somethingRenamed = true
      end
    end
    if somethingRenamed then
      for i=#folders,1,-1 do
        if folders[i].name == "" then
          table.remove(folders, i)
        end
      end
      activeLayer.properties(PK).folders = folders
    end
    imi.repaint = true
  end
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
      app.transaction(function() setup_sprite(spr) end)
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
      local activeCategory = activeTileset.name
      if activeCategory == "" then
        activeCategory = "Base Category"
      end
      if imi.button(activeCategory) then
        -- Show popup to select other category
        imi.afterGui(
          function()
            show_categories_selector(categories, activeTileset)
          end)
      end

      imi.margin = 0
      if imi.button("Folders") then
        imi.afterGui(
          function()
            show_folders_selector(folders)
          end)
      end
      imi.margin = 4*imi.uiScale
      if imi.button("+") then
        imi.afterGui(
          function()
            local folder = new_folder_dialog()
            if folder then
              table.insert(folders, folder)
              activeLayer.properties(PK).folders = folders
            end
            imi.repaint = true
          end)
      end

      imi.space(2*imi.uiScale)
      if imi.button("Options") then
        imi.afterGui(
          function()
            show_options()
          end)
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
      imi.viewport = Rectangle(imi.cursor.x, imi.cursor.y,
                               imi.viewport.width - imi.cursor.x,
                               imi.viewport.height - imi.cursor.y)

      for i,folder in ipairs(folders) do
        imi.pushID(i .. folder.name)
        imi.sameLine = false
        imi.breakLines = true

        local openFolder = imi.toggle(folder.name)


        if openFolder then
          -- One viewport for each opened folder
          local outSize2 = Size(outSize.width*3/4, outSize.height*3/4)
          imi.beginViewport(Size(imi.viewport.width,
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
              activeLayer.properties(PK).folders = folders
              imi.repaint = true
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
        imi.popID()
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
