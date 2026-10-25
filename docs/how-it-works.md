# How Claude Switch works

This page explains what Claude Switch reads, what it writes, and how it keeps your data recoverable.
For quota and usage numbers, see [usage-data.md](usage-data.md). For the code layout, see [architecture.md](architecture.md).

## What a Claude Desktop login is

Claude Desktop is an Electron app. Its login lives in `~/Library/Application Support/Claude/` and consists of:

- the browser storage containers `Cookies` (with its `-journal`, `-wal` and `-shm` files), `Local Storage`, `Session Storage` and `IndexedDB`,
- three keys in `config.json`: `lastKnownAccountUuid`, `oauth:tokenCache` and `oauth:tokenCacheV2` (plus a pending `config.json.journal`, if Claude left one).

That set is the **identity allow-list**. Switching accounts means replacing exactly these items and nothing else.

## Startup access

Claude Switch checks two separate Keychain items before opening its main interface:

- **Claude Safe Storage** opens Claude's encrypted login credentials so Switch can query account quota.
- **Claude Switch · Saved Logins** (`io.github.uiuing.claude-desktop-switch.local-vault`) encrypts and opens Switch's saved logins and recovery copies for account switching.

The startup page explains both uses and shows which item is available. macOS can ask separately for each item; approving one does not authorize the other. Choose **Allow access**, then approve each required macOS dialog. Enter your Mac login password only in the system dialog; Switch receives the requested encryption key, not your Mac password. **Always Allow** remembers access for that app identity, while **Allow** can require another approval after cached keys are cleared. If Claude Desktop has never been used, sign in there first.

Switch uses only the project Keychain identifier shown above. A new installation creates its key with the readable label during explicit setup. Existing items are not relabeled when the app language changes. If saved logins or recovery data remain but the project key is missing, setup reports the missing key and stops without replacing it or overwriting those files.

Both Keychain checks must succeed before account scans, saved-login maintenance or background work starts. Canceling keeps the page open for retry. Keys are shared in memory across operations and cleared on sleep, session deactivation and exit; wake rechecks both items silently. A missing vault key is never replaced while saved logins or recovery data remain.

The same startup flow introduces **switch notifications**, enabled in the setup choice by default. It explains completion notices and account recommendations before requesting macOS permission. The user can turn this choice off; declining notifications does not block account features. This introduction appears even if both Keychain permissions already work. A completed choice is remembered, and notifications can later be adjusted in **Settings → Notifications**.

## Feedback and updates

**Report an issue** opens this project's GitHub Issues page. **View latest version** opens the stable `/releases/latest` link. Both are available from the sidebar, menu bar panel and Help menu; Settings includes feedback and update controls as well. Opening feedback does not submit anything or attach local data.

**Settings → Menu bar → Show GitHub, feedback and version links** controls all three links in the menu bar panel together. It is enabled by default, applies immediately and remembers your choice after restarting. It does not change automatic update checks or the links elsewhere in the app.

The separate update checker sends a HEAD request to `https://github.com/uiuing/claude-desktop-switch/releases/latest` and reads the stable version from its redirect target. It does not use the GitHub API quota. It starts with Switch, independently of the account-access gate, and does not read Claude or Keychain data. Automatic checks are enabled by default and run at most once per day while Switch is open; **Settings → Updates** lets users disable them or check manually. Checks across both app scenes share one request. The last attempt, latest stable version and endpoint-specific server cooldown are stored in Switch's preferences. Closely repeated manual checks do not send another request; GitHub rate limits are preserved across restarts. A network or parsing failure is shown as a failed check, never as proof that the app is current.

Only stable numeric release tags are compared. The request carries no account credentials, cookies or local conversation data. The redirect must point to this exact project’s HTTPS release-tag page; other hosts, projects and unsupported tags are rejected. The redirect is not followed, and no page body or release asset is downloaded. The app does not download or install updates; users follow the release link and replace the app themselves. Tests and screenshot previews use injected release data and never contact GitHub.

## Saving logins

When Claude Desktop is signed in to an account that Claude Switch has not saved yet, or whose credentials changed, the app saves it automatically while Claude keeps running:

1. It reads the allow-listed files. Nothing in Claude's folder is modified.
2. It checks the credential fingerprint and the signed-in account before and after reading, and discards the copy if anything changed in between. The captured cookie database is checked together with its captured WAL, so committed login changes need not wait for a database checkpoint. Claude writes its data while it runs, so transient failures retry after 1, 2, 5, 15 and 30 seconds, then at most once per 30 seconds. Persistent failures are shown with a retry action while automatic recovery continues; unsafe paths and unsupported formats require a manual retry or changed credentials.
3. It encrypts the copy with **AES-256-GCM**. The authenticated data binds each snapshot to its account, and every file also carries a SHA-256 digest.
4. The encryption key is stored in your login Keychain as a non-synchronizing item that belongs to Claude Switch. It never goes to iCloud, and a copy of the saved logins cannot be read without it. The login Keychain does move with a full migration of your macOS user account (Migration Assistant or a restored backup), and the saved logins with it.

