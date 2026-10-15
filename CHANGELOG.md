# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Smarter account choices, timely reminders and Code conversations that travel with you.

### Added

- Quota-aware account ordering across the account list, menu and search. Plan, session and weekly headroom, and confirmed reset times help rank saved accounts; the current account stays pinned. Stale readings never trigger recommendations.
- Switch reminders in the app and menu bar, with optional macOS notifications. Click to review the recommended account and followed conversations before confirming. Repeated refreshes do not repeat the same low-quota alert.
- Optional operation-result notifications showing the selected account, transferred conversation counts and available quota. Notification preferences and email masking remain under your control.
- A follow-up preview after adding an account, so followed Code conversations can be moved or copied once the new login is saved and verified. A canceled preview remains available to review later.
- Built-in version checks and feedback links. Checks read only this project's public GitHub release redirect, at most once per day automatically or on demand. Downloads and installation remain manual.

### Changed

- More compact account cards, clearer hover and press feedback, and plain-language confirmations and recovery guidance in all ten languages. Custom interaction effects respect Increase Contrast and Reduce Motion.
- Operation results use compact, dismissible cards. Success messages clear after five seconds; errors and recovery warnings remain visible.
- Startup explains and checks access to both Claude's quota key and Switch's saved-login key, and offers optional notification setup. Authorized keys are reused in memory and cleared on sleep or session deactivation.
- Profile checks verify new tokens, both accounts after a switch, and manual quota refreshes. Other automatic reads reuse verified identity while preserving per-login cooldowns.
- Updated English, Simplified Chinese, Traditional Chinese and Japanese guides, refreshed product screenshots and a new social preview. Removed unused translations and kept visual-review captures outside the published documentation.

### Fixed

- Session moves, copies and follow rules retain modes, worktrees, branches, preferences and PR metadata. Account authorization, cloud bindings and live connection state are excluded; local transcripts stay in place.
- Follow rules use the current account's copy, including preference-only changes. A fallback from a third account cannot overwrite a conversation already in the destination.
- Paused or failed quota refreshes keep the last reading and reset time visible. A passed reset waits for online confirmation instead of inventing a full quota; mismatched account or organization readings are rejected.
- Free and unknown plans are distinct. Verified email and plan information takes precedence over local caches, and plan changes clear obsolete quota readings.
- New-account discovery observes cookie WAL changes, retries transient saves and continues after startup or wake. Missing emails can be filled by the online profile, and saving failures provide a retry action.
- Keychain requests share an interaction guard, so background work cannot inherit permission to show a prompt. Damaged login data no longer repeatedly rereads a shared key, and interrupted approvals cannot report success after sleep.

## [0.1.5] - 2026-10-15

More reliable quota readings and account switching, with less background work.

### Upgrading from 0.1.0

- On launch, Claude Switch checks access to **Claude Safe Storage** before opening the workbench. If prompted, choose **Allow access**, then approve the macOS Keychain dialog. Canceling leaves a retry screen; background work waits for authorization.
- Quota and reset times now come only from online responses. Old local estimates are removed, so an account may show **—** until its next successful refresh. Saved logins and conversations are preserved.

### Added

- Configurable automatic quota refresh: the current account follows conversation activity, other accounts default to 30 minutes, and queries are staggered. Refresh pauses when Claude closes and can be disabled in Settings.
- Manual quota refresh for each saved account without switching Claude Desktop. Switching refreshes both the incoming and outgoing accounts once; newly saved logins are also refreshed once.

### Changed

