# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Choose which Code conversations follow an account switch directly in its confirmation: saved follows and the current account's three most recently active conversations appear together, with move/copy choices. Successful switches remember the selection.
- Automatically select all eligible Code conversations active in the last five minutes when reviewing an account switch, including those beyond the three most recent suggestions. Each can still be deselected.

### Fixed

- Account switches with followed Code conversations no longer fail when Claude's quit cleanup changes only JSON formatting or excluded connection state. Preserved metadata and destination changes still stop the operation; transaction failures now log their stage without account data.
- Quota refresh can use an eligible Code credential when the preferred Desktop credential was already rejected, including after restarting Switch.

## [0.2.2] - 2026-10-16

Clearer quota reminders, smoother conversation browsing and more reliable menu bar behavior.

### Added

- Optional Code task status and conversation shortcuts in the menu bar.
- A setting to hide project links from the menu bar.

### Improved

- Clearer low-quota badges make it easier to see when a switch could help, including when your weekly quota runs out.
- Faster conversation search and less background work in large libraries.
- Fewer interruptions: low-quota reminders begin at 10% session quota or 5% weekly quota remaining.

### Fixed

- Quota and task counts display together correctly in the menu bar.
- The menu reopens on the next click after opening a conversation or another destination.
- Low-quota reminders no longer repeat as the percentage drops or the reset time is corrected.
- More consistent backup recommendations, with better preference for accounts that have more weekly quota available.

### Documentation

- Refreshed screenshots and social preview, with guides in four languages.

## [0.2.0] - 2026-10-16

Switch recommendations, timely reminders, and an easier way to bring your Code conversations to another account.

### Added

- Low-quota reminders in the menu bar and optional macOS notifications. Review a recommended account when you are ready to switch.
- After adding an account, choose which followed Code conversations to bring with you.
- Optional notifications for completed switches and conversation transfers.
- Version checks and feedback links inside the app.

### Improved

- Accounts with available quota are easier to find, with matching recommendations across the app and menu bar.
- More compact account cards, clearer controls and simpler messages in all ten languages.
- Updated guides in four languages, new screenshots and a refreshed social preview.

### Fixed

- Moved and copied Code conversations keep their conversation settings.
- Quota stays visible when automatic refresh is paused or temporarily unavailable.
- New accounts are found and saved more reliably, with more accurate emails and plan names.
- More reliable Keychain access and fewer repeated permission requests.

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

[Unreleased]: https://github.com/uiuing/claude-desktop-switch/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/uiuing/claude-desktop-switch/compare/v0.2.0...v0.2.2
[0.2.0]: https://github.com/uiuing/claude-desktop-switch/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/uiuing/claude-desktop-switch/compare/v0.1.0...v0.1.5
[0.1.0]: https://github.com/uiuing/claude-desktop-switch/releases/tag/v0.1.0
