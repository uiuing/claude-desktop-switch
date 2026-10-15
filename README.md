<div align="center">

<img src="docs/images/icon.png?v=0.2.0" width="112" alt="Claude Switch icon">

# Claude Switch

**Switch accounts. Keep your flow.**

Your Claude Desktop accounts and remaining quota, together in your Mac’s menu bar. Bring your Code conversations along when you switch.

[![Latest release](https://img.shields.io/badge/Download-latest_release-C9653F?style=flat-square)](https://github.com/uiuing/claude-desktop-switch/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square&logo=apple)
[![License: MIT](https://img.shields.io/badge/license-MIT-3B82F6?style=flat-square)](LICENSE)

**English** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-en-dark.jpg?v=0.2.0">
  <img src="docs/images/hero-en-light.jpg?v=0.2.0" alt="Claude Switch: the accounts window and the menu bar panel">
</picture>

</div>

## Why Claude Switch

Using personal and work accounts should not mean signing in over and over or finding your place again after a switch. Claude Switch keeps your accounts close at hand, shows which ones have room, and helps you continue your local Code conversations.

## Features

- **Switch without signing in again.** Save your usual accounts once, then choose the one you need from the menu bar.
- **See your quota at a glance.** Compare what is left across your accounts without switching between them.
- **Get a heads-up when you run low.** A reminder points you to a suitable backup account when one is available.
- **Pick up where you left off.** Move or copy local Claude Code conversations between accounts, or choose conversations to follow you when you switch.
- **Add an account, keep the others.** Sign in to another account without signing out of the ones you already saved.
- **Understand your usage.** Look back at your local Code activity, daily usage and most-used models.

## Screenshots

<table>
  <tr>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/conversations-dark.png?v=0.2.0">
        <img src="docs/images/conversations-light.png?v=0.2.0" alt="Conversations: move, copy and follow Claude Code sessions">
      </picture>
      <p align="center"><b>Conversations</b> · continue your work on another account</p>
    </td>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/usage-dark.png?v=0.2.0">
        <img src="docs/images/usage-light.png?v=0.2.0" alt="Usage statistics with an activity heatmap and daily tokens per model">
      </picture>
      <p align="center"><b>Usage</b> · see your activity over time</p>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/switch-reminder-menu-en.png?v=0.2.0" width="330" alt="Switch reminders">
      <p><b>Switch reminders</b> · know when another account can help</p>
    </td>
    <td width="50%">
      <img src="docs/images/new-account-follow-confirm-en.png?v=0.2.0" alt="Bring conversations along">
      <p><b>Bring conversations along</b> · choose what to bring to your new account</p>
    </td>
  </tr>
</table>

<sub>All screenshots use fictional sample data.</sub>

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

Use **Settings → Updates** to check for a new version or turn automatic checks off. **View latest version** opens the [download page](https://github.com/uiuing/claude-desktop-switch/releases/latest). Download and installation are manual.

Quit Claude Switch before replacing it in Applications. If asked on launch, choose **Allow access** and approve the macOS prompts. **Always Allow** helps avoid repeated prompts.

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

- Saved logins are encrypted on your Mac and protected by your login Keychain.
- No telemetry, no tracking, and no servers of our own. Local conversations are never uploaded.
- Quota checks connect to Anthropic; version checks connect to GitHub. Both automatic checks can be turned off.
- Interrupted switches can be recovered from Settings. Your projects and Claude Code CLI login stay untouched.

Details: [How it works](docs/how-it-works.md) · [Quota and usage data](docs/usage-data.md) · [Security policy](.github/SECURITY.md)

## FAQ

<details>
<summary><b>Why does macOS ask to let Claude Switch use "Claude Safe Storage"?</b></summary>

Claude Switch needs this permission to show account quota. A separate permission protects your saved logins. Choose **Allow access** to approve the macOS prompts; **Always Allow** helps avoid being asked again.
</details>

<details>
<summary><b>Does it switch the Claude Code CLI too?</b></summary>

No. Claude Switch switches Claude Desktop. The Claude Code command-line tool keeps its own separate login.
</details>

<details>
<summary><b>Why do some accounts show "—" or an older reading?</b></summary>

“—” means quota is not available yet. If it does not update, switch to that account, check that you are signed in to Claude, and try refreshing again.
</details>

<details>
<summary><b>Can I move my saved accounts to another Mac?</b></summary>

Sign in to each account on the new Mac to save it again. A full transfer with macOS Migration Assistant may also preserve your saved logins.
</details>

<details>
<summary><b>Will a Claude Desktop update break it?</b></summary>

Occasionally, a Claude Desktop update may require an update to Claude Switch too. Check for a newer release, or [report an issue](https://github.com/uiuing/claude-desktop-switch/issues/new/choose) if switching stops working.
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
