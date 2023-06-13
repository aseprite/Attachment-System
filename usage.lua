-- Aseprite Attachment System
-- Copyright (c) 2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

local usage = {}
local tilesFreq = {} -- How many times each tile is used in the active layer

function usage.isUsedTile(ti)
  return tilesFreq[ti] and tilesFreq[ti] >= 1
end

function usage.isUnusedTile(ti)
  return tilesFreq[ti] == nil
end

function usage.getTileFreq(ti)
  return tilesFreq[ti]
end

function usage.calculateHistogram(layer)
  assert(layer)
  assert(layer.isTilemap)
  tilesFreq = {}
  for _,cel in ipairs(layer.cels) do
    local ti = cel.image:getPixel(0, 0)
    if tilesFreq[ti] == nil then
      tilesFreq[ti] = 1
    else
      tilesFreq[ti] = tilesFreq[ti] + 1
    end
  end
end

-- Returns the next (or previous) cel in the given layer where the
-- attachment "ti" is used/found. "istep" parameter can be +1 or -1
-- depending on if you want to go forward or backward.
local function find_next_cel_templ(layer, iniFrame, ti, istep)
  local prevMatch = nil
  local istart, iend
  local isPrevious

  if istep < 0 then
    istart, iend = #layer.cels, 1
    isPrevious = function(f) return f >= iniFrame end
  else
    istart, iend = 1, #layer.cels
    isPrevious = function(f) return f <= iniFrame end
  end

  local cels = layer.cels
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
          return cel
        end
      end
    end
  end
  if prevMatch then
    return prevMatch
  else
    return layer:cel(iniFrame)
  end
end

function usage.findNext(layer, frame, ti)
  return find_next_cel_templ(layer, frame, ti, 1)
end

function usage.findPrev(layer, frame, ti)
  return find_next_cel_templ(layer, frame, ti, -1)
end

return usage
