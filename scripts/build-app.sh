#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
/usr/bin/xcrun swift build -c release --scratch-path .build
bin_dir=$(/usr/bin/xcrun swift build -c release --scratch-path .build --show-bin-path)
bundle=build/Subline.app
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# Replace the executable inode instead of modifying a previously launched
# Mach-O in place (macOS may retain its old code-signature cache).
cp "$bin_dir/Subline" "$bundle/Contents/MacOS/Subline.next"
chmod 755 "$bundle/Contents/MacOS/Subline.next"
mv -f "$bundle/Contents/MacOS/Subline.next" "$bundle/Contents/MacOS/Subline"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
chmod 755 "$bundle/Contents/MacOS/Subline"
printf 'Built %s\n' "$bundle"
