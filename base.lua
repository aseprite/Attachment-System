-- Aseprite Attachment System
-- Copyright (c) 2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

local base = {}

function base.clamp(value, min, max)
  if value == nil then value = min end
  return math.max(min, math.min(value, max))
end

return base
