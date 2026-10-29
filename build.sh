#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
output="${BRIDGE_BUILD_DIR:-$HOME/Library/Caches/MDDNowPlayingBridge/Build}/MDD Now Playing 桥接.app"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
swiftc -parse-as-library -O -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" "$root"/Sources/*.swift -o "$output/Contents/MacOS/MDDNowPlayingBridge"
cp -X "$root/Resources/Info.plist" "$output/Contents/Info.plist"
mdd_icon="${MDD_APP_PATH:-/Applications/MDDClass.app}/Contents/Resources/MDDClass.icns"
if [[ -f "$mdd_icon" ]]; then
  cp -X "$mdd_icon" "$output/Contents/Resources/MDDClass.icns"
else
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$output/Contents/Info.plist"
  print 'MDD icon unavailable; building with the system default app icon.'
fi
xattr -cr "$output"
codesign --force --sign - --timestamp=none "$output"
codesign --verify --deep --strict "$output"
print "Built: $output"
print 'Build only. Copy the app to ~/Applications yourself before granting permission.'