The previous snapshot of an account is kept for one generation, so a bad save can be rolled back.
Because Claude is running while this happens, a snapshot taken this way may not be perfectly consistent across files; the switch itself saves the current account again after Claude has quit.

## Switching accounts

Every switch is planned first and executed only after you confirm it.

The confirmation combines conversations already set to follow this target with the current account's three most recently active, unarchived Code conversations that have a local history reference, plus every eligible conversation active within the last five minutes. Duplicate sessions appear once. Existing follows and conversations active in those five minutes start checked; older recent additions start unchecked. This default is set when opening the confirmation, so later selection edits stay as chosen. You can select or deselect conversations and choose Move or Copy without leaving the confirmation, including switching with no conversations selected. Activity uses the same last-active timestamp as Conversations, not task running state; future timestamps are not preselected.

Changing the selection rebuilds and validates the transfer preview before enabling Switch. A conversation that cannot be transferred can be deselected. Follow changes are saved only after a successful switch: deselecting a previously followed conversation stops its follow rule, while selecting a new one enables following. Existing account restrictions are preserved, adding this target when the conversation is selected in the confirmed switch. Canceling the preview or a failed switch leaves saved follow rules unchanged.

1. **Preview.** The plan records the current identity, a fingerprint of `config.json`, the target account and organization, the selected Claude Code sessions and a SHA-256 of every file involved. A plan expires after 120 seconds and is re-checked before execution.
2. **Locking.** An in-process actor and a file lock shared between app instances prevent two operations from running at once. An unfinished transaction blocks new ones.
3. **Decrypt first.** The target snapshot is decrypted and verified before Claude is touched. A login saved by an older Claude is restored, because Claude upgrades its own data after an update; one saved by a newer Claude than the installed one stops the switch.
4. **Quit Claude normally.** Claude is asked to quit the usual way. If it does not quit, if several instances are running, or if Claude's helper processes or the Claude Code sessions it started are still running, the switch stops. Claude Code started in a terminal or an editor has its own login and never touches Claude Desktop's files, so it keeps running. Claude Switch never force-kills a process.
5. **Save the current account** again, now that Claude is closed. Revalidate selected conversations against the records checked before quitting. Changes only to JSON formatting or already-excluded authorization/connection state are accepted when the actual transfer content is identical. Changes to any preserved metadata or destination still stop the operation. Source removals pin the exact post-quit file digest.
6. **Replace with a journal.** Each replacement is written to a write-ahead journal first; the original file is moved into the transaction folder before the new one is put in place. The journal and folders are synced to disk. A multi-file change is not atomic, which is why the journal exists.
7. **Roll back on failure.** If any step fails, the transaction is reversed while Claude is still closed. If a safe rollback cannot be confirmed, all data is kept and Settings shows a recovery entry; Claude is not reopened in a mixed state.
8. **Commit and reopen.** Only after a successful commit is Claude reopened. Whether the login is still valid is decided by Claude itself: for 36 seconds after the switch, Claude Switch watches whether Claude stays signed in.

After a successful switch, both the outgoing and incoming accounts are queued for an automatic quota refresh. These read-only requests do not affect the switch result; a failure on one account does not block the other, and each account keeps its own cooldown. See [usage-data.md](usage-data.md).

Operation results identify the selected account, distinguish moved and copied conversations, and ask the user to check the result in Claude. Account-switch results include available fresh online quota; unknown, stale, reset-pending and estimated readings are omitted. The result describes the completed local change, not a new server-side login validation. Successful notices dismiss after five seconds, or sooner with their close button. Errors, manual-open guidance and backup warnings remain visible until dismissed or replaced.

### Notifications and switch reminders

In **Settings → Notifications**, enable macOS notifications and choose **Operation results**, **Switch recommendations**, or both. Permission is requested only when you enable them. If macOS blocks notifications, the settings page links to Notification Settings. System notifications are silent. Operation results identify the selected account using the same email-display preference as the account list, include the result and available quota, and direct the user to check Claude. Failures identify the account and link back to Claude Switch for details; raw errors that may contain file paths remain in the app. Recommendation notifications contain no account identities. When the workbench is visible and active, the in-app notice replaces the system banner to avoid showing the same reminder twice.

