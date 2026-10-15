<div align="center">

<img src="docs/images/icon.png" width="112" alt="Claude Switch 圖示">

# Claude Switch

**在 Mac 選單列管理所有 Claude Desktop 帳號，一鍵切換。**

每個帳號登入一次就會保存，之後隨時秒切；每個帳號的 5 小時額度與週額度一目瞭然。

[![最新版本](https://img.shields.io/github/v/release/uiuing/claude-desktop-switch?style=flat-square&color=C9653F&label=release)](https://github.com/uiuing/claude-desktop-switch/releases/latest)
[![下載次數](https://img.shields.io/github/downloads/uiuing/claude-desktop-switch/total?style=flat-square&color=C9653F)](https://github.com/uiuing/claude-desktop-switch/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square&logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-3B82F6?style=flat-square)](LICENSE)

[English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-zh-Hant-dark.jpg">
  <img src="docs/images/hero-zh-Hant-light.jpg" alt="Claude Switch：帳號視窗與選單列面板">
</picture>

</div>

## 為什麼需要它

Claude Desktop 同一時間只能登入一個帳號。如果你同時有個人帳號和工作帳號，或不同專案使用不同方案，換帳號就得登出、再登入，也很難記住每個帳號還剩多少額度。

Claude Switch 會把你用到的每個登入加密保存在本機，並替你完成切換。它是原生 macOS 選單列 App，沒有第三方相依套件。

## 功能

- **一鍵切換**：在選單列選一個帳號，Claude 會正常結束、換上保存的登入，再自動開啟並維持登入狀態。
- **額度一目瞭然**：從線上取得 **5 小時額度**、**週額度** 與重置時間，支援依模型區分的週額度。
- **自動更新**：目前帳號依對話活動調整頻率，其他帳號預設每 30 分鐘更新；可在設定中調整，Claude 結束後暫停。
- **智慧推薦**：目前帳號額度快用完時，選單列會標出仍有餘裕的已保存帳號。
- **新增帳號不必登出**：「新增帳號」會先把目前的登入移到一旁，讓 Claude 回到登入頁；原帳號在伺服器端不會被登出，之後照常可用。
- **Claude Code 工作階段跟著走**：把本機的 Claude Code 工作階段移動或複製到其他帳號，也能讓指定的工作階段在每次切換時自動跟隨。
- **用量統計**：Token、模型、活躍熱度圖、連續天數與每日圖表，統計方式與 Claude Desktop 內建的統計一致。
- **安全設計**：加密快照、嚴格的檔案白名單、可回復的操作日誌。詳見 [運作原理](docs/how-it-works.md)（英文）。
- **原生 macOS 體驗**：SwiftUI、淺色／深色模式、快速鍵，支援 10 種介面語言。

## 截圖

<table>
  <tr>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/conversations-dark.png">
        <img src="docs/images/conversations-light.png" alt="對話：移動、複製或跟隨 Claude Code 工作階段">
      </picture>
      <p align="center"><b>對話</b> · 在帳號之間移動、複製或跟隨工作階段</p>
    </td>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/usage-dark.png">
        <img src="docs/images/usage-light.png" alt="用量統計：活躍熱度圖與各模型的每日 Token">
      </picture>
      <p align="center"><b>用量</b> · Token、模型、熱度圖與連續天數</p>
    </td>
  </tr>
</table>

<sub>所有截圖皆使用內建範例資料，由 <code>scripts/screenshots.sh</code> 產生。</sub>

## 安裝

**系統需求**：macOS 14 Sonoma 或更新版本（Apple 晶片或 Intel 皆可），並已安裝 [Claude Desktop](https://claude.ai/download)。

1. 從 [最新版本](https://github.com/uiuing/claude-desktop-switch/releases/latest) 下載 `ClaudeSwitch-<版本>-macOS.zip`。
2. 解壓縮後把 **Claude Switch** 拖到「應用程式」資料夾。
3. 開啟它。App 尚未經過 Apple 公證，第一次開啟需要多一個步驟：
   - macOS 15 及以上：開啟 **系統設定 → 隱私權與安全性**，往下捲動，按 **強制打開**。
   - macOS 14：在 App 上按右鍵，選 **打開**，再確認一次。

   也可以在終端機移除下載隔離標記：

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Claude Switch.app"
   ```

每個版本的下載旁都附有 SHA-256 檢查碼，可用來核對檔案。

### 更新

Claude Switch **目前還沒有遠端更新或自動更新**。想第一時間得知新版本，請在本儲存庫按 **Watch → Custom → Releases**，或關注 [Releases](https://github.com/uiuing/claude-desktop-switch/releases) 頁面。取代「應用程式」中的舊版前，請先結束 Claude Switch；已保存的帳號仍保留在本機。啟動時若顯示授權頁面，按 **允許存取**，再於 macOS 鑰匙圈對話框中允許存取 **Claude Safe Storage**。更新後，macOS 也可能詢問是否允許存取 Claude Switch 自己的加密金鑰；這些項目均可選擇 **永遠允許**。

從 0.1.0 升級時，會移除舊的本機推估額度；帳號可能暫時顯示 **—**，直到下一次成功在線上更新。已保存的登入和對話不受影響。

## 快速上手

1. 像平常一樣**登入 Claude Desktop**，然後開啟 Claude Switch，依提示允許存取鑰匙圈，目前的帳號會自動保存。
2. 在選單列按 **新增帳號…**。Claude 會重新啟動到登入頁，用另一個帳號登入，它也會自動保存。
3. 之後隨時在選單列或帳號視窗中**切換**。

> [!IMPORTANT]
> 換帳號請使用 Claude Switch，不要用 Claude 裡的 **登出** 或 Claude Code 的 `/login`。
> 登出會讓這個登入在 Anthropic 那端失效，Claude Switch 保存的副本也就無法使用。
> 如果 Claude 無法恢復登入，在 Claude 裡重新登入一次即可再次保存。

主視窗快速鍵：`⌘1` `⌘2` `⌘3` 切換頁面，`⌘K` 搜尋帳號與對話，`⌘R` 更新本機帳號與對話；額度使用各帳號卡片上的更新按鈕。

## 隱私與安全

- **資料只留在你的 Mac**：保存的登入以 AES-256-GCM 加密，金鑰存放在登入鑰匙圈中，不會同步到 iCloud，單獨複製保存的登入也無法讀取。
- **沒有遙測、沒有統計、沒有我們自己的伺服器。**
- **有限的連網行為**：僅向 Anthropic 查詢帳號與額度，可關閉自動更新，不上傳本機對話。
- **影響範圍很小**：只替換 Claude Desktop 的登入檔案；Claude Code 本身的登入、你的專案、MCP 伺服器、Skills 與設定都不會動到。
- **可以回復**：每次切換都有操作日誌，中途被打斷時可以回復到切換前的狀態。

詳細說明（英文）：[運作原理](docs/how-it-works.md) · [額度與用量資料](docs/usage-data.md) · [安全政策](.github/SECURITY.md)

## 常見問題

<details>
<summary><b>為什麼 macOS 會詢問是否允許 Claude Switch 使用「Claude Safe Storage」？</b></summary>

Claude 用這個鑰匙圈項目中的金鑰加密登入權杖。Claude Switch 只有在線上讀取所選帳號的額度時才需要它，只在你按 **允許存取** 或手動更新額度時詢問。一次授權供所有帳號使用，受影響的帳號會自動重試。啟動時會先檢查權限，授權後才能進入。選 **永遠允許** 可避免重新啟動後重複詢問。
</details>

<details>
<summary><b>會一起切換 Claude Code 命令列嗎？</b></summary>

不會。Claude Switch 切換的是 Claude Desktop；Claude Code 命令列工具有自己獨立的登入。
</details>

<details>
<summary><b>為什麼有些帳號顯示「—」或較早的額度資料？</b></summary>

更新失敗時保留上次成功的額度資料與時間；「—」表示尚無可用額度資料。若保存的存取權杖已過期，請切換到該帳號，讓 Claude 更新登入憑證。
</details>

<details>
<summary><b>可以把保存的帳號搬到另一台 Mac 嗎？</b></summary>

單獨複製檔案不行：保存的登入只能用這台 Mac 登入鑰匙圈裡的金鑰讀取。用移轉輔助程式或從備份完整還原使用者帳號時，鑰匙圈會一起移轉，保存的帳號可能可以繼續使用。否則在新的 Mac 上把每個帳號登入一次，就會重新保存。
</details>

<details>
<summary><b>Claude Desktop 更新後會不會失效？</b></summary>

Claude Switch 依賴 Claude Desktop 的本機檔案格式，這並非公開 API。遇到無法辨識的格式時，它會停下來而不是猜測，也不會改動任何東西。若遇到這種情況，歡迎 [回報 Issue](https://github.com/uiuing/claude-desktop-switch/issues/new/choose)。
</details>

## 從原始碼建置

需要 Xcode 16 或更新版本（Swift 6 工具鏈）。

```sh
git clone https://github.com/uiuing/claude-desktop-switch.git
cd claude-desktop-switch
swift test                               # 單元測試
zsh scripts/build.sh                     # 產生 "dist/Claude Switch.app"
open "dist/Claude Switch.app" --args --demo   # 用範例資料試用
```

`scripts/build.sh --read-only` 會建置一個只能檢視、永遠不會改動 Claude 檔案的版本。更多內容請見 [架構說明](docs/architecture.md) 與 [貢獻指南](.github/CONTRIBUTING.md)（英文）。

## 介面語言

English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch、Português (Brasil)、Русский。預設跟隨 macOS 語言，也可以在設定中更改。歡迎協助改進翻譯。

## 參與貢獻

歡迎回報 Bug、提出建議與送出 Pull Request。送出前請先閱讀 [貢獻指南](.github/CONTRIBUTING.md)；安全問題請依 [安全政策](.github/SECURITY.md) 私下回報。

如果你使用 Claude Code 或其他 AI 程式設計助手開發：[AGENTS.md](AGENTS.md) 與 [CLAUDE.md](CLAUDE.md) 提供專案規則、常用指令與斜線指令，[docs/claude-internals.md](docs/claude-internals.md) 記錄了本專案依賴的 Claude Desktop 與 Claude Code 本機資料格式（英文）。

## 授權

[MIT](LICENSE)

Claude Switch 是獨立的開源專案，與 Anthropic 沒有任何隸屬、背書或贊助關係。Claude 與 Claude Desktop 是 Anthropic, PBC 的商標。請只在你有權使用的帳號上使用，並遵守 Anthropic 的相關條款。
