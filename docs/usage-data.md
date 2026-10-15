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

Account plan badges distinguish **Free** from **Plan unknown**. A matching online profile is authoritative for the email, organization and plan, even if the following quota query fails. Local Desktop scans update emails and plans that have not been confirmed online, and fill missing email information. Desktop's email cache takes precedence over Claude Code's fallback; saved snapshots and Code only fill gaps. Local files never overwrite an online-confirmed email or plan, regardless of file timestamps. Unchanged local plan values do not advance their observation time. A confirmed plan change clears quota from the previous plan; an ordinary query failure preserves it when the plan has not changed. Missing online plan metadata clears an outdated label to unknown, while offline and authorization failures alone never imply Free or expired membership. Membership end dates and renewal dates are not read or inferred.

Every account always shows a session and a weekly row, even when one is unknown. Model-specific weekly limits are listed in addition when they exist.

Account cards keep vertical spacing compact while retaining full-size text, controls and reset times. The list scrolls when saved accounts exceed the available window height.

- Unknown values are shown as `—` with an empty track. `0%` is only shown when a window is truly used up.
- Remaining quota is `100 − utilization`. Quota is never decreased over time by guesswork.
- Cached readings keep their normal percentage, progress bar and reset display even when stale. The account's update time and the tooltip identify the last successful measurement; freshness never hides an existing value. A confirmed zero-usage session with an explicitly absent reset keeps "Starts on next use" when cached.
- When a reset time passes, the row keeps the previous percentage and reset timestamp with an **Awaiting sync** qualifier. Relative-time mode shows **Reset passed · Awaiting sync**. No 100% value or future weekly reset is invented. A successful server response replaces the cached reading and may confirm that the next session starts on next use.
- Cards, menu rows, status items, timestamps and ranking all require the reading to match the account and its known organization. A mismatched or missing organization yields unknown quota.
- The account page and menu show one shared notice when automatic refresh is disabled or paused because Claude is closed, the Mac is asleep or connectivity is unavailable. Cached values and account metadata stay visible during the pause and while waiting for resumed reads. Opening Claude resumes eligible reads, prioritizing the current account and preserving server cooldowns. Manual refresh remains a separate action; opening a view or relaunching Switch does not advance cached timestamps.
- Every window keeps its own source and observation time. Freshness classification follows the refresh interval plus a one-minute allowance, with a ten-minute minimum, independently of display. Switch suggestions normally require measurements no older than ten minutes; confirmed unused backup sessions follow the availability rule below. A failed query preserves the previous measurement and its timestamp.

### Account order and switch suggestions

`AccountRanking` supplies the account page, menu, quick search and account selectors. The current account is pinned first only for display; its score is evaluated normally. Usable accounts come first, followed by readings needing confirmation, confirmed exhausted accounts and unavailable logins. A refresh error or HTTP 429 is not evidence that subscription quota is exhausted.

A saved non-current account whose online response confirmed 100% session quota and an explicitly absent session reset remains eligible between refreshes: its next session starts on use. Its last confirmed weekly reading must also have positive quota and a known, unelapsed server reset. These readings keep their original observation times. New online readings replace this state, including usage on another device; an elapsed weekly reset requires confirmation. A passed session reset alone never creates an unused session. Reminder expiry follows the same availability rule, so the backup's ten-minute reading age does not withdraw an otherwise valid reminder. Current-account readings and started backup sessions retain the ten-minute requirement.

Within the same availability group, accounts with known session multipliers use this **ranking index**:

```text
relative base = session remaining fraction x min(1, weekly remaining percent / 20)
comparison base = highest relative base in a comparable session group
score = session multiplier x comparison base x (1 + 5% x weekly remaining fraction + reset bonus)
```

