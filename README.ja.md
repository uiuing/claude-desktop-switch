<div align="center">

<img src="docs/images/icon.png?v=0.2.0" width="112" alt="Claude Switch アイコン">

# Claude Switch

**Claude Desktop のすべてのアカウントを、Mac のメニューバーからワンクリックで。**

ログインを保存し、残りの使用量を確認。アカウントを切り替えても、ローカルの Code セッションを引き継げます。

[![最新リリース](https://img.shields.io/badge/Download-latest_release-C9653F?style=flat-square)](https://github.com/uiuing/claude-desktop-switch/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?style=flat-square&logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-3B82F6?style=flat-square)](LICENSE)

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **日本語**

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-ja-dark.jpg?v=0.2.0">
  <img src="docs/images/hero-ja-light.jpg?v=0.2.0" alt="Claude Switch：アカウントウインドウとメニューバーのパネル">
</picture>

</div>

## Claude Switch とは

Claude Desktop は一度に 1 つのアカウントにしかサインインできません。個人用と仕事用のアカウントを使い分けたり、プロジェクトごとに別のプランを使ったりしていると、切り替えのたびにサインアウトとサインインが必要で、各アカウントの残り使用量も把握しにくくなります。

Claude Switch は、使っているログインを暗号化して Mac に保存し、切り替えを代わりに行います。サードパーティの依存関係がない、macOS ネイティブのメニューバーアプリです。

## 主な機能

- **再ログインせずに切り替え**：保存済みのアカウントを選んで確認すると、Claude を通常どおり終了し、ログインを復元して再び開きます。
- **残りの使用量をひと目で確認**：セッション、週間、モデル別の上限をオンラインで取得し、リセット時刻と最終更新を表示。会話の動きに合わせて自動更新し、Claude の終了中は停止します。
- **余裕のあるアカウントを見つける**：プラン、残りの使用量、確認済みのリセット時刻で並び替えます。現在のアカウントは先頭に固定し、古いデータで切り替えを勧めません。
- **必要なときにお知らせ**：メニューバーのマークと任意の macOS 通知でおすすめを表示。アカウントと追従するセッションを確認してから切り替えます。
- **Code セッションも一緒に**：ローカルの Claude Code セッションを移動・コピー・追従し、モード、ワークツリー、設定を保持します。アカウント追加後も、別のプレビューで追従セッションの転送を確認できます。
- **サインアウトせずに追加**：元のログインを保存したまま Claude のサインイン画面を開き、新しいアカウントへのサインインが完了すると自動保存します。
- **ローカルの使用状況を確認**：トークン数、モデル、ヒートマップ、連続日数、日別グラフ。使用統計とサブスクリプションの上限は別々に表示します。
- **データは自分の Mac で管理**：ログインは暗号化して保存し、切り替えや転送には復元用の操作ログを残します。アカウントや会話を受け取る独自サーバーはありません。[仕組み](docs/how-it-works.md)（英語）もご覧ください。
- **macOS になじむ使い心地**：SwiftUI、ライト／ダークモード、ショートカット、10 言語に対応。バージョン確認を内蔵し、ダウンロードとインストールは手動で行います。

## スクリーンショット

<table>
  <tr>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/conversations-dark.png?v=0.2.0">
        <img src="docs/images/conversations-light.png?v=0.2.0" alt="会話：Claude Code セッションの移動・コピー・追従">
      </picture>
      <p align="center"><b>会話</b> · アカウント間でセッションを移動・コピー・追従</p>
    </td>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/usage-dark.png?v=0.2.0">
        <img src="docs/images/usage-light.png?v=0.2.0" alt="使用量の統計：ヒートマップとモデル別の日別トークン">
      </picture>
      <p align="center"><b>使用量</b> · トークン、モデル、ヒートマップ、連続日数</p>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/switch-reminder-menu-ja.png?v=0.2.0" width="330" alt="切り替えのおすすめ">
      <p><b>切り替えのおすすめ</b> · 残りの使用量を確認してから切り替え</p>
    </td>
    <td width="50%">
      <img src="docs/images/new-account-follow-confirm-ja.png?v=0.2.0" alt="セッションを引き継ぐ">
      <p><b>セッションを引き継ぐ</b> · アカウント追加後に移動・コピーを確認</p>
    </td>
  </tr>
</table>

<sub>スクリーンショットはすべて内蔵のサンプルデータを使い、<code>scripts/screenshots.sh</code> で生成しています。</sub>

## インストール

**動作環境**：macOS 14 Sonoma 以降（Apple シリコン／Intel）、[Claude Desktop](https://claude.ai/download) がインストール済みであること。

1. [最新リリース](https://github.com/uiuing/claude-desktop-switch/releases/latest) から `ClaudeSwitch-<バージョン>-macOS.zip` をダウンロードします。
2. 解凍して **Claude Switch** を「アプリケーション」フォルダに移動します。
3. 起動します。まだ Apple の公証を受けていないため、初回のみ次の操作が必要です。
   - macOS 15 以降：**システム設定 → プライバシーとセキュリティ** を開き、下にスクロールして **このまま開く** をクリックします。
   - macOS 14：アプリを右クリックして **開く** を選び、確認します。

   ターミナルでダウンロード時の隔離属性を外すこともできます。

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Claude Switch.app"
   ```

各リリースのダウンロードには SHA-256 チェックサムを添えています。

### アップデート

Claude Switch は起動中に 1 日 1 回まで GitHub の新しいバージョンを確認します。**設定 → アップデート** で手動確認や自動確認の無効化ができます。**最新バージョンを見る** から [リリースページ](https://github.com/uiuing/claude-desktop-switch/releases/latest) を開き、手動でダウンロードしてインストールしてください。

「アプリケーション」内の旧版を置き換える前に Claude Switch を終了してください。起動時に許可画面が表示されたら **アクセスを許可** を選び、macOS のダイアログで **Claude Safe Storage** と **Claude Switch · 保存済みログイン** へのアクセスを許可します。**常に許可** を選ぶと、現在のアプリビルドへの許可を記憶します。

## はじめかた

1. いつもどおり **Claude Desktop にサインイン** してから Claude Switch を開き、求められたらキーチェーンへのアクセスを許可します。そのアカウントが自動で保存されます。
2. メニューバーの **アカウントを追加…** をクリックします。Claude がサインイン画面で再起動するので、別のアカウントでサインインすると、そちらも自動で保存されます。
3. あとはメニューバーやアカウントウインドウから、いつでも **切り替え** できます。


初回設定または **設定 → 通知** で、切り替えのおすすめと操作結果の通知を有効にできます。切り替えには毎回確認が必要です。

> [!IMPORTANT]
> アカウントの切り替えには Claude Switch を使い、Claude の **ログアウト** や Claude Code の `/login` は使わないでください。
> サインアウトすると Anthropic 側でそのログインが無効になり、Claude Switch が保存したコピーも使えなくなります。
> Claude がログインを復元できない場合は、もう一度サインインすれば再び保存されます。

メインウインドウのショートカット：`⌘1` `⌘2` `⌘3` でページ切り替え、`⌘K` でアカウントと会話を検索、`⌘R` でローカルのアカウントと会話を更新。使用量は各アカウントの更新ボタンから取得できます。

## プライバシーとセキュリティ

- **データは Mac の中だけに**：保存したログインは AES-256-GCM で暗号化され、鍵はログインキーチェーンに保管されます。iCloud には同期されず、保存したログインだけをコピーしても読み取れません。
- **テレメトリ、解析、独自サーバーは一切ありません。**
- **通信を最小限に**：アカウントと使用上限は Anthropic に、公開バージョン情報は GitHub に問い合わせます。どちらの自動確認も無効にできます。バージョン確認でアカウント情報を送信せず、ローカルの会話をアップロードしません。
- **影響範囲は最小限**：入れ替えるのは Claude Desktop のログインファイルだけです。Claude Code 自身のログイン、プロジェクト、MCP サーバー、スキル、設定には触れません。
- **元に戻せる**：切り替えはすべて記録され、途中で中断しても切り替え前の状態に戻せます。

詳細（英語）：[仕組み](docs/how-it-works.md) · [上限と使用量のデータ](docs/usage-data.md) · [セキュリティポリシー](.github/SECURITY.md)

## よくある質問

<details>
<summary><b>macOS が「Claude Safe Storage」の使用許可を求めてくるのはなぜですか？</b></summary>

Claude はこのキーチェーン項目の鍵でログイントークンを暗号化しています。Claude Switch がこれを使うのは、選択したアカウントの上限をオンラインで読み込むときだけで、確認は「アクセスを許可」または使用量の更新を選んだときだけ表示されます。一度の許可をアカウント間で共有し、待機中のアカウントは自動で再試行します。起動時にアクセス権を確認し、許可後にアプリを利用できます。**常に許可** を選ぶと再起動後の確認を減らせます。
</details>

<details>
<summary><b>Claude Code の CLI も切り替わりますか？</b></summary>

いいえ。Claude Switch が切り替えるのは Claude Desktop です。Claude Code のコマンドラインツールは独自のログインを持ち続けます。
</details>

<details>
<summary><b>「—」や古い数値が表示されるアカウントがあるのはなぜですか？</b></summary>

更新に失敗した場合は、最後に取得できた値と時刻を保持します。「—」はまだ値がないことを示します。保存済みトークンの期限切れ時は、そのアカウントに切り替えて Claude にログインを更新させてください。
</details>

<details>
<summary><b>保存したアカウントを別の Mac に移せますか？</b></summary>

ファイルをコピーするだけでは移せません。保存したログインは、この Mac のログインキーチェーンにある鍵でしか読み取れないためです。移行アシスタントやバックアップからユーザアカウントごと復元した場合はキーチェーンも引き継がれるため、保存したアカウントをそのまま使えることがあります。そうでなければ、新しい Mac で各アカウントに一度サインインすれば再び保存されます。
</details>

<details>
<summary><b>Claude Desktop のアップデートで動かなくなりませんか？</b></summary>

Claude Switch は Claude Desktop のローカルファイル形式に依存しており、これは公開 API ではありません。認識できない形式を見つけた場合は推測せずに停止し、何も変更しません。そのような場合は [Issue](https://github.com/uiuing/claude-desktop-switch/issues/new/choose) でお知らせください。
</details>

## ソースからビルド

Xcode 16 以降（Swift 6 ツールチェーン）が必要です。

```sh
git clone https://github.com/uiuing/claude-desktop-switch.git
cd claude-desktop-switch
swift test                               # ユニットテスト
zsh scripts/build.sh                     # "dist/Claude Switch.app" を作成
open "dist/Claude Switch.app" --args --demo   # サンプルデータで試す
```

`scripts/build.sh --read-only` を使うと、表示はすべてできるものの Claude のファイルを決して変更しないバージョンをビルドできます。詳しくは [アーキテクチャ](docs/architecture.md) と [コントリビューションガイド](.github/CONTRIBUTING.md)（英語）をご覧ください。

## 表示言語

English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch、Português (Brasil)、Русский。macOS の言語に従い、設定から変更することもできます。翻訳の改善も歓迎します。

## コントリビューション

バグ報告、アイデア、プルリクエストを歓迎します。まず [コントリビューションガイド](.github/CONTRIBUTING.md) をお読みください。セキュリティ上の問題は [セキュリティポリシー](.github/SECURITY.md) に従って非公開で報告してください。

Claude Code などの AI コーディングアシスタントを使う場合は、[AGENTS.md](AGENTS.md) と [CLAUDE.md](CLAUDE.md) にプロジェクトのルール、コマンド、スラッシュコマンドをまとめています。このアプリが依存する Claude Desktop と Claude Code のローカルデータ形式は [docs/claude-internals.md](docs/claude-internals.md)（英語）にあります。

## ライセンス

[MIT](LICENSE)

Claude Switch は独立したオープンソースプロジェクトであり、Anthropic とは提携・推奨・後援の関係にありません。Claude および Claude Desktop は Anthropic, PBC の商標です。利用が認められたアカウントでのみ、Anthropic の規約に従ってご利用ください。