Recommendations use the same fresh online quota and account ranking as the account list. Low-quota reminders begin at 10% remaining session quota or 5% remaining weekly quota, with a suitable backup and the reset timing rules described in [usage-data.md](usage-data.md). A low limit produces one reminder per account, organization and quota cycle; exhaustion can produce one more. Receipts survive restarts and stale readings. Declining percentages, corrected reset times and changing the recommended backup do not repeat a low-quota warning or clear its reviewed state. A small rebound after exhaustion does not bring back the earlier warning. A fresh reading confirming the next quota cycle allows another reminder. Suggestions about another account's upcoming reset use distinct wording rather than claiming the current account is running out. Expired or withdrawn recommendations are removed from the interface and Notification Center, without fetching quota just for a reminder.

When a low-quota recommendation has a suitable backup account, the menu bar keeps the Claude icon and the main percentage always represents the current account's session limit. A session warning highlights that percentage with an orange rounded badge and switch arrows. A weekly warning leaves the session percentage unchanged and adds a separate badge labeled Weekly with the weekly percentage. Only the affected limit turns red when exhausted: a weekly limit at 0% never turns a healthy session percentage red. The badge's value, severity and tooltip all use the same recommendation. If both limits need attention, the shared switch advisor chooses the reason; the menu bar does not apply another ranking or warning priority.

Reviewing or dismissing the reminder does not clear the badge: it stays while the recommendation is valid, and disappears when switching, quota recovery, stale readings or an unavailable backup withdraws the recommendation. Without a valid recommendation, the normal session display remains; the menu panel still lists both limits. Upcoming-reset opportunities retain a separate, unreviewed-only arrow indicator.

An unreviewed recommendation also shows a dismissible in-app reminder, which fades after twelve seconds. Clicking the status item for an unreviewed recommendation or clicking the notification opens the existing switch confirmation, including followed conversations and move/copy choices. The shortcut reevaluates the recommendation and verifies the source and target again after preparing the plan. A stale notification opens Accounts with an explanation; it cannot switch an old target. After reviewing or dismissing a reminder, clicking the menu bar opens the normal menu, which retains a recommendation shortcut while the recommendation is valid. No reminder opens a window on its own or executes a switch without confirmation.

After a commit, the recovery copies are archived in encrypted form and read back for verification before the temporary folder is removed.
Finished operations are kept while they are useful: the two newest switches that moved each account's login out of Claude, and everything else for a week. Unfinished operations are always kept.

### Recovering an unfinished operation

If a switch is interrupted (power loss, crash, full disk), Claude Switch shows a recovery banner. Recovery requires Claude to be closed and restores the files to their state before the operation; anything written in between is kept aside rather than discarded. Transactions that were already committed are never rolled back, so a recovery cannot overwrite newer data.

## Adding an account

**Add account** moves the current login out of Claude into the encrypted vault: it removes the identity allow-list from Claude's folder (the three `config.json` keys are removed structurally, everything else in the file stays), and reopens Claude at its sign-in screen. Sign in with another account and it is saved automatically.

Nothing is signed out on the server, so the account you moved aside stays valid.

Adding a login does not immediately transfer conversations. The Add account screen explains this before you start. Once the new login is saved and its organization is verified, Switch offers a separate transfer preview for Code conversations marked to follow. It prefers the account you just left when several copies exist and keeps each conversation's move/copy choice. Only confirming that preview quits Claude and transfers the indexes through the existing journaled transaction.

Until then, Accounts and the menu show **Login saved · Conversations not transferred**. If organization confirmation is still pending, Accounts explains the wait and offers **Refresh quota**, using the existing manual quota/profile read. Canceling the preview leaves a **Review transfer** entry without repeatedly opening it. The pending step survives restarting Switch; signing back in to the original account, having no eligible followed conversations, or switching away ends it. Ordinary automatic login saves do not start this flow. Cowork and cloud Chat are not transferred.

While waiting for a login, Switch checks publication metadata every second and observes changes to config and cookie files, including the cookie WAL. It scans immediately on entry, after a publication, and at least every five seconds while state is unchanged. An unsuccessful or busy scan never consumes a publication. Only a verified signed-in account with a matching saved fingerprint completes discovery; an account already saved before the watcher started can also complete it. Account saving does not wait for online quota or email retrieval.

After fifteen minutes, metadata checks slow to five seconds and unchanged-state scans to fifteen seconds; discovery keeps running. Checks pause while Claude is closed, the Mac is asleep or another operation is running. Startup recovers discovery for signed-out or unsaved logins, and wake or relaunch restores the fast interval. The account list shows waiting or saving status, with saving errors taking priority over the waiting indicator.

