# Claude Desktop and Claude Code internals

Reference for the local files, Keychain items and endpoints Claude Switch depends on. None of this is a public API: Anthropic can change any of it in an update. Code that reads these formats must fail closed (stop and report) when something does not match, and every assumption below should be re-checked after a Claude update with `swift run switch-inspect`.

Paths are relative to `~/Library/Application Support/Claude/` (the Desktop data folder) unless stated otherwise. Where the code lives is noted in brackets.

## Claude Desktop app

| Item | Value |
| --- | --- |
| Bundle identifier | `com.anthropic.claudefordesktop` |
| Install locations checked | `/Applications/Claude.app`, `~/Applications/Claude.app` |
| Data folder | `~/Library/Application Support/Claude/` |
| Interface strings | `Claude.app/Contents/Resources/ion-dist/i18n/<locale>.json` |
| Menu bar icon | `Claude.app/Contents/Resources/TrayIconTemplate.png` (24 pt template, with `@2x` and `@3x`) |

Claude Switch shows Claude's menu bar icon in its status item, in front of the remaining percentage, by loading it from the installed app at runtime (`StatusIcon`); the artwork is never copied into this repository. Everywhere else the app uses its own icon.

The interface string files are the reference for official wording, such as the usage-limit names "Current session", "Session limit", "Weekly · all models" and "Weekly · Opus". Claude ships English, German, Spanish, French, Hindi, Indonesian, Italian, Japanese, Korean and Brazilian Portuguese; there is no official Chinese or Russian wording. [`MacEnvironment`]

## Login identity

A Desktop login is the **identity allow-list**, and only these items are ever replaced when switching [`IdentitySchema`]:

- `Cookies`, `Cookies-journal`, `Cookies-wal`, `Cookies-shm`
- `Local Storage/`, `Session Storage/`, `IndexedDB/`
- three keys in `config.json`: `lastKnownAccountUuid`, `oauth:tokenCache`, `oauth:tokenCacheV2`

Any other `oauth:` key in `config.json` means the format changed; saving and switching are refused.

### `config.json` and its journal

- `lastKnownAccountUuid`: the account Claude was last signed in to. It stays after a sign-out, so it alone does not prove a live login.
- `config.json.journal`, if present, is a pending write: the first line is `<sha256 of payload> <store digest> <in-flight digest>`, then the payload. Claude applies it on the next start only if one of the recorded digests matches the current `config.json`. [`MacEnvironment.effectiveConfig`]

### Signed-in check

`Cookies` is an SQLite database. A non-expired `sessionKey` cookie for host `.claude.ai` in table `cookies(host_key, name, expires_utc)` means Claude is signed in. [`LoginProbe`]

### Token cache encryption

`oauth:tokenCacheV2` (or `oauth:tokenCache`) is base64 of `v10` + ciphertext, Chromium's macOS scheme:

- password: Keychain generic password, service `Claude Safe Storage`, account `Claude Key` (only Claude is trusted by default)
- key: PBKDF2-HMAC-SHA1, salt `saltysalt`, 1003 iterations, 16 bytes
- cipher: AES-128-CBC, IV of 16 spaces (`0x20`), PKCS#7 padding

The plaintext is a JSON object. Keys look like `<client>:<org>:https://api.anthropic.com:<scopes>`, or `acct:<account>|<client>:<org>:https://api.anthropic.com:<scopes>` when bound to an account. Values hold `token` and `expiresAt` (and a refresh token, which Claude Switch never reads or uses). Only entries with both `user:profile` and `user:inference` scopes can read usage. [`DesktopTokenReader`]

## Accounts, emails and plans

