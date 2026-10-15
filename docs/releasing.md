# Releasing

Releases are built locally and published by hand on GitHub. Claude Switch checks the project's public latest release, automatically at most once per day or on demand. Users download and install the app themselves through the stable `/releases/latest` link. Publish a non-draft, non-prerelease release with a stable `vX.Y.Z` tag and mark it latest when it is ready for users; a tag alone is not an update.

`Resources/Info.plist` is the single source of the version. Versions follow [Semantic Versioning](https://semver.org).

## Steps

1. Update the version in `Resources/Info.plist`:
   - `CFBundleShortVersionString`: the user-facing version `X.Y.Z`
   - `CFBundleVersion`: increase by one for every release
2. Move the entries under **Unreleased** in `CHANGELOG.md` into a new section `## [X.Y.Z] - YYYY-MM-DD` and update the comparison links at the bottom.
3. If the UI changed, regenerate the README images with `zsh scripts/screenshots.sh` and set their README image URL cache keys to `?v=X.Y.Z` using the release version. The download badge links to the latest release without caching a displayed version or download count.
4. Check and build:

   ```sh
   python3 scripts/check-localization.py
   swift build
   swift test
   swift test --scratch-path .build/write-tests -Xswiftc -DCLAUDE_WRITE_ENABLED
   zsh scripts/package.sh            # dist/ClaudeSwitch-X.Y.Z-macOS.zip and .sha256
   ```

   Verify both architectures, the signature and the archive checksum. Inspect the regenerated images, including English and German in narrow layouts.

   ```sh
   lipo "dist/Claude Switch.app/Contents/MacOS/ClaudeSwitch" -verify_arch arm64 x86_64
   codesign --verify --deep --strict "dist/Claude Switch.app"
   (cd dist && shasum -a 256 -c ClaudeSwitch-X.Y.Z-macOS.zip.sha256)
   if LC_ALL=C grep -a -q '/Users/' "dist/Claude Switch.app/Contents/MacOS/ClaudeSwitch"; then
     echo 'Build paths remain in the release binary.' >&2
     exit 1
   fi
   zsh scripts/release-notes.sh X.Y.Z > dist/release-notes-X.Y.Z.md
   ```

   Fixture tests and demo screenshots do not verify real-account switching, Keychain approval or live quota requests. Record any separate manual acceptance and outstanding limits before publishing. Do not run acceptance against a developer's everyday Claude data.

5. Review the changed files and stage only the intended release files. Add updated documentation, scripts or screenshots explicitly when applicable. After reviewing the staged diff, commit, tag and push:

   ```sh
   git status --short
   git diff --check
   git diff
   git add Resources/Info.plist CHANGELOG.md
   git diff --cached
   git commit -m "Release X.Y.Z"
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

6. Publish the release, either with the GitHub CLI:

   ```sh
   gh release create vX.Y.Z \
     dist/ClaudeSwitch-X.Y.Z-macOS.zip dist/ClaudeSwitch-X.Y.Z-macOS.zip.sha256 \
     --verify-tag \
     --title "Claude Switch X.Y.Z" \
     --notes-file dist/release-notes-X.Y.Z.md
   ```

   or on the website: **Releases → Draft a new release**, choose the tag `vX.Y.Z`, set the title `Claude Switch X.Y.Z`, paste the output of `zsh scripts/release-notes.sh X.Y.Z` as the description, attach the zip and the `.sha256` file, keep **Set as the latest release** checked, and publish.

`scripts/release-notes.sh` prints the version's `CHANGELOG.md` section followed by install and update instructions.

To prepare and verify a replacement without overwriting an app that may be running from `dist/`, set `CLAUDE_SWITCH_DIST_DIR` to a separate staging directory when running `scripts/package.sh`. After verifying that package, quit only Claude Switch normally, retain the previous bundle for rollback, and replace the installed app. Claude Desktop does not need to be closed for this app update.

## Signing and notarization (optional)

By default the app is ad-hoc signed. Users have to approve it once in **System Settings → Privacy & Security**. After an update, the startup authorization screen may require renewed access to **Claude Safe Storage**, and macOS may also ask for access to Claude Switch's vault key. With an Apple Developer ID the app can be signed and notarized instead:

1. Store notarization credentials once in your login keychain:

   ```sh
   xcrun notarytool store-credentials claude-switch \
     --apple-id "<your Apple ID>" --team-id "<TEAMID>" --password "<app-specific password>"
   ```

2. Build, sign with the hardened runtime, notarize and staple:

   ```sh
   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE=claude-switch \
   zsh scripts/package.sh
   ```

With a stable signing identity, macOS remembers "Always Allow" choices for Keychain items across updates.
