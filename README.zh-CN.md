<div align="center">

<img src="docs/images/icon.png?v=0.2.0" width="112" alt="Claude Switch 图标">

# Claude Switch

**在 Mac 菜单栏里管理所有 Claude Desktop 账号，一键切换。**

保存登录、查看剩余额度，切换账号时也能带上本地 Code 会话。

[![最新版本](https://img.shields.io/badge/Download-latest_release-C9653F?style=flat-square)](https://github.com/uiuing/claude-desktop-switch/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square&logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-3B82F6?style=flat-square)](LICENSE)

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-zh-Hans-dark.jpg?v=0.2.0">
  <img src="docs/images/hero-zh-Hans-light.jpg?v=0.2.0" alt="Claude Switch：账号窗口与菜单栏面板">
</picture>

</div>

## 为什么需要它

Claude Desktop 同一时间只能登录一个账号。如果你同时有个人账号和工作账号，或者不同项目用不同套餐，换账号就得退出登录、再登录，还很难记住每个账号还剩多少额度。

Claude Switch 把你用到的每个登录加密保存在本机，并替你完成切换。它是原生 macOS 菜单栏应用，没有第三方依赖。

## 功能

- **切换不用重新登录**：选一个已保存的账号并确认，Claude 会正常退出、恢复登录，再自动打开。
- **剩余额度一目了然**：在线读取 5 小时、每周及模型专属额度，同时显示重置时间和上次更新时间。自动刷新随会话活动调整，Claude 退出后暂停。
- **找到还有余量的账号**：结合套餐、剩余额度与已确认的重置时间排序，当前账号始终置顶；过期数据不会触发推荐。
- **需要时提醒你**：菜单栏标记和可选的 macOS 通知提示推荐账号，确认切换前可以查看账号与跟随的会话。
- **Code 会话跟着走**：移动、复制或跟随本地 Claude Code 会话，保留模式、工作树和偏好设置。添加账号后，也能在单独的预览中确认带入跟随会话。
- **添加账号不用退出登录**：保留原账号的登录，让 Claude 打开登录页；新账号登录完成后自动保存。
- **查看本地用量**：Token 总量、模型、活跃热力图、连续天数和每日图表；用量统计与订阅额度分别展示。
- **数据由你掌握**：登录在本机加密保存，切换与转移都有可恢复的操作日志。没有自建服务器接收账号或会话数据。详见 [工作原理](docs/how-it-works.md)（英文）。
- **原生 macOS 体验**：SwiftUI、浅色与深色模式、快捷键、10 种语言，并内置版本检查，下载与安装由你决定。

## 截图

<table>
  <tr>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/conversations-dark.png?v=0.2.0">
        <img src="docs/images/conversations-light.png?v=0.2.0" alt="会话：移动、复制或跟随 Claude Code 会话">
      </picture>
      <p align="center"><b>会话</b> · 在账号之间移动、复制或跟随会话</p>
    </td>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/usage-dark.png?v=0.2.0">
        <img src="docs/images/usage-light.png?v=0.2.0" alt="用量统计：活跃热力图与按模型的每日 Token">
      </picture>
      <p align="center"><b>用量</b> · Token、模型、热力图与连续天数</p>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/switch-reminder-menu-zh-Hans.png?v=0.2.0" width="330" alt="切换提醒">
      <p><b>切换提醒</b> · 先查看推荐账号的额度，再确认切换</p>
    </td>
    <td width="50%">
      <img src="docs/images/new-account-follow-confirm-zh-Hans.png?v=0.2.0" alt="带上会话">
      <p><b>带上会话</b> · 添加账号后确认移动或复制</p>
    </td>
  </tr>
</table>

<sub>所有截图均使用内置示例数据，由 <code>scripts/screenshots.sh</code> 生成。</sub>

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

Claude Switch 运行时每天最多检查一次 GitHub 新版本。可在 **设置 → 版本更新** 中手动检查或关闭自动检查。**查看最新版本** 打开 [发布页](https://github.com/uiuing/claude-desktop-switch/releases/latest)，下载与安装由你手动完成。

替换「应用程序」中的旧版前，先退出 Claude Switch。启动时若显示授权页面，点击 **允许访问**，再在 macOS 对话框中允许访问 **Claude Safe Storage** 和 **Claude Switch · 已保存的登录**。选择 **始终允许**，可记住对当前应用版本的授权。

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

- **数据只在你的 Mac 上**：保存的登录用 AES-256-GCM 加密，密钥存放在登录钥匙串中，不会同步到 iCloud，单独复制保存的登录也无法读取。
- **没有遥测、没有统计、没有我们自己的服务器。**
- **有限的联网行为**：向 Anthropic 查询账号和额度，向 GitHub 查询公开版本信息，两项自动检查均可关闭。版本检查不发送账号数据，也不上传本地会话。
- **改动范围很小**：只替换 Claude Desktop 的登录文件；Claude Code 自己的登录、你的项目、MCP 服务、Skills 和设置都不会碰。
- **可以恢复**：每次切换都有操作日志，中途被打断时可以恢复到切换前的状态。

详细说明（英文）：[工作原理](docs/how-it-works.md) · [额度与用量数据](docs/usage-data.md) · [安全策略](.github/SECURITY.md)

## 常见问题

<details>
<summary><b>为什么 macOS 会询问是否允许 Claude Switch 使用「Claude Safe Storage」？</b></summary>

Claude 用这个钥匙串项目里的密钥加密登录令牌。Claude Switch 只有在线读取所选账号的额度时才需要它，只在你点击 **允许访问** 或手动刷新额度时询问。一次授权供所有账号使用，受影响的账号会自动重试。启动时会先检查权限，授权后才能进入。选 **始终允许** 可避免重启后的重复询问。
</details>

<details>
<summary><b>会同时切换 Claude Code 命令行吗？</b></summary>

不会。Claude Switch 切换的是 Claude Desktop；Claude Code 命令行工具有自己独立的登录。
</details>

<details>
<summary><b>为什么有的账号显示「—」或者较早的额度数据？</b></summary>

刷新失败时保留上次成功的额度数据和时间；「—」表示尚无可用额度数据。若保存的访问令牌已过期，请切换到该账号，让 Claude 更新登录凭据。
</details>

<details>
<summary><b>能把保存的账号迁移到另一台 Mac 吗？</b></summary>

单独复制文件不行：保存的登录只能用这台 Mac 登录钥匙串里的密钥读取。用迁移助理或从备份完整恢复用户账户时，钥匙串会一起迁移，保存的账号可能可以继续使用。否则在新 Mac 上把每个账号登录一次，就会重新保存。
</details>

<details>
<summary><b>Claude Desktop 更新后会不会失效？</b></summary>

Claude Switch 依赖 Claude Desktop 的本地文件格式，这不是公开 API。遇到无法识别的格式时，它会停下来而不是猜测，也不会改动任何东西。如果遇到这种情况，欢迎 [提交 Issue](https://github.com/uiuing/claude-desktop-switch/issues/new/choose)。
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
