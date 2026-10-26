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

`Cookies` is an SQLite database. Read a stable private copy together with committed WAL frames; never open the live database as immutable. A non-expired `sessionKey` cookie for host `.claude.ai` in table `cookies(host_key, name, expires_utc)` means Claude is signed in. [`LoginProbe`]

### Token cache encryption

`oauth:tokenCacheV2` (or `oauth:tokenCache`) is base64 of `v10` + ciphertext, Chromium's macOS scheme:

- password: Keychain generic password, service `Claude Safe Storage`, account `Claude Key` (only Claude is trusted by default)
- key: PBKDF2-HMAC-SHA1, salt `saltysalt`, 1003 iterations, 16 bytes
- cipher: AES-128-CBC, IV of 16 spaces (`0x20`), PKCS#7 padding

The plaintext is a JSON object. Keys look like `<client>:<org>:https://api.anthropic.com:<scopes>`, or `acct:<account>|<client>:<org>:https://api.anthropic.com:<scopes>` when bound to an account. Values hold `token` and `expiresAt` (and a refresh token, which Claude Switch never selects or uses). Only entries with both `user:profile` and `user:inference` scopes can read usage. Account-bound candidates take precedence over unbound candidates; within that binding, candidates without `user:sessions:claude_code` take precedence unless their token has a recorded authorization rejection. An eligible Code-scoped candidate can then be selected, without bypassing identity conflicts, same-rank ambiguity or account cooldowns. Expiry is a validity check, not evidence of ownership or issuance order. [`DesktopTokenReader`]

## Accounts, emails and plans

