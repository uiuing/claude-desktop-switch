# Contributing to Claude Switch

Thanks for helping out. Bug reports, translations, documentation and code are all welcome.

## Before you start

- For anything larger than a small fix, please open an issue first so we can agree on the approach.
- Report security problems privately; see [SECURITY.md](SECURITY.md).
- Never put real tokens, cookies, account IDs or full email addresses in issues, tests, logs or screenshots.

## Development setup

You need macOS 14 or later and Xcode 16 or later (Swift 6 toolchain). There are no third-party dependencies.

```sh
swift build                    # debug build, read-only
swift test                     # unit tests
python3 scripts/check-localization.py
```

To try the app without touching your own Claude data, run it with sample data:

```sh
zsh scripts/build.sh --read-only
open "dist/Claude Switch.app" --args --demo
```

Tests that exercise switching, session transfer and recovery are compiled only when writes are enabled. They run against temporary fixtures inside `.build/` and never touch your real Claude folders:

```sh
swift test --scratch-path .build/write-tests -Xswiftc -DCLAUDE_WRITE_ENABLED
```

Please test changes to switching or transfers with a separate macOS user or dedicated test accounts, not with the Claude installation you work in.

## Ground rules for code

- **Writes are gated.** Anything that changes Claude's files or processes must call `BuildAccess.requireClaudeWrites()` and go through `SwitchEngine` and `FileTransaction`, so it is journaled and can be rolled back.
- **Stay inside the allow-list.** Do not widen the set of files described in [docs/how-it-works.md](../docs/how-it-works.md) without discussing it first.
- **Keep network access bounded.** Account access uses only the documented quota and profile reads. Automatically refresh both logins involved in an account switch, and a newly saved login, once each; eligible saved logins also use the documented configurable, staggered periodic schedule while Claude is running. Current-account credential publication and stale/recovery lifecycle events may also trigger bounded reads. Automatic reads must respect account/organization back-off and never prompt for Keychain access. Never renew tokens or query logins known to be revoked. Update checks may read this project's public GitHub latest-release redirect, without credentials or local data, manually or at most once per day automatically. They never download or install a release.
- **No secrets in output.** Tokens, cookies and emails must never reach logs, errors, the clipboard or shell arguments.
- **Fail closed.** Unknown login formats, malformed records, identity conflicts, unsafe paths and changed fingerprints stop the operation. Session transfers preserve opaque Claude metadata while removing documented account and connection fields; see [session fields](../docs/session-fields.md).
- Match the surrounding style: small types, clear names, comments only where the code cannot speak for itself.

## Working with AI coding assistants

[AGENTS.md](../AGENTS.md) describes the repository, commands, hard safety rules and conventions for AI assistants; Claude Code loads it through [CLAUDE.md](../CLAUDE.md), which also lists project slash commands such as `/check`, `/add-string` and `/safety-review`. The local formats of Claude Desktop and Claude Code that this project depends on are documented in [docs/claude-internals.md](../docs/claude-internals.md). Contributions made with an assistant follow the same review standards as any other.

## Localization

All user-facing text uses `L10n.tr("English source text", arguments...)`. Every key must exist in all ten files under `Sources/SwitchCore/Localizations/`, with the same `{0}`, `{1}` placeholders. Use dotted keys (for example `quota.session`) when the same English word needs different translations in different places.

`python3 scripts/check-localization.py` and `LocalizationTests` check keys, placeholders and that no CJK text is hard-coded in sources. Native speakers reviewing translations are especially welcome.

## Screenshots

The images in `docs/images` are rendered from the built-in demo data:

```sh
zsh scripts/screenshots.sh
```

Please regenerate them when a pull request changes the visible UI.

The script publishes README and social-preview assets to `docs/images`. Additional language, error and narrow-layout captures stay in `.build/screenshots` for visual review.

## Pull requests

- Keep each pull request focused on one change.
- Make sure `swift test` and the localization check pass.
- Add a line to `CHANGELOG.md` under **Unreleased** for user-visible changes.
- Describe how you tested it, including any manual checks.

By contributing, you agree that your contributions are licensed under the [MIT License](../LICENSE).
