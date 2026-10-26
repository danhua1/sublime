#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bundle=build/Subline.app
plist="$bundle/Contents/Info.plist"
binary="$bundle/Contents/MacOS/Subline"
/usr/bin/plutil -lint "$plist"
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
[ "$(value CFBundleExecutable)" = Subline ]
[ "$(value CFBundleIdentifier)" = local.subline.editor ]
[ "$(value CFBundlePackageType)" = APPL ]
[ "$(value LSMinimumSystemVersion)" = 12.0 ]
[ "$(value NSPrincipalClass)" = NSApplication ]
[ "$(value CFBundleDocumentTypes:0:CFBundleTypeRole)" = Editor ]
[ -x "$binary" ]
/usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64'
/usr/bin/otool -L "$binary" | /usr/bin/grep -q '/AppKit.framework/'
/usr/bin/otool -l "$binary" | /usr/bin/grep -A 5 LC_BUILD_VERSION | /usr/bin/grep -Eq 'minos 12\.0(\.0)?$'
printf 'PASS: real arm64 AppKit bundle, executable, identifier, document role, macOS 12 deployment target\n'
