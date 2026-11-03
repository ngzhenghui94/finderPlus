#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="$PWD/dist/FinderPlus.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FinderPlus "$APP/Contents/MacOS/FinderPlus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/MakeIcon.swift "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '\nBuilt %s\n' "$APP"
