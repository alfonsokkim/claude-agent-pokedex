#!/bin/zsh
# Builds "Claude Pet.app" into ~/Applications from ClaudePet.swift.
set -e
here=${0:A:h}
app="$HOME/Applications/Claude Pet.app"

mkdir -p "$app/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 "$here/ClaudePet.swift" -o "$app/Contents/MacOS/ClaudePet"
cp "$here/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null
echo "built $app"
