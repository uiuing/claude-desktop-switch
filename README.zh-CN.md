<div align="center">

<img src="docs/images/icon.png?v=0.2.0-2" width="112" alt="Claude Switch 图标">

# Claude Switch

**换个账号，接着做事。**

常用 Claude Desktop 账号和剩余额度，都在 Mac 菜单栏里。切换账号时，也能带上需要继续的 Code 会话。

[![最新版本](https://img.shields.io/badge/Download-latest_release-C9653F?style=flat-square)](https://github.com/uiuing/claude-desktop-switch/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square&logo=apple)
[![License: MIT](https://img.shields.io/badge/license-MIT-3B82F6?style=flat-square)](LICENSE)

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-zh-Hans-dark.jpg?v=0.2.0-2">
  <img src="docs/images/hero-zh-Hans-light.jpg?v=0.2.0-2" alt="Claude Switch：账号窗口与菜单栏面板">
</picture>

</div>

## 为什么需要它

个人账号、工作账号来回用，不该总是卡在重新登录、查看额度和找回会话上。Claude Switch 帮你保存常用账号，看清哪个还有余量，换号后也能接着处理本地 Code 会话。

## 功能

- **切换不用重新登录**：常用账号保存一次，之后直接从菜单栏选择需要的账号。
- **剩余额度一眼看清**：把各个账号的余量放在一起，不用来回切换着查。
- **额度不足，及时提醒**：快用完时，有合适的备用账号就会提醒你，让你决定要不要切换。
- **换账号，会话跟着走**：移动或复制本地 Claude Code 会话，也可以让指定会话每次切换时自动跟随。
- **添加账号，不丢原来的登录**：新账号登录后一起保存，需要时随时切回来。
- **看看自己的使用习惯**：查看本地 Code 的每日用量、常用模型和活跃趋势。

## 截图

**额度不足，及时提醒。**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/switch-reminder-menu-zh-Hans-dark.png?v=0.2.0-2">
  <img src="docs/images/switch-reminder-menu-zh-Hans-light.png?v=0.2.0-2" width="330" alt="额度不足，及时提醒。">
</picture>

**换账号，会话跟着走。**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/conversations-zh-Hans-dark.png?v=0.2.0-2">
  <img src="docs/images/conversations-zh-Hans-light.png?v=0.2.0-2" alt="换账号，会话跟着走。">
</picture>

**看看自己的使用习惯。**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/usage-zh-Hans-dark.png?v=0.2.0-2">
  <img src="docs/images/usage-zh-Hans-light.png?v=0.2.0-2" alt="看看自己的使用习惯。">
</picture>

<sub>所有截图均使用虚构的示例数据。</sub>

## 安装

**系统要求**：macOS 14 Sonoma 或更新版本（Apple 芯片或 Intel 均可），并已安装 [Claude Desktop](https://claude.ai/download)。

1. 从 [最新版本](https://github.com/uiuing/claude-desktop-switch/releases/latest) 下载 `ClaudeSwitch-<版本号>-macOS.zip`。
2. 解压后把 **Claude Switch** 拖到「应用程序」文件夹。
3. 打开它。应用暂未经过 Apple 公证，第一次打开需要多一步：
   - macOS 15 及以上：打开 **系统设置 → 隐私与安全性**，向下滚动，点 **仍要打开**。
   - macOS 14：右键点应用，选 **打开**，再确认一次。

   也可以在终端里移除下载隔离标记：

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Claude Switch.app"
   ```

每个版本的下载旁都附有 SHA-256 校验值，可用于核对文件。

### 更新

在 **设置 → 版本更新** 中检查新版本，或关闭自动检查。点击 **查看最新版本** 前往 [下载页](https://github.com/uiuing/claude-desktop-switch/releases/latest)，下载与安装由你手动完成。

替换「应用程序」中的旧版前，先退出 Claude Switch。启动时如果出现授权提示，点击 **允许访问**，再确认 macOS 对话框。选择 **始终允许** 可减少重复询问。

## 快速上手

1. 像平常一样**登录 Claude Desktop**，然后打开 Claude Switch，按提示允许访问钥匙串，当前账号会被自动保存。
2. 在菜单栏点 **添加账号…**。Claude 会重启到登录页，用另一个账号登录，它也会被自动保存。
3. 之后随时在菜单栏或账号窗口里**切换**。

可在首次设置或 **设置 → 通知** 中开启切换推荐和操作结果通知。每次切换仍需你确认。

> [!IMPORTANT]
> 换账号请用 Claude Switch，不要用 Claude 里的 **退出登录** 或 Claude Code 的 `/login`。
> 退出登录会让这个登录在 Anthropic 那边失效，Claude Switch 保存的副本也就不能用了。
> 如果 Claude 无法恢复登录，在 Claude 里重新登录一次即可重新保存。

主窗口快捷键：`⌘1` `⌘2` `⌘3` 切换页面，`⌘K` 搜索账号和会话，`⌘R` 刷新本地账号和会话；额度使用各账号卡片上的刷新按钮。

## 隐私与安全

- 保存的登录在 Mac 上加密，由登录钥匙串保护。
- 没有遥测、追踪或自建服务器，也不上传本地会话。
- 额度查询连接 Anthropic，版本检查连接 GitHub；两项自动检查都可关闭。
- 切换中断时可在设置中恢复。你的项目和 Claude Code 命令行登录不会被改动。

详细说明（英文）：[工作原理](docs/how-it-works.md) · [额度与用量数据](docs/usage-data.md) · [安全策略](.github/SECURITY.md)

## 常见问题

<details>
<summary><b>为什么 macOS 会询问是否允许 Claude Switch 使用「Claude Safe Storage」？</b></summary>

Claude Switch 需要这项权限来显示账号额度，另一项权限用于保护保存的登录。点击 **允许访问** 后，在 macOS 对话框中确认；选择 **始终允许** 可减少重复询问。
</details>

<details>
<summary><b>会同时切换 Claude Code 命令行吗？</b></summary>

不会。Claude Switch 切换的是 Claude Desktop；Claude Code 命令行工具有自己独立的登录。
</details>

<details>
<summary><b>为什么有的账号显示「—」或者较早的额度数据？</b></summary>

「—」表示暂时没有可用的额度信息。如果一直无法更新，请切换到这个账号，确认在 Claude 中已登录，再刷新一次。
</details>

<details>
<summary><b>能把保存的账号迁移到另一台 Mac 吗？</b></summary>

在新 Mac 上重新登录各个账号，就能再次保存。通过 macOS 迁移助理完整迁移时，原来保存的登录也可能继续使用。
</details>

<details>
<summary><b>Claude Desktop 更新后会不会失效？</b></summary>

Claude Desktop 更新后，偶尔也需要同步更新 Claude Switch。如果无法切换，请先检查新版，或 [提交 Issue](https://github.com/uiuing/claude-desktop-switch/issues/new/choose)。
</details>

## 从源码构建

需要 Xcode 16 或更新版本（Swift 6 工具链）。

```sh
git clone https://github.com/uiuing/claude-desktop-switch.git
cd claude-desktop-switch
swift test                               # 单元测试
zsh scripts/build.sh                     # 生成 "dist/Claude Switch.app"
open "dist/Claude Switch.app" --args --demo   # 用示例数据体验
```

`scripts/build.sh --read-only` 会构建一个只能查看、永远不会改动 Claude 文件的版本。更多内容见 [架构说明](docs/architecture.md) 和 [贡献指南](.github/CONTRIBUTING.md)（英文）。

## 界面语言

English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch、Português (Brasil)、Русский。默认跟随 macOS 语言，也可以在设置里更改。欢迎帮忙改进翻译。

## 参与贡献

欢迎提交 Bug、建议和 Pull Request。提交前请先阅读 [贡献指南](.github/CONTRIBUTING.md)；安全问题请按 [安全策略](.github/SECURITY.md) 私下报告。

如果你用 Claude Code 或其他 AI 编程助手开发：[AGENTS.md](AGENTS.md) 和 [CLAUDE.md](CLAUDE.md) 提供了项目规则、常用命令和斜杠命令，[docs/claude-internals.md](docs/claude-internals.md) 记录了本项目依赖的 Claude Desktop 与 Claude Code 本地数据格式（英文）。

## 许可证

[MIT](LICENSE)

Claude Switch 是独立的开源项目，与 Anthropic 没有任何隶属、背书或赞助关系。Claude 与 Claude Desktop 是 Anthropic, PBC 的商标。请只在你有权使用的账号上使用，并遵守 Anthropic 的相关条款。
