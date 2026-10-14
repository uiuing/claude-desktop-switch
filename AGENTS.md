# AGENTS.md

Guidance for AI coding assistants (Claude Code, Codex, Cursor and others) working in this repository. People should start with [CONTRIBUTING](.github/CONTRIBUTING.md); everything here applies to them too.

## What this is

Claude Switch is a native macOS menu bar app (Swift 6 toolchain, SwiftUI + AppKit, macOS 14+, no third-party dependencies) that saves Claude Desktop logins in an encrypted vault and switches between them. It also shows each account's session and weekly limits, moves or copies local Claude Code sessions between accounts, and shows local usage statistics.

It touches real credentials and another app's private files. **Correctness and safety matter more than features.**

## Repository map

| Path | Contents |
| --- | --- |
| `Sources/SwitchCore` | Foundation-only models, quota presentation, reset inference, switch suggestions, follow rules, plans, `L10n` and the JSON catalogs in `Localizations/` |
| `Sources/SwitchStorage` | Bounded, symlink-safe reading of Claude's files (`SafeFiles`, `LocalReader`, `DesktopProfile`, `TokenScanner`, `LimitLogScanner`, `LoginProbe`) and the app's own `LibraryStore` |
| `Sources/SwitchMac` | macOS side: `SwitchEngine` (plans and execution), `FileTransaction` (journal and rollback), `CredentialVault`, `DesktopController` (Claude process), `ActiveUsageClient` (online quota), `MigrationBuilder` (session transfer) |
| `Sources/ClaudeSwitch` | SwiftUI app: `AppState`, `MenuPanel`, `MainWindow`, pages, sheets, `Theme` (formatting, quota bars, menu bar glyph), `DemoData` |
| `Sources/SwitchInspect` | `switch-inspect`, a read-only diagnostic that prints counts only |
| `Tests/` | `SwitchCoreTests`, `SwitchMacTests` (fixtures under `.build/`), `ScreenshotTests` (opt-in README image renderer) |
| `scripts/` | `build.sh`, `package.sh`, `release-notes.sh`, `screenshots.sh`, `check-localization.py`, `make-icon.swift` |
| `docs/` | [how-it-works](docs/how-it-works.md), [usage-data](docs/usage-data.md), [architecture](docs/architecture.md), [claude-internals](docs/claude-internals.md), [releasing](docs/releasing.md) |

Read [docs/claude-internals.md](docs/claude-internals.md) before touching anything that parses Claude's files, and [docs/how-it-works.md](docs/how-it-works.md) before touching switching, transfers or recovery.

## Commands

```sh
swift build                                   # debug build (read-only: writes compiled out)
swift test                                    # unit tests
swift test --scratch-path .build/write-tests -Xswiftc -DCLAUDE_WRITE_ENABLED   # also the write-path tests, on fixtures
python3 scripts/check-localization.py         # catalogs, placeholders, no hard-coded CJK
zsh scripts/build.sh [--read-only] [--universal]   # dist/Claude Switch.app
zsh scripts/package.sh                        # universal zip + sha256 in dist/
zsh scripts/release-notes.sh [X.Y.Z]          # GitHub release notes from CHANGELOG.md
zsh scripts/screenshots.sh                    # re-render docs/images from demo data
open "dist/Claude Switch.app" --args --demo   # run the UI with sample data only
```

SwiftPM needs to run outside restrictive sandboxes (it uses `sandbox-exec` for the manifest). The first build takes about a minute; incremental builds take seconds.

## Hard rules

1. **Never operate on the developer's real Claude data.** Do not run the app without `--demo`, do not run switching or transfer code against `~/Library/Application Support/Claude`, and do not quit, kill or restart Claude. Test write paths only through the fixture tests.
2. **Never read secrets.** No `security` CLI, no Keychain queries, no reading Claude's `config.json`, cookies, IndexedDB, `~/.claude.json` or Claude Switch's vault from a terminal. `switch-inspect` is the only sanctioned look at real data, and it prints counts only.
3. **No real personal data in the repository.** Tests, fixtures, docs and screenshots use synthetic UUIDs (for example `0a1b2c3d-1111-4aaa-8bbb-000000000001`) and masked emails on common providers (`mi•••el@gmail.com`). Do not use `example.com`-style addresses in user-facing material, and never copy real account IDs, emails, paths or usage numbers from a machine.
4. **Writes go through the gate.** Anything that changes Claude's files or processes calls `BuildAccess.requireClaudeWrites()` and runs inside a `FileTransaction` created by `SwitchEngine`, so it is journaled, re-validated and reversible. Never write Claude's files directly.
5. **Stay inside the allow-list.** Only the identity items in `IdentitySchema` and the whitelisted session index fields may change. Widening either needs an explicit decision from a maintainer.
6. **Fail closed.** Unknown formats, unexpected keys, ambiguous organizations or changed fingerprints stop the operation with a clear message. Never guess, never fall back to "probably fine".
7. **Network stays minimal.** Only the documented `profile` and `usage` GETs for the signed-in account, on the documented triggers. No telemetry, no new hosts, no token refresh, nothing for signed-out accounts.
8. **No secrets in output.** Tokens, cookies and emails never reach logs, error messages, the clipboard, shell arguments or test output.
9. **Never kill processes.** Claude is quit with a normal quit request; if it does not quit, the operation stops.
10. **No third-party artwork in the repository.** Claude's logo appears only in the status item, in front of the percentage, loaded at runtime from the installed Claude app (`StatusIcon`). Everywhere else the app uses its own icon. Do not copy Anthropic's or anyone else's icons, logos or code into this project.