- Failed quota reads retain the last successful online measurement and its timestamp. Elapsed reset times show **Awaiting confirmation**; stale readings no longer drive switch suggestions.
- Current-account quota follows updated credentials, including late renewal after switching. Incoming accounts have priority; startup, wake and network recovery can refresh stale readings. Automatic reads never show a Keychain prompt.
- General refresh and Command-R update local records independently of quota. Use each account's refresh button for quota; cards show the measurement time, with new readings labeled **Just now**.
- Claude Code running in a terminal or an editor no longer blocks switching. Only Claude Desktop's helpers and the Claude Code sessions it started are waited for.
- Old recovery copies are cleaned up: the two newest switches that moved each account's login out of Claude and a week of other finished operations are kept. Unfinished operations are always kept.
- Less background work: unchanged transcripts are skipped, the smaller usage cache is written at most every five minutes, and statistics are rescanned every ten minutes while the Usage page is not visible. Statistics scans no longer redraw the menu bar.

### Fixed

- Saved accounts can be switched to after Claude Desktop updates itself. A login saved by a newer Claude than the installed version is still refused.
- An account using different organizations in Desktop and Claude Code keeps its Desktop organization, plan and quota. Session transfers stop if the destination organization cannot be confirmed.
- Login detection and saved-snapshot validation include committed SQLite WAL data through private copies, so a newly signed-in account can be saved before Claude checkpoints its cookies. Missing cookies no longer mark saved logins permanently expired; old cookie-based invalid flags are cleared. Saving retries when Claude is still writing its login data.
- Quota cooldowns and rejected credentials are tracked separately for each login across restarts. Token renewal cannot bypass server retry delays, and one account's failure does not stop another account's queued refresh.
- One Keychain approval is shared across accounts; permission-blocked requests resume without refreshing each card. Credential blocks and server cooldowns remain intact.
- Expired credentials, missing scopes, Keychain permissions, authorization errors, network failures and server failures have distinct recovery states. Quota parsing accepts only supported window kinds.
- The "Quota was just read" notice no longer stays on an account card forever: it counts down and disappears when the wait is over. Quota notices can be dismissed, and they are cleared when that account is refreshed successfully.
- Opening Usage from Conversations preserves the window width while the conversation details panel closes.
- The German switch hint fits narrow menu rows without truncation.
- Simplified Chinese uses mainland wording throughout, for example 数据, 文件 and 操作 instead of 资料, 档案 and 交易.
- Documentation clarifies that the vault key never syncs to iCloud, but can move with a full migration of your macOS user account.

## [0.1.0] - 2026-10-14

First public release.

### Added

- Menu bar panel and main window for managing Claude Desktop accounts on macOS 14 and later. The menu bar item shows Claude's own icon (taken from the installed Claude app) next to the remaining session limit.
- Automatic saving of the account currently signed in to Claude Desktop, encrypted with AES-256-GCM and a key kept in the macOS Keychain.
- One-click switching: Claude quits normally, the saved login is restored through a journaled, recoverable transaction, and Claude reopens.
- "Add account" moves the current login aside so Claude opens at its sign-in screen, without signing out on the server.
- Detection of logins the server has revoked, with a prompt to sign in again.
- Remaining session limit (5 hours) and weekly limit (7 days) with reset times for every saved account, from Claude Desktop's local records, with an optional on-demand refresh for the signed-in account. Window names follow Claude's own usage screen.
- A suggested account in the menu bar when the signed-in account is running low.
- Conversations page for local Claude Code sessions: search, filter, move or copy to another account, and "follow" rules that carry sessions along when switching.
- Usage page with token totals, model breakdown, activity heatmap, streaks and daily charts, counted the same way as Claude Desktop's local statistics.
- Recovery of unfinished operations from Settings.
- Light, dark and system themes; 10 interface languages.
- Links to the project on GitHub from the sidebar, the menu bar panel and Settings. There are no remote or automatic updates yet; new versions are published as GitHub releases.
- `switch-inspect`, a read-only command-line diagnostic that prints counts only.

[Unreleased]: https://github.com/uiuing/claude-desktop-switch/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/uiuing/claude-desktop-switch/compare/v0.1.0...v0.1.5
[0.1.0]: https://github.com/uiuing/claude-desktop-switch/releases/tag/v0.1.0