- Desktop stores no account name or avatar locally; the UUID is the identity.
- `~/.claude.json` → `oauthAccount.accountUuid`, `emailAddress`, `organizationUuid` (the Claude Code login, which may differ from Desktop's: another account, or another organization of the same account, so its organization only fills a gap). Only `oauthAccount` is decoded; the file also holds project history. [`LocalReader`]
- `IndexedDB/https_claude.ai_0.indexeddb.blob/…`: claude.ai's persisted query cache. Values are V8-serialized and usually Snappy-compressed (`FF 11 02` header). From it Claude Switch reads `account { uuid, email_address }`, each organization's `rate_limit_tier` and `capabilities`, and `current_account.messageLimits[<org>]`. Values are paired only with the `uuid` of the object that holds them, and parsing stops at unknown tags. [`DesktopProfile`]
- Plan names come from `rate_limit_tier` (words `max` with an optional `5x`/`20x`, `pro`, `team`, `enterprise`), falling back to capabilities `claude_max` / `claude_pro`.

## Quota

- `plan-usage-history.json` → `samples[]` with `t` (time), `org`, `u.fh` (session limit used, %) and `u.sd` (weekly limit used, %). No reset times. Samples from earlier logins can remain, so each sample must be matched to its organization. [`LocalReader.localUsage`]
- `messageLimits[<org>]` (above) includes reset times only while a limit is near or hit: `resetsAt` for `representativeClaim`, plus `windows["5h" | "7d"].resets_at`.
- Window identifiers and lengths: `five_hour` (5 hours, starts with the first message), `seven_day` (7 days), plus model-specific weekly windows such as `seven_day_opus` and `seven_day_sonnet`. [`ResetInference.lengths`]

## Claude Code sessions in Desktop

- `claude-code-sessions/<account>/<org>/<sessionId>.json`: one index record per local Claude Code session shown in Desktop. Session IDs are UUIDs or `local_<UUID>`. Fields used: `sessionId`, `cliSessionId`, `title`, `titleSource`, `cwd`, `originCwd`, `model`, `effort`, `createdAt`, `lastActivityAt`, `lastFocusedAt`, `isArchived`, `permissionMode`, `remoteControl`.
- When moving or copying a session, only the resume fields above are carried over; `permissionMode` is reset to `default`, and permission grants, secrets and remote control are dropped. [`MigrationBuilder`]
- Organization folders can exist without sessions (for example holding only `scheduled-tasks.json`); they do not count as a destination.
- `local-agent-mode-sessions/<account>/<org>/…`: Cowork sessions, as JSON files or folders with `manifest.json`. Listed only; Cowork carries sandbox and attachment state that cannot be transferred safely.

## Claude Code transcripts

`~/.claude/projects/<project>/<cliSessionId>.jsonl` (shared by every account; never moved or deleted):

- rows have `type` (`user`, `assistant`, …), `timestamp`, `sessionId`, `isSidechain`, `requestId`, `message.id`, `message.model`, and `message.usage` with `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`;
- `<project>/<…>/subagents/agent-*.jsonl` hold subagent rows; files containing `.superseded-` are obsolete; the model `<synthetic>` is not real usage;
- a reply that hit or neared a limit carries `quotaLimits { status: "rejected" | "allowed_warning", rateLimitType, resetsAt }`. Transcripts have no account UUID. [`TokenScanner`, `LimitLogScanner`]

Installed Claude Code versions live in `claude-code/<version>/` (bundled with Desktop) or `~/.local/share/claude/versions/<version>/`.

## Online endpoints

Used only for the signed-in account, only on the triggers in [usage-data.md](usage-data.md), with the token Desktop already holds:

| Request | Fields read |
| --- | --- |
| `GET https://api.anthropic.com/api/oauth/profile` | `account.uuid`, `account.email_address`, `account.has_claude_max`, `account.has_claude_pro`, `organization.uuid`, `organization.rate_limit_tier` |
| `GET https://api.anthropic.com/api/oauth/usage` | `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus` → `utilization`, `resets_at`; `limits[]` → `scope.model.display_name`, `percent` or `utilization`, `resets_at` |

Headers match Claude Code's `/usage`: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<installed version>`. Back-off rules are in [usage-data.md](usage-data.md). [`ActiveUsageClient`]

## Process behavior

- Claude must be quit through a normal quit request; its helper processes and the Claude Code sessions it runs (builds in `claude-code/<version>/`) can keep files open after it exits. Claude Code started from a terminal or an editor has its own login and never touches Desktop's files, so it is not waited for. Claude Switch never sends `kill`. [`DesktopController`]
- The bundle version (`CFBundleShortVersionString`) is a dotted number. Claude upgrades data left by an older version; data from a newer version may not be readable. [`DesktopVersion`]
- Signing out in Claude, or `/login` in Claude Code, revokes the login on the server; restoring a saved copy afterwards fails and Claude shows its sign-in screen within seconds.
- Claude's updater can restart the app at any time; operations re-check state at each step instead of assuming it.
