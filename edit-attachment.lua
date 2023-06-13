-- Aseprite Attachment System
-- Copyright (c) 2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

local imi = require 'imi'
local db = require 'db'
local usage = require 'usage'
local editAttachment = {}

-- Constants
local PK = db.PK

--- Original layer/frame where we start editing attachments
local originalLayer
local originalFrame

-- Callback after we restore the original sprite
local afterEditingCallback

-- Array of bool elements to detect changes on the tempSprite cels,
-- used on Sprite_change(). Helps to save only the changes, it improves
-- performance and the undo process
local changeDetectionOnCels

-- Temporal sprite/layer to edit attachments
local tempSprite
local editAttachmentLayer
local attachmentOriginalPositions

local function restore_original()
  if tempSprite ~= nil then
    tempSprite:close()
    tempSprite = nil
  end

  changeDetectionOnCels = nil
  editAttachmentLayer = nil

  app.sprite = originalLayer.sprite
  app.layer = originalLayer
  app.frame = originalFrame
  originalLayer = nil

  if afterEditingCallback then
    afterEditingCallback()
    afterEditingCallback = nil
  end
end

function editAttachment.isEditing(sprite)
  return (originalLayer ~= nil and
          originalLayer.sprite == sprite or
          tempSprite == sprite)
end

function editAttachment.acceptChanges()
  if not originalLayer then return end

  local ts = originalLayer.tileset
  local tileSize = ts.grid.tileSize

  -- Restore original sprite and start a transaction to apply all
  -- attachment changes.
  app.sprite = originalLayer.sprite
  if tempSprite ~= nil then
    local changes = changeDetectionOnCels
    changeDetectionOnCels = nil

    app.transaction("Edit Attachments", function()
      for i=1,#tempSprite.frames do
        if changes[i] and editAttachmentLayer:cel(i) then
          local celImage = editAttachmentLayer:cel(i).image
          if not celImage:isEmpty() then
            local image = Image(ts:tile(i).image.spec)
            local pos = editAttachmentLayer:cel(i).position - attachmentOriginalPositions[i]
            image:drawImage(celImage, pos)
            ts:tile(i).image = image
          end
        end
      end
    end)
  end

  restore_original()
end

function editAttachment.cancelChanges()
  restore_original()
end

function editAttachment.startEditing(ti, afterEditing)
  if not app.layer or not app.layer.isTilemap then
    return
  end

  -- Close/cancel a previous editing state
  if tempSprite ~= nil then
    tempSprite:close()
    tempSprite = nil
  end

  originalLayer = app.layer
  originalFrame = app.frame.frameNumber
  afterEditingCallback = afterEditing

  local spr = app.sprite
  local ts = originalLayer.tileset
  local refTileset = db.getBaseTileset(originalLayer)
  local tileSize = refTileset.grid.tileSize
  local defaultAnchorSample = 1

  tempSprite = Sprite(spr.width, spr.height, spr.colorMode)
  app.transaction("Start Attachment Edition", function()
    local palette = spr.palettes[1]
    tempSprite.palettes[1]:resize(#palette)
    for i=0,#palette-1 do
      tempSprite.palettes[1]:setColor(i, palette:getColor(i))
    end
    for i=1,#ts-2 do
      tempSprite:newEmptyFrame()
    end

    local tilePosOnTempSprite = Point((tempSprite.width - tileSize.width)/2,
      (tempSprite.height - tileSize.height)/2)

    -- Add faded parent tiles layer for reference
    local parentLayer = db.findParentLayer(spr.layers, originalLayer)
    if parentLayer then
      local defaultParentAnchor = db.findAnchorOnLayer(parentLayer, originalLayer, defaultAnchorSample)
      assert(defaultParentAnchor)
      local parentLayerOnTempSprite = tempSprite.layers[1]
      parentLayerOnTempSprite.name = parentLayer.name
      for i=1,#ts-1 do
        app.sprite = spr
        app.frame = originalFrame
        app.layer = originalLayer

        local parentAnchorPos
        local parentImageIndex
        if not usage.isUnusedTile(i) then
          -- Find next usage of the active tile
          app.cel = usage.findNext(app.layer, app.frame.frameNumber, i)

          if parentLayer:cel(app.frame.frameNumber) then
            parentImageIndex = parentLayer:cel(app.frame.frameNumber).image:getPixel(0, 0)
            local parentAnchor = db.findAnchorOnLayer(parentLayer, originalLayer, parentImageIndex)
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
      app.sprite = tempSprite
      app.command.LayerOpacity {
        opacity = 128
      }
      app.layer.isEditable = false
    end

    -- Add Attachment editing layer
    if parentLayer then
      editAttachmentLayer = tempSprite:newLayer()
    else
      -- Recycle first layer if no parent found
      editAttachmentLayer = tempSprite.layers[1]
    end
    editAttachmentLayer.name = originalLayer.name

    -- Fill the attachment editing layer with one cel/image per tile
    attachmentOriginalPositions = {}
    for i=1,#tempSprite.frames do
      tempSprite:newCel(editAttachmentLayer,
                        i,
                        ts:tile(i).image,
                        tilePosOnTempSprite)
      table.insert(attachmentOriginalPositions, tilePosOnTempSprite)
    end

    app.layer = editAttachmentLayer
    app.frame = ti

    changeDetectionOnCels = {}
    for i=1,#tempSprite.frames do
      table.insert(changeDetectionOnCels, false)
    end
  end)
end

function editAttachment.onSpriteChange()
  if changeDetectionOnCels and app.layer == editAttachmentLayer then
    changeDetectionOnCels[app.frame.frameNumber] = true
  end
end

return editAttachment
