-- Aseprite Attachment System
-- Copyright (c) 2022-2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

local imi = require 'imi'
local pref = require 'pref'
local main -- this is given from initVars()
local commands = {}

function commands.initVars(params)
  main = params.main
end

function commands.SwitchWindow()
  if main.hasDialog() then
    main.closeDialog()
  else
    main.openDialog()
  end
end

function commands.FindNext()
  main.findNextAttachmentUsage()
end

function commands.FindPrev()
  main.findPrevAttachmentUsage()
end

function commands.InsertJoint()
  local initialPoint = app.editor.spritePos

  main.startSelectingJoint(initialPoint)
  app.editor:askPoint{
    title="Click a pixel to specify a joint between parts",
    point=initialPoint,
    onclick=function(ev)
      main.setPossibleJoint(ev.point)
    end,
    onchange=function(ev)
      main.setPossibleJoint(ev.point)
    end,
    oncancel=function(en)
      main.cancelJoint()
    end
  }
end

function commands.AlignAnchors()
  main.alignAnchors()
end

function commands.FocusPrevAttachment()
  main.moveFocusedItem(Point(-1, 0))
end

function commands.FocusNextAttachment()
  main.moveFocusedItem(Point(1, 0))
end

function commands.FocusAttachmentAbove()
  main.moveFocusedItem(Point(0, -1))
end

function commands.FocusAttachmentBelow()
  main.moveFocusedItem(Point(0, 1))
end

function commands.SelectFocusedAttachment()
  main.selectFocusedAttachment()
end

function commands.NewFolder()
  main.newFolder()
end

function commands.ShowTilesID()
  if not main.hasDialog() then return end
  pref.showTilesID = not pref.showTilesID
  imi.repaint = true
end

function commands.ShowUsage()
  if not main.hasDialog() then return end
  pref.showTilesUsage = not pref.showTilesUsage
  imi.repaint = true
end

function commands.ShowUnusedTilesSemitransparent()
  if not main.hasDialog() then return end
  pref.showUnusedTilesSemitransparent = not pref.showUnusedTilesSemitransparent
  imi.repaint = true
end

function commands.ResetZoom()
  if not main.hasDialog() then return end
  pref.setZoom(1.0)
  imi.repaint = true
end

-- All registered commands will be called AttachmentSystem_CommandName
-- where you can find the commands.CommandName() function defined
-- above.
function commands.registerCommands(plugin)
  local steps = {
    { group="view_new" },
    { newGroup="AttachmentSystem_Group", title="Attachment System" },
    { group="AttachmentSystem_Group" },
    { newCommand="SwitchWindow", title="Open/Close Window" },
    { newSeparator=true },
    { newCommand="FindNext", title="Find Next Attachment Usage" },
    { newCommand="FindPrev", title="Find Previous Attachment Usage" },
    { newSeparator=true },
    { newCommand="FocusPrevAttachment", title="Focus Previous Attachment" },
    { newCommand="FocusNextAttachment", title="Focus Next Attachment" },
    { newCommand="FocusAttachmentAbove", title="Focus Attachment Above" },
    { newCommand="FocusAttachmentBelow", title="Focus Attachment Below" },
    { newCommand="SelectFocusedAttachment", title="Select Focused Attachment" },
    { newSeparator=true },
    { newCommand="InsertJoint", title="Insert Joint" },
    { newCommand="AlignAnchors", title="Align Anchors" },
    { newSeparator=true },
    { newCommand="NewFolder", title="New Attachments Folder" },
    { newSeparator=true },
    { newGroup="AttachmentSystem_OptionsGroup", title="Options" },
    { group="AttachmentSystem_OptionsGroup" },
    { newCommand="ShowTilesID", title="Show Attachment ID/Index" },
    { newCommand="ShowUsage", title="Show Attachment Usage" },
    { newCommand="ShowUnusedTilesSemitransparent", title="Show Unused Attachments as Semitransparent" },
    { newCommand="ResetZoom", title="Reset Attachment Window Zoom" }
  }

  local group = nil      -- Current group where we are adding commands
  for _,step in ipairs(steps) do
    -- Set current group
    if step.group then
      group = step.group
    -- New separator
    elseif step.newSeparator then
      plugin:newMenuSeparator{ group=group }
    -- New group
    elseif step.newGroup then
      plugin:newMenuGroup{
        id=step.newGroup,
        title=step.title,
        group=group
      }
    elseif step.newCommand then
      local id = step.newCommand
      plugin:newCommand{
        id="AttachmentSystem_" .. id,
        title=step.title,
        group=group,
        onclick=commands[id]
      }
    end
  end
end

return commands
