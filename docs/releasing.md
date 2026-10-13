# Releasing

Releases are built locally and published by hand on GitHub. Claude Switch doesn't have automatic or remote updates yet, so a GitHub release is how users learn about and get a new version.

`Resources/Info.plist` is the single source of the version; the first release is `0.1.0`. Versions follow [Semantic Versioning](https://semver.org).

## Steps

1. Update the version in `Resources/Info.plist`:
   - `CFBundleShortVersionString`: the user-facing version `X.Y.Z`
   - `CFBundleVersion`: increase by one for every release
2. Move the entries under **Unreleased** in `CHANGELOG.md` into a new section `## [X.Y.Z] - YYYY-MM-DD` and update the comparison links at the bottom.
3. If the UI changed, regenerate the README images with `zsh scripts/screenshots.sh`.
4. Check and build:

   ```sh
   python3 scripts/check-localization.py
   swift test
   swift test --scratch-path .build/write-tests -Xswiftc -DCLAUDE_WRITE_ENABLED
   zsh scripts/package.sh            # dist/ClaudeSwitch-X.Y.Z-macOS.zip and .sha256
   ```

5. Commit, tag and push:

   ```sh
   git commit -am "Release X.Y.Z"
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

6. Publish the release, either with the GitHub CLI:

   ```sh
   gh release create vX.Y.Z \
     dist/ClaudeSwitch-X.Y.Z-macOS.zip dist/ClaudeSwitch-X.Y.Z-macOS.zip.sha256 \
     --title "Claude Switch X.Y.Z" \
     --notes "$(zsh scripts/release-notes.sh X.Y.Z)"
   ```

   or on the website: **Releases → Draft a new release**, choose the tag `vX.Y.Z`, set the title `Claude Switch X.Y.Z`, paste the output of `zsh scripts/release-notes.sh X.Y.Z` as the description, attach the zip and the `.sha256` file, keep **Set as the latest release** checked, and publish.

`scripts/release-notes.sh` prints the version's `CHANGELOG.md` section followed by install and update instructions.

## Signing and notarization (optional)

By default the app is ad-hoc signed. Users have to approve it once in **System Settings → Privacy & Security**, and after each update macOS may ask again whether the new version can use the app's Keychain item. With an Apple Developer ID the app can be signed and notarized instead:

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
