---
description: Add a user-facing string to all ten localization catalogs
argument-hint: <English text, with {0}, {1} placeholders if needed>
---

Add this user-facing string: $ARGUMENTS

1. Decide the key. Use the English text itself, unless the same English word already exists with a different meaning; then use a dotted key such as `quota.session` or `analytics.messageCount`.
2. Add the key to every file in `Sources/SwitchCore/Localizations/` (`en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `es`, `fr`, `de`, `pt-BR`, `ru`). Keep insertion order (append at the end, or next to related keys), two-space indentation and `ensure_ascii=False` style JSON.
3. Translate naturally for a macOS app, matching the terminology already used in each catalog (look up related keys first). Keep every placeholder exactly. Usage-limit names follow the table in AGENTS.md. Simplified Chinese uses mainland terms (数据, 文件, 支持, 信息, 操作, 退出登录, 钥匙串), not Taiwanese ones.
4. Keep it short enough for where it appears; menu rows and quota columns are narrow.
5. Use it in code as `L10n.tr("<key>", …)`.
6. Run `python3 scripts/check-localization.py` and `swift test --filter LocalizationTests`.

Show the ten translations in a table when you are done.
