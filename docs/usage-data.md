# Quota and usage data

Claude Switch shows two different kinds of numbers:

- **Quota**: how much of each subscription limit is left, per account. Names follow Claude's own usage screen: the **session limit** (a 5-hour window), the **weekly limit** for all models (7 days), and model-specific weekly limits such as **Weekly · Opus**.
- **Usage**: tokens, messages and sessions counted from local Claude Code records on this Mac.

They are measured in different units and cannot be converted into each other.

## Quota

### Where readings come from

Quota percentages and reset times come only from successful online usage responses. Switch does not read Desktop's quota-history file, transcript rate-limit hints or cached `messageLimits`, and never estimates reset times from local history.

Switch retains its own last successful online response for offline display. Reading that cache, checking files or failing a request never advances the measurement time. On library load, legacy local and estimated windows are removed; individually attributed online windows retain their original timestamps. A locally sourced reset is removed even when its percentage came from the server.

### What is shown

Account plan badges distinguish **Free** from **Plan unknown**. Each already permitted quota refresh first rechecks the profile, even if the access token has not changed. A profile whose account and organization match is applied even if the following quota query fails. A confirmed plan change clears quota from the previous plan; an ordinary query failure preserves it when the plan has not changed. Missing plan metadata clears an outdated label to unknown, while offline and authorization failures alone never imply Free or expired membership. Local cache timestamps cannot overwrite a server-confirmed plan. Membership end dates and renewal dates are not read or inferred.

Every account always shows a session and a weekly row, even when one is unknown. Model-specific weekly limits are listed in addition when they exist.

- Unknown values are shown as `—` with an empty track. `0%` is only shown when a window is truly used up.
- Remaining quota is `100 − utilization`. Quota is never decreased over time by guesswork.
- When a reset time passes, the row shows **Awaiting confirmation** and an unknown percentage. The original measurement and reset timestamp remain intact; no 100% value or future weekly reset is invented. A fresh server reading of zero usage with no session reset can show "Starts on next use".
- Every window keeps its own source and observation time. Display freshness follows the refresh interval plus a one-minute allowance, with a ten-minute minimum. Switch suggestions still require measurements no older than ten minutes, without estimates or pending resets. A failed query preserves the previous measurement and its timestamp.

### Suggested account

When the signed-in account's session limit drops to 20% or less (or its weekly limit to 10% or less) and will not reset within the next half hour (an hour for the weekly limit), the menu bar highlights the saved account with the most session quota left, provided it has clearly more left and at least 20% of its weekly limit. Without a shortage, it may instead point to an account whose unused quota is about to reset. The suggestion is only a hint; nothing switches on its own.
- Online readings include the account’s server totals, including other devices. Saved accounts retain their last successful reading when their credentials expire.

### Refreshing online

The refresh button on **each saved account’s card** reads that account's quota. The current account always comes from Desktop's published credentials, with no fallback to its saved snapshot. Existing manual reads of other saved logins remain available. After a successful or observed account switch the incoming account is prioritized, then the outgoing saved login is read once. A newly saved login is also read once; eligible saved accounts also use the periodic schedule below.

The current account additionally gets a bounded read on:

- startup, wake, session unlock, or network restoration, when its reading is due under the refresh policy, missing, or awaiting recovery;
- publication of changed credentials for the same account; a changed encrypted cache only causes a request if the selected access token actually changed;
- an observed reset boundary, once per boundary.

A debounced file observer notices config publication and atomic file replacement. The existing 60-second local scan is a fallback. Toolbar/menu refresh and `⌘R` rescan local accounts and conversations only (and statistics on the Usage page); they do not enqueue quota queries. The account-card refresh reads that card’s quota. Automatic reads never show a Keychain prompt.

### Automatic schedule and settings

Settings can disable automatic quota reads, disable activity adjustment, and set the current-account default interval (5–60 minutes), other-account interval (15–120 minutes), minimum interval (1–5 minutes) and quiet interval (at least the current-account default, up to 120 minutes). Defaults are 15, 30, 1 and 30 minutes respectively. Manual refresh remains available when automatic refresh is disabled.

While Claude is running, a 60-second heartbeat checks metadata of task records belonging to the current account and organization. Code uses uniquely attributed transcript files and their subagent records. Cowork uses account-scoped `audit.jsonl` and nested transcript files, including `agent/` sessions. Only modification times and sizes are read for this purpose; no message bodies, focus/keyboard activity, CPU load or quota deltas are used. Titles, index-file changes and output artifacts do not count.

Each minute contributes at most one changed observation, regardless of the number of sessions. With default settings:

| Changed observations in the last five minutes | Current-account interval |
| --- | --- |
| 4–5 | 1 minute |
| 2–3 | 2 minutes |
| 1 | 5 minutes |
| 0 | 15 minutes |
| 30 continuous minutes of complete observations without changes | 30 minutes |

The intermediate intervals are two and five times the configured minimum, capped at the default interval. Other accounts use their own configured interval, 30 minutes by default, independently of current-account activity. Missing, ambiguous, stale or incomplete activity observations fall back to the default; they never establish inactivity. Account changes clear the selected account’s observation window. Recently modified records seed the initial observation; discovering an old record does not count as new activity. This measures record-change frequency, not exact execution state or token consumption. A long task that produces no record changes can therefore slow down the polling rate.

