#!/bin/zsh
# Renders the README images in docs/images from built-in demo data.
# Windows are drawn off-screen and no real account data is read.
set -euo pipefail
cd "${0:A:h:h}"
output="$PWD/.build/screenshots"
published="$PWD/docs/images"
mkdir -p "$output" "$published"
CLAUDE_SWITCH_SCREENSHOTS="$output" swift test --filter "${1:-ScreenshotTests}"
for name in hero-{en,zh-Hans,zh-Hant,ja}-{light,dark}.jpg \
  {conversations,usage,switch-reminder-menu,switch-selection}-{en,zh-Hans,zh-Hant,ja}-{light,dark}.png \
  social-preview.png; do
  if [[ -f "$output/$name" ]]; then cp "$output/$name" "$published/$name"; fi
done
sips -s format png -Z 512 Resources/AppIcon.icns --out "$published/icon.png" >/dev/null
print "Rendered README images into $published; review states are in $output"
