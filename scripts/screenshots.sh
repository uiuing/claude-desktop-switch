#!/bin/zsh
# Renders the README images in docs/images from built-in demo data.
# Windows are drawn off-screen and no real account data is read.
set -euo pipefail
cd "${0:A:h:h}"
output="$PWD/docs/images"
mkdir -p "$output"
CLAUDE_SWITCH_SCREENSHOTS="$output" swift test --filter ScreenshotTests
sips -s format png -Z 512 Resources/AppIcon.icns --out "$output/icon.png" >/dev/null
print "Rendered images into $output"