> [!WARNING]
> Do not change accounts with Claude's own **Log out** or Claude Code's `/login`. Both revoke the current login on the server, and the copy Claude Switch saved stops working. If Claude cannot restore the login, sign in to it once more. Local cookie absence alone does not establish server revocation.

## Revoked logins

Claude Switch checks session-cookie metadata in a private, stable copy of the cookie database and its WAL. A missing cookie means the account is not currently shown as active; an unreadable or changing store remains unknown. Neither condition marks a saved login permanently expired. Switch waits for Claude to publish updated credentials and shows guidance if login needs attention. An OAuth access-token rejection blocks that token only.

## Moving and copying Claude Code sessions

The menu can also show the current account's [Claude Code task status](code-task-status.md), with followed conversations pinned first and clickable Desktop conversation links. Its optional counts use explicit process state, not recent activity. Switching clears previous associations and reloads the actual account after success or rollback.

Claude Desktop keeps a small index file per local Claude Code session under `claude-code-sessions/<account>/<organization>/`, while the transcript itself is shared in `~/.claude/projects`. Claude Switch can carry the index to another account:

- **Move** (default) writes the index into the target account, then moves the source index into the protected transaction folder, so the source account no longer lists it.
- **Copy** writes the index into the target account and keeps the source.
- If the target already has the same session (same `sessionId` and `cliSessionId`), the preview shows that the selected source will replace that copy. Activity timestamps and file modification times do not override this choice. A different transcript with the same session ID stops the operation.
- The index goes into the organization Claude Desktop uses for the target account. Claude Code can be signed in to another organization of the same account, so when that organization is only a guess and the target's sessions are elsewhere, the transfer stops; switching to the account once and refreshing its quota confirms it.

Writes, the backup of the replaced target and the removal of the source are part of one file transaction, with the same journal and rollback as a switch. The transcript in `~/.claude/projects` is never moved or deleted.

The session record is carried over as a whole, except for the explicit account authorization, cloud bindings and live connection state in `SessionTransferRecord`. This includes cloud-session handoffs, cloud child tasks, Space and routine IDs, cloud publication links, remote dispatch parents and cloud process settings. Pending-start remote-control intent is removed too. Cloud task suggestions and their matching result entries are cleared, while local suggestions remain. Permission modes and their provenance, worktree and branch associations, local preferences, PR metadata and local session lineage remain intact. Switch validates the JSON object, session identity, transcript availability and destination; it does not interpret every Claude setting or enforce a per-version field schema. SSH/WSL targets are execution context and are retained. See [session transfer fields](session-fields.md) for the preservation and exclusion rules.

**Follow** rules mark sessions that should come along whenever you switch accounts, using the same move-or-copy choice. They use a stable session ID, so they keep working after a session has been moved. The current account's copy is authoritative, including preference-only changes that did not advance its activity time. If the current account has no copy and the target already does, no other account's copy overwrites it. A fallback is used only when the target has no copy. An archived current copy is not resurrected from another account. File fingerprints are rechecked before the transaction changes anything.

Cowork sessions are listed for reference only, and cloud chats have no local file that could be transferred.

## What is never touched

- `~/.claude`, `~/.claude.json` and the Claude Code credentials in the Keychain. The separate Claude Code CLI login keeps its own account.
- MCP configuration, skills, plugins, hooks, projects, Cowork data and transcripts.
- Claude's "Claude Safe Storage" Keychain item is only read, for quota access (see [usage-data.md](usage-data.md)).
- Refresh tokens are never used.

## Files and permissions

Claude Switch keeps its own data in `~/Library/Application Support/Claude Desktop Switch/`:

| Path | Contents |
| --- | --- |
| `library.json` | Saved accounts, quota readings, follow rules and preferences |
| `vault/` | Encrypted login snapshots |
| `transactions/` | Journals and recovery copies of switches and transfers |
| `usage-cache.json` | Incremental statistics cache (no message text or credentials) |
| `usage-cooldown.json` | Cooldown state for online quota requests |

The folder is created with mode `0700` and files with `0600`. Files are written atomically. Claude's files are opened one path component at a time with `O_NOFOLLOW`, sizes are bounded, and inode, size and modification time are compared after reading. A damaged library file is never silently replaced with an empty one.

Removing an account in Claude Switch deletes its saved login, its quota history and its copies in finished transactions. Claude Desktop is not affected. Unfinished transactions are always kept for recovery.

## Known limits

- Claude Desktop's storage formats are private and can change with any update. When Claude Switch finds an unknown login format, it refuses to save or switch rather than guessing.
- Other software running as your macOS user, or Claude's own updater restarting the app between checks, cannot share a lock with Claude Switch.
- Swift strings cannot be reliably wiped from memory; decrypted buffers are cleared where possible and secrets are never logged.
