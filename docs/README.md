# Aseprite Attachment System

The Aseprite Attachment System is an experimental plugin to manage
hierarchies of sprites in [Aseprite](https://www.aseprite.org) using
tiles & tilesets. The general idea is to be able to create characters
attaching and reusing parts of their body through all the animations,
making high-framerate and modular characters possible in pixel-art.

Sponsored by [Soupmasters](https://soupmasters.com/) to manage huge
animations in [Big Boy Boxing](https://store.steampowered.com/app/1680780/Big_Boy_Boxing/).

[![Soupmasters Logo](https://user-images.githubusercontent.com/39654/210549230-ec3a32f4-14af-4cf0-9286-ee1f4f589011.png)](https://soupmasters.com/)

## Experimental

This extension --and this documentation-- is a [work-in-progress](https://github.com/orgs/aseprite/projects/7).
Based on ideas of Soupmasters team, we're working together to speed up their
workflow. Anyway feel free to use this extension and provide
[feedback](https://github.com/aseprite/Attachment-System/issues) in
case you find it useful for your own game.

## Overview

The main goal of this plugin is to being able to create sprites
drawing different attachments/parts/modules and integrating them to
compose each frame. Begin able to exchange those parts on any frame as
you need, and re-using as many parts as possible.

Some concept of the Attachment System:

* *Attachments*: Each layer that uses attachments is a [tilemap
  layer](https://www.aseprite.org/docs/tilemap), with just one big
  tile on each frame. This tile is the instance of the attachment. It
  means that this tilemap layer uses a tileset where each tile has the
  whole canvas size (it's not the regular tileset we're used to see
  with small tiles).

* *Categories*: All categories for same layer are similar tilesets
  (tilesets with the same number *and same order* of tiles) where
  their tiles matches a different variations/alternatives of the same
  graphic. E.g. You can have a "Base" category for a "Body" layer, but
  you might have an alternative category called "Armored" with the same
  graphics as the "Base" but with an armor.

* *Folders*: Each folder is a place where you can arrange the
  attachments in any order. There is the "Base Set" folder where all
  attachments are present, but then you can create your own folders to
  rearrange and keep your attachments organized based on animations or
  similarities.

## Internals

This Attachment System uses several new features of Aseprite like
[extension-defined properties](https://www.aseprite.org/api/properties#extension-defined-properties)
to store its data in `.aseprite` files, and [canvas widget](https://www.aseprite.org/api/dialog#dialogcanvas)
and [GraphicsContext](https://www.aseprite.org/api/graphicscontext)
to paint the custom Attachment System window.

Also the standard Aseprite tilemap manager is disabled as the plugin
uses tiles to represent attachments. This is possible because the
[Sprite.tileManagementPlugin](https://www.aseprite.org/api/sprite#spritetilemanagementplugin)
property is changed by the plugin to `"aseprite/Attachment-System"`.
