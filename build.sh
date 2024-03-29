#! /bin/bash

version=$(cat package.json | grep "\"version\"" | sed 's/.*"version": "\(.*\)".*/\1/')
zip Attachment-System-$version.aseprite-extension \
    LICENSE.txt \
    README.md \
    base.lua \
    commands.lua \
    db.lua \
    default.aseprite-keys \
    edit-attachment.lua \
    export.lua \
    imi.lua \
    main.lua \
    package.json \
    plugin.lua \
    pref.lua \
    usage.lua
