# Quota and usage data

Claude Switch shows two different kinds of numbers:

- **Quota**: how much of each subscription limit is left, per account. Names follow Claude's own usage screen: the **session limit** (a 5-hour window), the **weekly limit** for all models (7 days), and model-specific weekly limits such as **Weekly · Opus**.
- **Usage**: tokens, messages and sessions counted from local Claude Code records on this Mac.

They are measured in different units and cannot be converted into each other.

## Quota

### Where readings come from

By default nothing is sent over the network. Readings come from files Claude Desktop already keeps:

- **Percentages** come from `plan-usage-history.json` in Claude Desktop's folder. Each sample belongs to an account and organization; Claude Switch keeps the newest sample for every account it can match unambiguously. If several local accounts share one organization and cannot be told apart, the reading stays unknown instead of being guessed.
- **Reset times** are not stored in that file. Claude Switch uses, in order:
  1. rate-limit replies (`quotaLimits` with status `rejected` or `allowed_warning`) recorded in Claude Code transcripts under `~/.claude/projects`, but only for sessions that belong to a single Desktop account. Files changed in the last 8 days are read incrementally, at most 16 MB per pass;
  2. the `messageLimits` of the signed-in account in Claude's local `claude.ai` cache. The cache is parsed field by field, and parsing stops at anything unrecognized.
- When neither source has a reset time, it is **estimated** from the sample history. Usage within one window never goes down, so the window started no later than the earliest sample of the current run, and it resets no later than that sample plus the window length. Such times are shown as "resets by …" and marked as estimates. With sparse samples the estimate can be early.

A known reset time always wins over an estimate. A reset time is discarded once it has passed or once a newer sample shows that usage dropped, which means the window reset early.

### What is shown

Every account always shows a session and a weekly row, even when one is unknown. Model-specific weekly limits are listed in addition when they exist.

- Unknown values are shown as `—` with an empty track. `0%` is only shown when a window is truly used up.
- Remaining quota is `100 − utilization`. Quota is never decreased over time by guesswork.
- When a reset time passes, the window is treated as reset: 100% left. Weekly windows roll over to their next reset. A session only starts with the next message, so it shows "Starts on next use" until it is read again.

### Suggested account

When the signed-in account's session limit drops to 20% or less (or its weekly limit to 10% or less) and will not reset within the next half hour (an hour for the weekly limit), the menu bar highlights the saved account with the most session quota left, provided it has clearly more left and at least 20% of its weekly limit. Without a shortage, it may instead point to an account whose unused quota is about to reset. The suggestion is only a hint; nothing switches on its own.
- Accounts that are not signed in keep their last reading together with the time it was taken. Usage on other devices is not visible to Claude Switch.

### Refreshing online

The refresh button on the **signed-in** account's card asks Anthropic for its current quota. It also runs once after you switch accounts, after a new account is saved, and when Claude Desktop changes accounts by itself. The menu bar refresh, `⌘R` and the background check every 60 seconds only re-read local files.

An online refresh:

- sends the same read-only `GET https://api.anthropic.com/api/oauth/usage` that Claude Code's `/usage` command sends. When the token changes, it first calls `GET /api/oauth/profile` and verifies that the account and organization match the one Claude Desktop is signed in to;
- requires a Claude Code installation (the one bundled with Claude Desktop is enough), whose version is sent in the `User-Agent`. Without it, no request is made;
- uses the access token Claude Desktop already holds. It decrypts Claude's token cache with the key in the **Claude Safe Storage** Keychain item. Refresh tokens are never used and no token is ever renewed, so Claude's own login is never disturbed;
- never reads or sends anything for accounts that are not signed in, never uses web cookies, and never sends prompts.

**Keychain prompt.** "Claude Safe Storage" belongs to Claude, so macOS asks once whether Claude Switch may read it. The prompt only appears when you press refresh yourself; automatic refreshes stay silent and skip the request instead. Choose **Always Allow** to avoid being asked again. Builds that are not signed with a stable identity are a new app to macOS after every update, so the question may come back.

**Back-off**, per login, persisted across restarts:

- at least 60 seconds between two requests;
- `429` or `403`: wait for `Retry-After`, or 5 minutes, at most 1 hour;
- `401`: no further requests until the credentials change.

Requests use an ephemeral session without cookies or cache, refuse redirects, time out quickly and accept at most 1 MB. If anything is off (an unexpected format, an identity mismatch, missing permissions), the previous reading is kept and the problem is shown. Error messages never include the response body or the `Authorization` header.

These endpoints are not a documented public API and may change.

## Usage statistics

The **Usage** page counts local Claude Code activity the same way Claude Desktop's own statistics do:

- In a main session file, `user` and `assistant` rows count as messages; sidechain rows do not.
- Each main session file is one session, dated by its first message. The busiest hour is based on session start times.
- Every assistant `usage` row adds its input, output, cache-read and cache-write tokens. `<synthetic>` models are excluded.
- Tokens from `subagents/agent-*.jsonl` count towards model totals but not towards sessions or messages. `.superseded-` files are ignored.
- A valid last line without a trailing newline is counted once; if the file grows later, the line is re-read without being counted twice.

Ranges are **All**, **Today**, **7 days** and **30 days**. Days follow the system time zone. Switching ranges filters daily totals already in memory.

These numbers describe local activity only. They are not subscription limits and not charges.

### Scanning and cache

The first scan reads all local records and shows its progress; you can use other pages meanwhile. After that, a cache (`usage-cache.json`) stores per-file positions, head-and-tail fingerprints, daily totals and token counts. It never contains message text, tool output or credentials.

- Unchanged files are checked by metadata and a fingerprint of their first and last 4 KB. Appended files are read from where the last scan stopped.
- Truncated, replaced or rewritten files are recounted; deleted files are removed from the totals.
- The cache is rebuilt if its version, the folder or the time zone changes, or if it is damaged.
- Files over 1 GB and lines over 16 MB are skipped and reported as partial coverage.

A rewrite in the middle of a file that also grows it while keeping the same head and tail is outside what append-only detection can notice.
