-- Aseprite Attachment System
-- Copyright (c) 2022-2023  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

-- Modules
local commands = require 'commands'
local pref = require 'pref'
local main = require 'main'

function init(plugin)
  if app.apiVersion < 23 then return app.alert "The Attachment System plugin needs Aseprite v1.3-rc3" end

  commands.initVars{ main=main }
  commands.registerCommands(plugin)

  pref.load(plugin)
end

function exit(plugin)
  if app.apiVersion < 23 then return end

  main.closeDialog()
  pref.save(plugin)
end
