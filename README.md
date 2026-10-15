<div align="center">

<img src="docs/images/icon.png" width="112" alt="Claude Switch icon">

# Claude Switch

**Every Claude Desktop account, one click away in your Mac's menu bar.**

Save your logins, see what quota is left, and bring your local Code conversations when you switch.

[![Latest release](https://img.shields.io/github/v/release/uiuing/claude-desktop-switch?style=flat-square&color=C9653F&label=release)](https://github.com/uiuing/claude-desktop-switch/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/uiuing/claude-desktop-switch/total?style=flat-square&color=C9653F)](https://github.com/uiuing/claude-desktop-switch/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square&logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-3B82F6?style=flat-square)](LICENSE)

**English** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-en-dark.jpg">
  <img src="docs/images/hero-en-light.jpg" alt="Claude Switch: the accounts window and the menu bar panel">
</picture>

</div>

## Why Claude Switch

Claude Desktop signs in to one account at a time. If you use a personal and a work account, or several plans for different projects, changing accounts means signing out, signing in again and losing track of how much quota each one has left.

Claude Switch keeps every login you use on your Mac, encrypted, and swaps them for you. It is a native macOS menu bar app with no third-party dependencies.

## Features

- **Switch without signing in again.** Choose a saved account and confirm. Claude quits normally, the login is restored, and Claude reopens.
- **Know what is left.** Session, weekly and model-specific limits come directly from Claude online, with reset times and the last update. Automatic refresh follows conversation activity and pauses when Claude closes.
- **Find an account with room.** Accounts are ranked using their plan, remaining quota and confirmed reset times. The current account stays pinned; old readings never trigger a recommendation.
- **Get a timely reminder.** A menu bar marker and optional macOS notifications point to a recommended account. Review the switch and any followed conversations before confirming.
- **Keep your Code conversations.** Move, copy or follow local Claude Code sessions, including their modes, worktrees and preferences. After adding an account, a separate preview lets you bring followed sessions over.
- **Add accounts without signing out.** Open Claude's sign-in screen while preserving the previous login. The new account is saved automatically once you sign in.
- **See your local usage.** Token totals, models, an activity heatmap, streaks and daily charts. Usage statistics are separate from subscription quota.
- **Stay in control.** Logins are encrypted on your Mac. Switches and transfers are journaled for recovery; account data and conversations are never sent to our own servers. See [How it works](docs/how-it-works.md).
- **Made for macOS.** SwiftUI, light and dark mode, keyboard shortcuts, 10 languages, and a built-in version checker with manual installation.

## Screenshots

<table>
  <tr>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/conversations-dark.png">
        <img src="docs/images/conversations-light.png" alt="Conversations: move, copy and follow Claude Code sessions">
      </picture>
      <p align="center"><b>Conversations</b> · move, copy or follow sessions across accounts</p>
    </td>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/usage-dark.png">
        <img src="docs/images/usage-light.png" alt="Usage statistics with an activity heatmap and daily tokens per model">
      </picture>
      <p align="center"><b>Usage</b> · tokens, models, heatmap and streaks</p>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/switch-reminder-menu-en.png" width="330" alt="Switch reminders">
      <p><b>Switch reminders</b> · review an account with quota before switching</p>
    </td>
    <td width="50%">
      <img src="docs/images/new-account-follow-confirm-en.png" alt="Bring conversations along">
      <p><b>Bring conversations along</b> · confirm moves and copies after adding an account</p>
    </td>
  </tr>
</table>

<sub>All screenshots use built-in sample data, rendered with <code>scripts/screenshots.sh</code>.</sub>

## Install

**Requirements:** macOS 14 Sonoma or later (Apple silicon or Intel) and [Claude Desktop](https://claude.ai/download).

1. Download `ClaudeSwitch-<version>-macOS.zip` from the [latest release](https://github.com/uiuing/claude-desktop-switch/releases/latest).
2. Unzip it and move **Claude Switch** to your Applications folder.
3. Open it. The app is not notarized by Apple yet, so the first launch needs one extra step:
   - macOS 15 and later: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   - macOS 14: right-click the app, choose **Open**, then confirm.

   Or remove the download quarantine flag in Terminal:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Claude Switch.app"
   ```

Each release lists a SHA-256 checksum next to the download if you want to verify it.

### Updates

Claude Switch checks GitHub for a new version at most once per day while open. Use **Settings → Updates** to check manually or turn automatic checks off. **View latest version** opens the [release page](https://github.com/uiuing/claude-desktop-switch/releases/latest); download and installation are manual.

Quit Claude Switch before replacing it in Applications. On launch, choose **Allow access** if shown, then approve the macOS dialogs for **Claude Safe Storage** and **Claude Switch · Saved Logins**. Choose **Always Allow** to remember access for this app build.

## Getting started

1. **Sign in to Claude Desktop** as usual, then open Claude Switch and allow Keychain access when asked. The signed-in account is saved automatically.
2. **Add another account** with **Add account…** in the menu bar. Claude restarts at its sign-in screen; sign in with the other account and it is saved too.
3. **Switch** from the menu bar or the Accounts window whenever you like.


You can enable switch recommendations and operation-result notifications during setup or later in **Settings → Notifications**. Every switch still requires confirmation.

> [!IMPORTANT]
> To change accounts, use Claude Switch rather than Claude's **Log out** or Claude Code's `/login`.
> Signing out revokes that login on Anthropic's side, and the copy Claude Switch saved stops working.
> If Claude cannot restore the login, sign in once more and it is saved again.

Handy shortcuts in the main window: `⌘1` `⌘2` `⌘3` switch pages, `⌘K` searches accounts and sessions, `⌘R` refreshes local accounts and conversations. Use each account’s refresh button for quota.

## Privacy and security

- **Everything stays on your Mac.** Saved logins are encrypted with AES-256-GCM. The key lives in your login Keychain and is never synced to iCloud, so a copy of the saved logins alone can't be read.
- **No telemetry, no analytics, no servers of our own.**
- **Limited network access.** Account and quota queries go to Anthropic; version checks read public GitHub release metadata. Both automatic features can be disabled. Version checks send no account data, and local conversations are never uploaded.
- **A narrow footprint.** Only Claude Desktop's login files are swapped. Claude Code's own login, your projects, MCP servers, skills and settings are left alone.
- **Recoverable.** Every switch is journaled; if something interrupts it, Claude Switch can restore the previous state.

Details: [How it works](docs/how-it-works.md) · [Quota and usage data](docs/usage-data.md) · [Security policy](.github/SECURITY.md)

## FAQ

<details>
<summary><b>Why does macOS ask to let Claude Switch use "Claude Safe Storage"?</b></summary>

Claude encrypts its login tokens with a key stored in that Keychain item. Claude Switch only needs it to read the selected account's current limits online, and only asks when you choose **Allow access** or refresh quota yourself. One approval is shared across accounts; affected accounts retry automatically. Access is checked at startup; the app opens after authorization. Choose **Always Allow** to avoid prompts after restarting.
</details>

<details>
<summary><b>Does it switch the Claude Code CLI too?</b></summary>

No. Claude Switch switches Claude Desktop. The Claude Code command-line tool keeps its own separate login.
</details>

<details>
<summary><b>Why do some accounts show "—" or an older reading?</b></summary>

A failed refresh keeps the last successful reading and its timestamp; “—” means no reading is available yet. If the saved access token has expired, switch to that account and let Claude update its login.
</details>

<details>
<summary><b>Can I move my saved accounts to another Mac?</b></summary>

Not by copying files: the saved logins can only be read with the key in this Mac's login Keychain. Migration Assistant, or restoring a backup of your whole user account, brings that Keychain along, so saved accounts may keep working. Otherwise, sign in to each account once on the new Mac and it is saved again.
</details>

<details>
<summary><b>Will a Claude Desktop update break it?</b></summary>

Claude Switch relies on Claude Desktop's local file formats, which are not a public API. When it meets a format it does not recognize, it stops instead of guessing, and nothing is changed. Please [open an issue](https://github.com/uiuing/claude-desktop-switch/issues/new/choose) if that happens.
</details>

## Build from source

You need Xcode 16 or later (Swift 6 toolchain).

```sh
git clone https://github.com/uiuing/claude-desktop-switch.git
cd claude-desktop-switch
swift test                               # unit tests
zsh scripts/build.sh                     # builds "dist/Claude Switch.app"
open "dist/Claude Switch.app" --args --demo   # try it with sample data
```

`scripts/build.sh --read-only` builds a version that can show everything but never changes Claude's files. See [Architecture](docs/architecture.md) and [Contributing](.github/CONTRIBUTING.md) for more.

## Languages

English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch, Português (Brasil) and Русский. The app follows your macOS language and can be changed in Settings. Translation fixes are very welcome.

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING](.github/CONTRIBUTING.md) first, and report security issues privately as described in the [security policy](.github/SECURITY.md).

Working with Claude Code or another AI assistant? [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md) give it the project's rules, commands and slash commands, and [docs/claude-internals.md](docs/claude-internals.md) documents the Claude Desktop and Claude Code formats this app depends on.

## License

[MIT](LICENSE)

Claude Switch is an independent open-source project. It is not affiliated with, endorsed by or sponsored by Anthropic. Claude and Claude Desktop are trademarks of Anthropic, PBC. Use it only with accounts you are allowed to use, and in line with Anthropic's terms.
