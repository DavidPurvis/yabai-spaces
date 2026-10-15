#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
test "$(uname -s)" = Darwin || { printf '%s\n' 'This app requires macOS.' >&2; exit 1; }
mkdir -p build/YabaiSpaces.app/Contents/MacOS build/YabaiSpaces.app/Contents/Resources build/module-cache
MACOSX_DEPLOYMENT_TARGET=13.0 xcrun swiftc -swift-version 5 -O \
    -framework AppKit -framework CoreGraphics -module-cache-path build/module-cache \
    app/HoverFocus.swift app/HoverSelfTests.swift app/main.swift -o build/YabaiSpaces.app/Contents/MacOS/YabaiSpaces
cp app/Info.plist build/YabaiSpaces.app/Contents/Info.plist
cp docs/REFERENCE.md build/YabaiSpaces.app/Contents/Resources/Reference.md
/usr/bin/codesign --force --sign - build/YabaiSpaces.app
/usr/bin/codesign --verify --strict build/YabaiSpaces.app
printf '%s\n' 'Built build/YabaiSpaces.app (local ad-hoc signature; not notarized).'
