#! /bin/bash

version=$(cat package.json | grep "\"version\"" | sed 's/.*"version": "\(.*\)".*/\1/')
zip Attachment-System-$version.aseprite-extension \
    LICENSE.txt \
    README.md \
    db.lua \
    default.aseprite-keys \
    export.lua \
    imi.lua \
    package.json \
    plugin.lua
