-- Aseprite Attachment System
-- Copyright (c) 2022  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

-- The main window/dialog
local dlg
local title = "Attachment Window"
local observedSprite

local function Sprite_change()
  -- TODO
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

-- When the active site (active sprite, cel, frame, etc.) changes this
-- function will be called.
local function App_sitechange(ev)
  local newSpr = app.activeSprite
  if newSpr ~= observedSprite then
    observe_sprite(newSpr)
    dlg:repaint()
  end
end

local function Canvas_onpaint(ev)
  local ctx = ev.context
  local spr = app.activeSprite
  if not spr then
    dlg:modify{ title=title }
    ctx:fillText("No sprite", 0, 0)
  else
    dlg:modify{ title=title .. " - " .. app.fs.fileTitle(spr.filename) }
    ctx:fillText("Sprite: " .. spr.filename, 0, 0)
    return
  end
end

local function Canvas_onmousemove(ev)
  -- TODO
end

local function Canvas_onmousedown(ev)
  -- TODO
end

local function Canvas_onmouseup(ev)
  -- TODO
end

local function AttachmentWindow_SwitchWindow()
  if dlg then
    unobserve_sprite()
    app.events:off(App_sitechange)
    dlg:close()
    dlg = nil
  else
    dlg = Dialog(title)
      :canvas{ width=400, height=300,
               onpaint=Canvas_onpaint,
               onmousemove=Canvas_onmousemove,
               onmousedown=Canvas_onmousedown,
               onmouseup=Canvas_onmouseup }
    dlg:show{ wait=false }

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
end
