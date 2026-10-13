## What does this change?

<!-- A short description of the change and why it is needed. Link related issues, e.g. "Fixes #12". -->

## How was it tested?

<!-- Commands you ran and what you checked by hand. -->

- [ ] `swift test`
- [ ] `swift test -Xswiftc -DCLAUDE_WRITE_ENABLED` (if switching, transfer or recovery code changed)
- [ ] Checked the UI in light and dark mode (if the UI changed)

## Checklist

- [ ] New user-facing text uses `L10n.tr` and has an entry in every file under `Sources/SwitchCore/Localizations/`
- [ ] No tokens, emails, account IDs or other personal data in code, tests, logs or screenshots
- [ ] Writes to Claude's files go through `BuildAccess.requireClaudeWrites()` and the transaction journal
- [ ] `CHANGELOG.md` updated under "Unreleased" for user-visible changes