All automatic reads share one serial queue with at least 15 seconds between attempts. The current account is prioritized without starving overdue saved accounts. The client separately enforces at least 60 seconds per account/organization. Manual success satisfies pending reads for that account. Each next periodic read is anchored to the last successful measurement or attempt, not postponed by every heartbeat. The scheduler does not replay missed polling rounds after sleep.

Claude exit, system sleep or loss of connectivity pauses automatic queries and cancels an automatic read in flight. Claude is never launched just to fetch quota. Expired or rejected credentials suspend that account’s periodic work until updated credentials or a manual recovery; no refresh token is used. Token changes cannot shorten a server cooldown. Background reads never request Keychain authorization.

An online refresh:

- uses only `GET https://api.anthropic.com/api/oauth/profile` and `GET /api/oauth/usage?skip_spend=1`; manual and automatic quota reads skip spending statistics, which the quota display does not use;
- verifies the account and organization with a fresh profile response before each allowed usage read, so a plan change does not wait for token renewal;
- reads the encrypted cache with **Claude Safe Storage**. It matches the supported client ID, exact audience, required and allowed scopes, account binding and a single organization. Conflicting equally suitable credentials stop the read; the latest expiry does not decide ownership;
- checks the server-provided `expiresAt` rather than assuming an eight-hour token lifetime. Expired and soon-expiring tokens wait for Claude; malformed metadata, missing scope, Keychain errors and authorization failures have separate messages;
- never uses refresh grants, web cookies or inference requests. Claude Desktop remains responsible for renewing its login. No saved login is restored merely to read quota.

**Request compatibility.** The builder follows the observed OAuth endpoint and bearer/beta-header contract, using the installed Claude Code version for the existing Code compatibility user agent. A missing Code installation stops the request. This is a Swift `URLSession` client, not Electron `net.fetch`: matching HTTP fields does not reproduce Desktop's transport, cookie context or TLS fingerprint. It is not an official public API or a guarantee against account enforcement. Desktop 2.37337.1 also has a separate cookie-based organization-usage path; Switch does not adopt that path or copy cookies into requests.

**Credential recovery.** A `401` blocks that exact access token, not the account or the encrypted cache. A changed cache with the same denied token cannot bypass this block. The first two minutes after a switch allow short local readiness checks; the observer and fallback scans continue after that deadline. If Claude publishes a replacement token several minutes later, Switch resumes with the new token, subject to the account's remaining cooldown. If Claude cannot renew it, the user must complete login in Claude. A missing local cookie does not prove that a saved login was revoked. Legacy invalid-login flags inferred only from cookie absence are cleared on library load; this permits revalidation without declaring the saved login valid.

A saved access token that has expired retains its last reading and asks the user to switch to the account so Claude can update the login. Non-current accounts are not actively renewed. Cancellation of a switch does not enqueue a switch refresh; an in-flight quota read is canceled when a file operation starts, and changed credentials discard the response.

**Keychain access.** Every normal launch first checks Claude Safe Storage access silently, before loading the library or starting background tasks. If access is unavailable, both app surfaces show an authorization screen; canceling keeps the app blocked with a retry option. This check tests permission only, without reading tokens or querying quota. Demo mode skips it. Only an explicit authorization action or manual quota refresh may request macOS approval. One shared notice covers accounts waiting for access. The authorized Safe Storage key is held only in memory, shared across accounts, and cleared on sleep, session deactivation or exit. A decryption failure discards it and permits one silent reread. Successful access resumes only permission-blocked accounts, preserving credential blocks and server cooldowns; the authorization action retries them 15 seconds apart while Claude is running. Background recovery stays silent. Ad-hoc builds can require approval again after an update.

**Retry state** is persisted in Switch's own private directory, using an exclusive lock to serialize reservations across app instances:

- one lookup cycle per account and organization per 60 seconds; an uncached cycle may contain one profile GET and one usage GET;
- `429`: honor the complete `Retry-After` duration or HTTP date, with a five-minute fallback. A new token or app restart cannot shorten it;
- `401`: wait for a different actual access token; `403` is an authorization/scope failure, not a rate-limit response, and also stops automatic reuse of that token;
- temporary network and server failures: exponential delay from one minute to one hour, respecting longer server delays. Automatic retry bursts are bounded by readiness checks; later recovery is event-driven;
- cancellation is not an account error. No response body or authorization header is put in an error message.

Requests use an ephemeral session without cookies or cache, refuse redirects, have short timeouts and accept at most 1 MB of successful response data (16 KB for error classification). A failed read preserves the last measurement. A visible cooldown is not a successful reading. Unknown response fields remain unknown; `limits[]` is accepted only for the known `weekly_scoped` kind, with bounded model labels and stable model IDs when supplied.

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

The first scan reads all local records and shows its progress; you can use other pages meanwhile. After that, a cache (`usage-cache.json`) stores per-file positions, head-and-tail fingerprints, daily totals and token counts. It never contains message text, tool output or credentials. The cache is written at most every five minutes; after a restart, lines added since then are simply read again. Records are rescanned every minute while the Usage page is on screen, and every ten minutes otherwise.

- Unchanged files are recognized by their inode, size and modification time. A file whose metadata changed is checked with a fingerprint of its first and last 4 KB, then read from where the last scan stopped.
- Truncated, replaced or rewritten files are recounted; deleted files are removed from the totals.
- The cache is rebuilt if its version, the folder or the time zone changes, or if it is damaged.
- Files over 1 GB and lines over 16 MB are skipped and reported as partial coverage.

A rewrite in the middle of a file that also grows it while keeping the same head and tail, or one that keeps its size and modification time, is outside what append-only detection can notice.