Pro uses 1, Max 5x uses 5 and Max 20x uses 20. These are nominal per-session multipliers, not weekly-capacity multipliers ([Max plan](https://support.claude.com/en/articles/11049741-what-is-the-max-plan)). Weekly quota below 20% discounts the base index; either window at zero prevents a usable ranking. This reserve is a conservative policy parameter, not an estimate of tokens, time or absolute weekly capacity. Weekly headroom also contributes above the reserve instead of being considered only when final indices tie.

Accounts with the same plan label and availability are compared in session groups. Starting with the highest relative base, a group includes accounts within five percentage points of both its session remainder and its reserve-adjusted relative base. All members use that group's highest relative base for comparison. Thus a small session difference does not defeat more weekly headroom. Missing plan labels are not combined. Each group has a fixed anchor: with session remainders of 100%, 96% and 92%, the first two are comparable, while 92% starts the next group. This avoids cyclic pairwise comparisons and keeps results independent of input order. Original measurements and the ungrouped base remain unchanged.

Reset time participates in the same score. Within each comparable session group, confirmed deadlines are grouped from earliest to latest: session resets within one hour of the group's earliest reset, and weekly resets within one day, share the later time for the urgency calculation. Differences inside these ranges therefore do not outweigh weekly headroom. Larger gaps retain separate urgency values and can change the preferred account.

```text
urgency = max(0, 1 - time until the group's latest reset / window length)
opportunity = clamp((time until reset - 5 minutes) / 15 minutes, 0, 1)
window priority = remaining fraction x urgency x opportunity
reset bonus = 10% x max(session priority, weekly priority)
```

The session priority uses the comparable group's highest session remainder; the weekly priority uses each account's own weekly remainder. Only usable accounts with confirmed reset times receive this bonus, including confirmed unused backups retained between refreshes. A confirmed unused session is treated as a full session window ahead for grouping and receives no session expiry bonus. Eligibility and scoring use the same validity decision: a retained unused backup does not lose its reset priority merely because its reading passes ten minutes. An unknown, estimated or elapsed reset contributes nothing; readings needing confirmation and exhausted or unavailable accounts receive no bonus. Five minutes are reserved for switching. With less than another fifteen minutes available, the opportunity factor still fades using the account's actual deadline rather than rewarding a deadline that cannot usefully be reached. These are bounded policy parameters, not measurements of switching time or predicted work. The two window priorities are not added because one request consumes both limits. The reset bonus remains capped at 10%, and the separate weekly-headroom bonus at 5% of the comparison base.

For example, two unused Pro accounts have 60% and 85% weekly remaining, resetting in 5.1 and 5.8 days. Both menu labels say six days. They share a comparison base and reset urgency, so the 85% account ranks first. A 95% session with more weekly quota can also precede a full session when their resets are close. If the 60% weekly account instead resets in half a day and the 85% account in six days, the larger reset advantage can put the earlier account first. The current account participates in the same grouping and scoring before display pinning.

Free, unknown Max tiers, Team without a confirmed seat type, Enterprise and unknown plans have no assumed multiplier. They follow mapped plans within their availability group and are ordered relative to each other using the same reserve policy. They can still be manually selected. No local token totals or historical capacity fitting enter this first implementation. Old online readings retain a last-recorded display order; only the confirmed unused backups described above can also supply a recommendation. Elapsed resets remain unknown until confirmed.

The best backup is the first usable non-current account in this ranking. Suggestions examine that one backup, never choose a different account using separate expiry or percentage rules:

- If the current account has a freshly confirmed exhausted window, a usable backup can be suggested immediately, even when a reset is close or its plan multiplier is unknown.
- Before exhaustion, both plans need known multipliers. The target must retain at least 20% weekly quota and improve the index by at least both 25% and 0.2. Different plan multipliers additionally require that the target's weekly percentage is no lower than the current account's; weekly capacities have no verified conversion.
- A session shortage of 10% or less triggers a suggestion only if it will not reset within half an hour. A weekly shortage of 5% or less similarly waits when its reset is within an hour. This waiting rule never suppresses a confirmed exhaustion.
- An expiry suggestion requires the same known multiplier, a final score no lower than the current account's, and no reduction in either remaining percentage. A session reset must be within an hour, or a weekly reset within a day, with at least five minutes left. Its advantage over the current reset must exceed the same one-hour or one-day comparison tolerance. The current account must have a confirmed later reset for that window, or an untouched session that starts on next use; an unknown or estimated current reset cannot establish an expiry advantage. A reset bonus may change the best backup without making it worth interrupting a healthy current account. No work rate is inferred.

Every relevant percentage must be an online measurement with a non-future timestamp and no pending reset, meeting either the ten-minute requirement or the confirmed unused-backup rule. Account and organization ownership must match. An unavailable or uncertain best backup does not silently cause the advisor to pick a lower-ranked account with a different scoring rule.

This is general account advice using the session and all-model weekly windows. Model-specific windows are still shown separately; the app does not infer the current model from historical sessions or claim that every model is usable. Context-specific ranking and learned capacity conversion are deferred.

Open menus freeze row positions and the suggested account identity. Readings continue updating; a withdrawn or changed suggestion disappears until the next opening. Newly saved accounts append, removed accounts disappear, and clicks remain bound to account IDs. The suggestion is only a hint; nothing switches on its own. Ranking adds no network requests or credential access.
- Online readings include the account’s server totals, including other devices. Saved accounts retain their last successful reading when their credentials expire.

### Refreshing online

The refresh button on **each saved account’s card** reads that account's quota. The current account always comes from Desktop's published credentials, with no fallback to its saved snapshot. Existing manual reads of other saved logins remain available. After a successful or observed account switch the incoming account is prioritized, then the outgoing saved login is read once. A newly saved login is also read once; eligible saved accounts also use the periodic schedule below.

Profile GETs have exactly three triggers: the first use of an access token for its account and organization, the incoming and outgoing reads after a switch, and the refresh button on an individual account's card. Each triggered read gets the profile before usage; overlapping triggers share one profile GET. Switch retries reuse a successfully read profile for that switch event, while a new manual refresh requests it again. Ordinary automatic reads reuse the token's verified identity until expiry, without a timed profile refresh. Verification is held only in memory, so the first read after an app restart verifies again. Cached verification never republishes old email or plan information. Email and plan discovery continues through the existing local scan; no additional timer or scheduler is added.

The current account additionally gets a bounded read on:

- startup, wake, session unlock, or network restoration, when its reading is due under the refresh policy, missing, or awaiting recovery;
- publication of changed credentials for the same account; a changed encrypted cache only causes a request if the selected access token actually changed;
- an observed reset boundary, once per boundary.

A debounced file observer notices config and cookie publication, including WAL updates and atomic file replacement. The existing 60-second local scan is a fallback. Toolbar/menu refresh and `⌘R` rescan local accounts and conversations only (and statistics on the Usage page); they do not enqueue quota queries. The account-card refresh reads that card's quota. Automatic reads never show a Keychain prompt.

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
- verifies the account and organization on the three profile triggers above; other reads directly request usage with the same valid, verified token. The usage request uses its bearer credential independently; the profile response is an identity check, not a separate authorization grant;
- reads the verified account's email from `account.email`, with `email_address` and `emailAddress` as compatibility fields. A verified profile fills in missing emails for new and existing saved accounts even if the following quota read fails. An unavailable email remains unknown; addresses from other objects are never borrowed;
- reads the encrypted cache with **Claude Safe Storage**. It matches the supported client ID, exact audience, required and allowed scopes, account binding and a single organization. Conflicting equally suitable credentials stop the read; the latest expiry does not decide ownership;
- checks the server-provided `expiresAt` rather than assuming an eight-hour token lifetime. Expired and soon-expiring tokens wait for Claude; malformed metadata, missing scope, Keychain errors and authorization failures have separate messages;
- never uses refresh grants, web cookies or inference requests. Claude Desktop remains responsible for renewing its login. No saved login is restored merely to read quota.

**Request compatibility.** The builder follows the observed OAuth endpoint and bearer/beta-header contract, using the installed Claude Code version for the existing Code compatibility user agent. A missing Code installation stops the request. This is a Swift `URLSession` client, not Electron `net.fetch`: matching HTTP fields does not reproduce Desktop's transport, cookie context or TLS fingerprint. It is not an official public API or a guarantee against account enforcement. Desktop 2.37337.1 also has a separate cookie-based organization-usage path; Switch does not adopt that path or copy cookies into requests.

**Credential recovery.** A `401` blocks that exact access token, not the account or the encrypted cache. A changed cache with the same denied token cannot bypass this block. The first two minutes after a switch allow short local readiness checks; the observer and fallback scans continue after that deadline. If Claude publishes a replacement token several minutes later, Switch resumes with the new token, subject to the account's remaining cooldown. If Claude cannot renew it, the user must complete login in Claude. A missing local cookie does not prove that a saved login was revoked. Legacy invalid-login flags inferred only from cookie absence are cleared on library load; this permits revalidation without declaring the saved login valid.

A saved access token that has expired retains its last reading and asks the user to switch to the account so Claude can update the login. Non-current accounts are not actively renewed. Cancellation of a switch does not enqueue a switch refresh; an in-flight quota read is canceled when a file operation starts, and changed credentials discard the response.

**Keychain access.** Every normal launch first checks Claude Safe Storage and Switch's own `io.github.uiuing.claude-desktop-switch.local-vault` access silently, before loading the library or starting background tasks. These are separate permissions: the former opens quota credentials; the latter protects saved logins and recovery copies. Both must be available. The startup page also introduces notifications with an enabled-by-default choice before requesting the optional system permission. If access is unavailable, both app surfaces show an authorization screen; canceling keeps the app blocked with a retry option. This check tests permission only, without reading tokens or querying quota. Demo mode skips it. Only an explicit authorization action or manual quota refresh may request macOS approval. One shared notice covers accounts waiting for access. Both authorized keys are held only in memory, shared across their operations, and cleared on sleep, session deactivation or exit. Wake silently rechecks both. `KeychainInteraction` serializes all reads and creation with the process-wide legacy interaction guard; only an explicitly authorized action can enable a system prompt. Vault encryption and decryption reuse its cached key, rather than querying Keychain for every snapshot or recovery copy. A decryption failure keeps the existing key while checking for a replacement; only a successful Keychain read replaces it. A key obtained during that request is not immediately read again. Concurrent rechecks share their result, and a bounded in-memory set remembers credential fingerprints that still fail with the freshly read key, until the key changes or is cleared. A failed replacement read affects only that account while the existing key remains available; manual refresh can request the needed authorization, while automatic rechecks stay silent. Sleep or session deactivation cancels a late approval result instead of reporting access that was not retained. Successful access resumes only permission-blocked accounts, preserving credential blocks and server cooldowns; the authorization action retries them 15 seconds apart while Claude is running. Background recovery stays silent. Ad-hoc builds can require approval again after an update.

**Retry state** is persisted in Switch's own private directory, using an exclusive lock to serialize reservations across app instances:

- one lookup cycle per account and organization per 60 seconds; a cycle contains one usage GET, preceded by one profile GET when required by a profile trigger;
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
