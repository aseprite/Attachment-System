-- Aseprite Attachment System
-- Copyright (c) 2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

local base = require 'base'

local pref = {
  -- Plugin preferences
  showTilesID = false,
  showTilesUsage = false,
  showUnusedTilesSemitransparent = true,
  zoom = 1.0,
}

function pref.setZoom(z)
  pref.zoom = base.clamp(z, 0.5, 10.0)
end

function pref.load(plugin)
  pref.showTilesID = plugin.preferences.showTilesID
  pref.showTilesUsage = plugin.preferences.showTilesUsage
  pref.setZoom(plugin.preferences.zoom)
end

function pref.save(plugin)
  plugin.preferences.showTilesID = pref.showTilesID
  plugin.preferences.showTilesUsage = pref.showTilesUsage
  plugin.preferences.zoom = pref.zoom
end

return pref