- Desktop stores no account name or avatar locally; the UUID is the identity.
- `~/.claude.json` → `oauthAccount.accountUuid`, `emailAddress`, `organizationUuid` (the Claude Code login, which may differ from Desktop's: another account, or another organization of the same account, so its organization only fills a gap). Only `oauthAccount` is decoded; the file also holds project history. [`LocalReader`]
- `IndexedDB/https_claude.ai_0.indexeddb.blob/…`: claude.ai's persisted query cache. Values are V8-serialized and usually Snappy-compressed (`FF 11 02` header). From it Claude Switch reads `account { uuid, email_address }`, each organization's `rate_limit_tier` and `capabilities`. Values are paired only with the `uuid` of the object that holds them, and parsing stops at unknown tags. [`DesktopProfile`]
- Plan names come from `rate_limit_tier` (words `max` with an optional `5x`/`20x`, `pro`, `team`, `enterprise`), falling back to capabilities `claude_max` / `claude_pro`. Known free tiers include `default_claude_ai` and `claude_free`. A complete `chat` capability list without paid, API or managed-team capabilities also identifies Free when the tier is absent. Missing flags, unknown tiers, mixed API/chat organizations and unsupported capability arrays stay unknown. A complete dense V8 string array is required for capability-based classification.
- OAuth profile reads also use organization `capabilities` and `raven_type` to distinguish personal Free from Team/Enterprise. A verified profile replaces an earlier plan, including with unknown, independently of usage success. Online-confirmed emails and plans take precedence over all local cache timestamps. The existing local scan updates unconfirmed Desktop information; Claude Code and saved snapshots only fill gaps. Changing organization clears its plan confirmation. Token expiry and HTTP authorization failures do not themselves imply membership expiry.

## Quota

Quota percentages and reset times are read only from the online endpoints below. Desktop's `plan-usage-history.json`, cached `messageLimits` and transcript quota hints are not used for quota. Existing local/estimated measurements are filtered from Switch's library on load. Window identifiers include `five_hour` and `seven_day`, plus model-specific weekly windows.

Activity scheduling reads only modification times and sizes of Code transcripts/subagent records and Cowork audit/transcript records. Cowork stores sessions under the account/organization directory, optionally under `agent/`; some Desktop versions shorten UUID directory names to eight characters. Shortened account/organization roots are used only when unambiguous among known identities. Missing or unsupported layouts remain unknown. This is scheduling evidence only; it never supplies quota or reset times.

## Claude Code sessions in Desktop

- `claude-code-sessions/<account>/<org>/<sessionId>.json`: one index record per local Claude Code session shown in Desktop. Session IDs are UUIDs or `local_<UUID>`. The [session transfer field policy](session-fields.md) describes preserved metadata and excluded account state.
- `SessionTransferRecord` preserves ordinary and future metadata; only evidenced identity, authorization and live bindings are excluded. `sessionPermissionUpdates` retains directory additions/removals; connector configuration keeps non-credential fields. Supported records store `remoteMcpServersConfig` as an array of server descriptors (`uuid`, `name`, optional `url`/`instructions`, `tools`); an empty array is valid, and tool input schemas are descriptions rather than stored credentials. Null optional configuration is treated as absent. [Session fields](session-fields.md) defines the policy. `ConversationTree` follows `spawnedFrom`, `forkedFromSessionId` and `lineageDetached`; IDs and full native records stay unchanged. The waiting-input manifests use `v`, `sessionId`, ordered `entries` and SHA-256-named blobs under `waiting-input/<sessionId>/`.
- Persisted Code view stores include `epitaxy.sidePaneStore.v1`, its `.pane.*` records, terminal tabs/prompt lines, side-chat and session-scroll stores in Local Storage. Their session-scoped entries are non-authentication state. Live WebContents, PTYs and worker processes are not a restart checkpoint. Persistent `launch-preview-*` partitions can retain website credentials across stable session IDs; transfers stop when persistent preview contexts would be reused.
- The narrow companion write boundary is `claude-code-sessions/<account>/<org>/.../<session-or-cli-id>[.<suffix>][/<descendants>]`. `switch-presentation/<sessionId>.json` is Switch-owned, credential-free presentation data retained with that conversation. Shared account catalogs are not assigned to one session by guessing.
- Organization folders can exist without sessions (for example holding only `scheduled-tasks.json`); they do not count as a destination.
- `local-agent-mode-sessions/<account>/<org>/…`: Cowork sessions, as JSON files or folders with `manifest.json`. Listed only; Cowork carries sandbox and attachment state that cannot be transferred safely.

## Claude Code transcripts

Code conversation activity uses `lastActivityAt`, with `updatedAt` only as a fallback. Missing index timestamps remain unknown; rewriting an index does not establish activity. For the active account, each inventory scan also checks user/assistant row timestamps in the uniquely matched `cliSessionId` transcript and its native `subagents/agent-*.jsonl` records, excluding superseded records. Quit-time writes can append maintenance rows to idle transcripts, so file modification times and non-conversation rows never advance conversation activity. Inactive account copies retain their own index times because transcripts are shared. Only type/timestamp fields are decoded, not message contents. Reads are cached by file stamp and bounded to the last 1 MiB per changed file and 16 MiB per scan; partial lines, invalid/future timestamps and unreadable or ambiguous histories do not override the index timestamp. Main-conversation activity includes descendants. Switch previews refresh local inventory before applying the five-minute selection rule. Conversation activity does not establish task status or account usage.

The separate [Code task status reader](code-task-status.md) reads bounded PID registry records under `~/.claude/sessions/` and selected Desktop Code indexes. It validates Desktop process ancestry, native process birth, `hostSessionId`, and `cliSessionId`. Transcript timestamps are not task state. The private registry format was inspected statically in the official Claude Code 2.1.301 distribution; compatibility with a running Desktop engine remains a separate acceptance step.

`~/.claude/projects/<project>/<cliSessionId>.jsonl` (shared by every account; never moved or deleted):

- rows have `type` (`user`, `assistant`, …), `timestamp`, `sessionId`, `isSidechain`, `requestId`, `message.id`, `message.model`, and `message.usage` with `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`;
- `<project>/<…>/subagents/agent-*.jsonl` hold subagent rows; files containing `.superseded-` are obsolete; the model `<synthetic>` is not real usage;
- a reply that hit or neared a limit carries `quotaLimits { status: "rejected" | "allowed_warning", rateLimitType, resetsAt }`. Transcripts have no account UUID. [`TokenScanner`; quota hints are ignored]

Installed Claude Code versions live in `claude-code/<version>/` (bundled with Desktop) or `~/.local/share/claude/versions/<version>/`.

## Online endpoints

Used on the event triggers and configurable, staggered periodic schedule in [usage-data.md](usage-data.md). Automatic queries pause when Claude is closed. The access token comes from Desktop or the selected encrypted vault snapshot; it is never renewed:

The profile is read before usage only for a new token's first verification, both sides of an account switch, or a manual account-card refresh. Identity verification is cached in memory by account, organization and token digest until expiry. A switch event keeps its profile-read identity across usage retries. Reusing validation does not publish cached account metadata. There is no separate profile polling interval.

| Request | Fields read |
| --- | --- |
| `GET https://api.anthropic.com/api/oauth/profile` | `account.uuid`, `account.email` (with `email_address` / `emailAddress` compatibility), `account.has_claude_max`, `account.has_claude_pro`, `organization.uuid`, `organization.rate_limit_tier`, `organization.capabilities`, `organization.raven_type` |
| `GET https://api.anthropic.com/api/oauth/usage?skip_spend=1` | `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`, `seven_day_oauth_apps`, `seven_day_cowork` → `utilization`, `resets_at`; `limits[]` with `kind == weekly_scoped` → optional `scope.model.id`, `scope.model.display_name`, `percent` or `utilization`, `resets_at` |

The OAuth compatibility builder uses: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<installed version>`. These fields do not establish transport equivalence with Electron. Desktop 2.37337.1 has both an OAuth usage path and a separate cookie-based organization-usage path. Switch uses only the OAuth compatibility path. Back-off and credential selection rules are in [usage-data.md](usage-data.md). [`ActiveUsageClient`]

## Process behavior

- Claude must be quit through a normal quit request; its helper processes and the Claude Code sessions it runs (builds in `claude-code/<version>/`) can keep files open after it exits. Claude Code started from a terminal or an editor has its own login and never touches Desktop's files, so it is not waited for. Claude Switch never sends `kill`. [`DesktopController`]
- The exact bundle-relative executable `Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler` is excluded from the helper stop check. Electron's separate Crashpad handler writes crash reports, not login or conversation stores; on macOS it can remain after its clients exit while an upload completes ([Electron](https://www.electronjs.org/docs/latest/api/crash-reporter/), [Crashpad handler lifecycle](https://github.com/chromium/crashpad/blob/main/handler/crashpad_handler.md)). The exclusion does not cover other executables with the same basename in another bundle location. [`ProcessTable.leftover`]
- The bundle version (`CFBundleShortVersionString`) is a dotted number. Claude upgrades data left by an older version; data from a newer version may not be readable. [`DesktopVersion`]
- Signing out in Claude, or `/login` in Claude Code, revokes the login on the server; restoring a saved copy afterwards fails and Claude shows its sign-in screen within seconds.
- Claude's updater can restart the app at any time; operations re-check state at each step instead of assuming it.
