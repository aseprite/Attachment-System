#! /bin/bash

version=$(cat package.json | grep "\"version\"" | sed 's/.*"version": "\(.*\)".*/\1/')
zip Attachment-System-$version.aseprite-extension \
    README.md \
    LICENSE.txt \
    package.json \
    imi.lua \
    plugin.lua