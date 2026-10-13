---
description: Prepare a release locally (version, changelog, checks) without pushing
argument-hint: <X.Y.Z>
---

Prepare release $ARGUMENTS following docs/releasing.md:

1. Confirm `$ARGUMENTS` is a valid semantic version greater than `CFBundleShortVersionString` in `Resources/Info.plist`. Stop if not.
2. In `Resources/Info.plist`, set `CFBundleShortVersionString` to `$ARGUMENTS` and increase `CFBundleVersion` by one.
3. In `CHANGELOG.md`, move everything under **Unreleased** into `## [$ARGUMENTS] - <today>` and update the comparison links at the bottom. Stop and ask if Unreleased is empty.
4. Run the `/check` steps and `zsh scripts/package.sh`.
5. Run `zsh scripts/release-notes.sh $ARGUMENTS` and show the notes.
6. Show the diff and the commands to finish: commit, `git tag v$ARGUMENTS`, `git push origin main v$ARGUMENTS`, and the `gh release create` command from docs/releasing.md. Do not commit, tag, push or publish yourself.
