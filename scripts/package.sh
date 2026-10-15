#!/bin/zsh
# Builds a universal release and packs it as dist/ClaudeSwitch-<version>-macOS.zip plus a .sha256 file.
#
# Environment (all optional):
#   CODESIGN_IDENTITY   Developer ID identity used by scripts/build.sh; ad-hoc signing otherwise
#   NOTARY_PROFILE      `xcrun notarytool store-credentials` profile; when set, the app is notarized and stapled
#   CLAUDE_SWITCH_DIST_DIR   optional staging directory; defaults to dist/
set -euo pipefail
cd "${0:A:h:h}"

zsh scripts/build.sh --universal

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
package_dir="${CLAUDE_SWITCH_DIST_DIR:-$PWD/dist}"
app="$package_dir/Claude Switch.app"
archive="$package_dir/ClaudeSwitch-$version-macOS.zip"
rm -f "$archive" "$archive.sha256"

/usr/bin/codesign --verify --deep --strict "$app"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    print -u2 'NOTARY_PROFILE requires CODESIGN_IDENTITY (a Developer ID Application identity).'
    exit 2
  fi
  /usr/bin/ditto -c -k --keepParent "$app" "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  rm -f "$archive"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd "$package_dir" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
print "Packed $archive"
cat "$archive.sha256"
