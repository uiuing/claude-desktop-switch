#!/bin/zsh
# Builds "dist/Claude Switch.app". It never launches the app or Claude and never runs tests.
#
# Usage: scripts/build.sh [--read-only] [--universal]
#   --read-only   build an app that can inspect and preview, but never changes Claude's files
#   --universal   build for both Apple silicon and Intel
#
# Environment:
#   CODESIGN_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)". Defaults to ad-hoc signing.
#   CLAUDE_SWITCH_DIST_DIR   optional staging directory; defaults to dist/
set -euo pipefail
cd "${0:A:h:h}"

flags=(-Xswiftc -DCLAUDE_WRITE_ENABLED)
arch=()
for arg in "$@"; do
  case "$arg" in
    --read-only) flags=() ;;
    --universal) arch=(--arch arm64 --arch x86_64) ;;
    *) print -u2 'Usage: scripts/build.sh [--read-only] [--universal]'; exit 2 ;;
  esac
done

swift build -c release "${arch[@]}" "${flags[@]}"
product_dir="$(swift build -c release "${arch[@]}" "${flags[@]}" --show-bin-path)"

bundle="${CLAUDE_SWITCH_DIST_DIR:-$PWD/dist}/Claude Switch.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# L10n looks for this resource bundle in Contents/Resources before SwiftPM's build folder.
cp -R "$product_dir/ClaudeDesktopSwitch_SwitchCore.bundle" "$bundle/Contents/Resources/"
cp "$product_dir/ClaudeSwitch" "$bundle/Contents/MacOS/ClaudeSwitch"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/"
# Debug symbols hold absolute paths of the build machine; the shipped binary must carry none.
/usr/bin/strip -S -x "$bundle/Contents/MacOS/ClaudeSwitch" 2>/dev/null

identity="${CODESIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
  /usr/bin/codesign --force --sign - "$bundle"
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$bundle"
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
print "Built Claude Switch $version: $bundle"
