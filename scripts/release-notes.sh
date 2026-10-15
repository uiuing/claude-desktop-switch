#!/bin/zsh
# Prints the GitHub release notes for a version: its CHANGELOG.md section plus install and update instructions.
# Usage: scripts/release-notes.sh [X.Y.Z]   (defaults to the version in Resources/Info.plist)
set -euo pipefail
cd "${0:A:h:h}"

version="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
section="$(awk -v version="$version" '
  index($0, "## [" version "]") == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found && /^\[.*\]: / { exit }
  found { print }
' CHANGELOG.md)"
if [[ -z "${section//[[:space:]]/}" ]]; then
  print -u2 "CHANGELOG.md has no section for $version."
  exit 1
fi

print -r -- "$section"
cat <<EOF

### Install

1. Download \`ClaudeSwitch-$version-macOS.zip\` below, unzip it and move **Claude Switch** to Applications.
2. The app is not notarized by Apple yet. On first launch:
   - macOS 15 and later: open **System Settings → Privacy & Security** and click **Open Anyway**.
   - macOS 14: right-click the app, choose **Open**, then confirm.

   Or run \`xattr -dr com.apple.quarantine "/Applications/Claude Switch.app"\` in Terminal.

Requires macOS 14 or later, Apple silicon or Intel. To verify the download: \`shasum -a 256 -c ClaudeSwitch-$version-macOS.zip.sha256\`

### Updating

Check for new versions in **Settings → Updates**, where you can also turn automatic checks off. Downloading and installing remain manual. Quit Claude Switch before replacing it in Applications. If asked on launch, choose **Allow access** and approve the macOS prompts. **Always Allow** helps avoid repeated prompts.
EOF