## Conventions

- **Swift style**: Swift 5 language mode with the Swift 6 toolchain; actors serialize I/O; small focused types; match the compact style of the file you are in. Comments state constraints the code cannot show, never the history of a change.
- **Localization**: every user-facing string is `L10n.tr("English source text", args…)` with indexed placeholders `{0}`, `{1}`. Add the key to all ten catalogs in `Sources/SwitchCore/Localizations/` (`en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `es`, `fr`, `de`, `pt-BR`, `ru`), keeping JSON insertion order and two-space indentation. Use dotted keys (`quota.session`) when one English word needs different translations in different places. Simplified Chinese uses mainland terms (数据, 文件, 支持, 信息, 操作, 退出登录, 钥匙串); the check rejects common Taiwanese ones. No CJK text in Swift, Python or shell sources. Run `scripts/check-localization.py`.
- **Usage-limit names follow Claude's own usage screen**, through `L10n.quotaTitle` and `L10n.quotaShortTitle`:

  | Window | English | 简体中文 | Narrow columns |
  | --- | --- | --- | --- |
  | `five_hour` | Session limit | 5 小时额度 | Session / 5 小时 |
  | `seven_day` | Weekly · all models | 周额度 | Weekly / 每周 |
  | `seven_day_opus` | Weekly · Opus | 周额度 · Opus | — |

  German, Spanish, French, Japanese, Korean and Portuguese use Claude's official translations (see [claude-internals](docs/claude-internals.md#claude-desktop-app)). Do not call these "5 hours" or "7 days": the Usage page's "7 days" is a date range, not a limit.
- **Text must fit**: check English and German in narrow places (menu rows, 56 pt quota columns); prefer shorter wording over truncation.
- **Demo data** (`DemoData.swift`) is fictional, deterministic and marketing-quality: masked US-provider emails, realistic plans (Max 20x, Max 5x, Team, Pro), model names without version numbers, and states that exercise the UI (a suggested switch, low quota colors, "Starts on next use").
- **Screenshots** come only from `scripts/screenshots.sh`. Re-render them when the visible UI changes and look at the results before committing.
- **Repository URL**: in the app it comes only from `ProjectLink` (`Sources/ClaudeSwitch/ProjectLink.swift`); the READMEs, `CHANGELOG.md` and `.github/ISSUE_TEMPLATE/config.yml` repeat it, so a rename touches all of them.
- **Versioning**: `Resources/Info.plist` is the single source of the version (Semantic Versioning, first release `0.1.0`). User-visible changes get a line under **Unreleased** in `CHANGELOG.md`. Do not invent version numbers in docs; use `X.Y.Z` in examples.

## Pitfalls

- Unstripped binaries embed absolute build paths (the build machine's user name and folders). `scripts/build.sh` strips debug symbols before signing; keep that step, and check `dist/` with `grep -a /Users/` before publishing.
- A file named `main.swift` cannot also use `@main`; the universal (`--arch arm64 --arch x86_64`) build uses Xcode's build system and rejects it.
- The packaged app loads catalogs from `Contents/Resources/ClaudeDesktopSwitch_SwitchCore.bundle`; SwiftPM runs and tests fall back to `Bundle.module`.
- Ad-hoc signed builds change identity on every build, so macOS asks again for the "Claude Safe Storage" Keychain item. That prompt may appear only after a user-initiated refresh, never from automatic triggers.
- `lastKnownAccountUuid` survives a sign-out; use `LoginProbe` (the `sessionKey` cookie) to know whether Claude is actually signed in.
- Claude Code transcripts are shared by all accounts and carry no account ID; never attribute usage to an account without explicit evidence.
- Writing to a running script (`scripts/*.sh`) while it executes can break the run.

## Before you finish

- [ ] `swift build` and `swift test` pass; the write-path tests pass if switching, transfer or recovery code changed
- [ ] `python3 scripts/check-localization.py` passes and new strings exist in all ten catalogs
- [ ] No real personal data, tokens or machine paths in the diff
- [ ] Docs and `CHANGELOG.md` (Unreleased) updated for user-visible changes; screenshots re-rendered if the UI changed
