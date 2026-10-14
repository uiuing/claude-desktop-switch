# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Claude Code running in a terminal or an editor no longer blocks switching. Only Claude Desktop's helpers and the Claude Code sessions it started are waited for.
- Old recovery copies are cleaned up: the two newest switches of each account and a week of other finished operations are kept. Unfinished operations are always kept.
- Less background work: the usage cache no longer stores every reply and is written at most every five minutes, unchanged transcripts are not read again, statistics are rescanned every ten minutes while the Usage page is not on screen, waiting for a sign-in checks only the login itself, and a statistics scan no longer redraws the menu bar.

### Fixed

- The "Quota was just read" notice no longer stays on an account card forever: it counts down and disappears when the wait is over. Quota notices can be dismissed, and they are cleared when another account is signed in.
- Saved accounts can be switched to again after Claude Desktop updates itself. Only a login saved by a newer Claude than the one installed is refused.
- An account that uses one organization in Claude Desktop and another in Claude Code keeps its organization, plan and quota steady, and a conversation moved to it no longer lands in an organization Claude Desktop doesn't show.
- Saving the signed-in login tries again by itself when Claude was writing its data at that moment, and the message no longer mentions a preview.
- Simplified Chinese uses mainland wording throughout, for example 数据, 文件 and 操作 instead of 资料, 档案 and 交易.
- The documentation no longer says saved logins only work on this Mac: the Keychain item never syncs to iCloud, but it moves with a full migration of your macOS user account.

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

[Unreleased]: https://github.com/uiuing/claude-desktop-switch/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/uiuing/claude-desktop-switch/releases/tag/v0.1.0
