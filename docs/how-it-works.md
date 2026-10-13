# How Claude Switch works

This page explains what Claude Switch reads, what it writes, and how it keeps your data recoverable.
For quota and usage numbers, see [usage-data.md](usage-data.md). For the code layout, see [architecture.md](architecture.md).

## What a Claude Desktop login is

Claude Desktop is an Electron app. Its login lives in `~/Library/Application Support/Claude/` and consists of:

- the browser storage containers `Cookies` (with its `-journal`, `-wal` and `-shm` files), `Local Storage`, `Session Storage` and `IndexedDB`,
- three keys in `config.json`: `lastKnownAccountUuid`, `oauth:tokenCache` and `oauth:tokenCacheV2` (plus a pending `config.json.journal`, if Claude left one).

That set is the **identity allow-list**. Switching accounts means replacing exactly these items and nothing else.

## Saving logins

When Claude Desktop is signed in to an account that Claude Switch has not saved yet, or whose credentials changed, the app saves it automatically while Claude keeps running:

1. It reads the allow-listed files. Nothing in Claude's folder is modified.
2. It checks the credential fingerprint and the signed-in account before and after reading, and discards the copy if anything changed in between.
3. It encrypts the copy with **AES-256-GCM**. The authenticated data binds each snapshot to its account, and every file also carries a SHA-256 digest.
4. The encryption key is stored in the macOS Keychain as a `ThisDeviceOnly`, non-synchronizing item that belongs to Claude Switch. Saved logins therefore cannot be moved to another Mac.

The previous snapshot of an account is kept for one generation, so a bad save can be rolled back.
Because Claude is running while this happens, a snapshot taken this way may not be perfectly consistent across files; the switch itself saves the current account again after Claude has quit.

## Switching accounts

Every switch is planned first and executed only after you confirm it.

1. **Preview.** The plan records the current identity, a fingerprint of `config.json`, the target account and organization, the selected Claude Code sessions and a SHA-256 of every file involved. A plan expires after 120 seconds and is re-checked before execution.
2. **Locking.** An in-process actor and a file lock shared between app instances prevent two operations from running at once. An unfinished transaction blocks new ones.
3. **Decrypt first.** The target snapshot is decrypted and verified before Claude is touched.
4. **Quit Claude normally.** Claude is asked to quit the usual way. If it does not quit, if several instances are running, or if helper or Claude Code processes are still busy, the switch stops. Claude Switch never force-kills a process.
5. **Save the current account** again, now that Claude is closed. If the Claude version differs from the one the target snapshot was taken with, the switch stops.
6. **Replace with a journal.** Each replacement is written to a write-ahead journal first; the original file is moved into the transaction folder before the new one is put in place. The journal and folders are synced to disk. A multi-file change is not atomic, which is why the journal exists.
7. **Roll back on failure.** If any step fails, the transaction is reversed while Claude is still closed. If a safe rollback cannot be confirmed, all data is kept and Settings shows a recovery entry; Claude is not reopened in a mixed state.
8. **Commit and reopen.** Only after a successful commit is Claude reopened. Whether the login is still valid is decided by Claude itself: for 36 seconds after the switch, Claude Switch watches whether Claude stays signed in.

After a commit, the recovery copies are archived in encrypted form and read back for verification before the temporary folder is removed.

### Recovering an unfinished operation

If a switch is interrupted (power loss, crash, full disk), Claude Switch shows a recovery banner. Recovery requires Claude to be closed and restores the files to their state before the operation; anything written in between is kept aside rather than discarded. Transactions that were already committed are never rolled back, so a recovery cannot overwrite newer data.

## Adding an account

**Add account** moves the current login out of Claude into the encrypted vault: it removes the identity allow-list from Claude's folder (the three `config.json` keys are removed structurally, everything else in the file stays), and reopens Claude at its sign-in screen. Sign in with another account and it is saved automatically.

Nothing is signed out on the server, so the account you moved aside stays valid.

> [!WARNING]
> Do not change accounts with Claude's own **Log out** or Claude Code's `/login`. Both revoke the current login on the server, and the copy Claude Switch saved stops working. If that happens, the account is marked **Expired** and you only need to sign in to it once more.

## Revoked logins

Claude Switch reads the `sessionKey` cookie for `claude.ai` to tell whether Claude is signed in. When Claude is signed out of an account that was in use, that account is marked **Expired**, it is not shown as active, and the app asks you to sign in to it again. A revoked login can only be detected once Claude tries to use it.

## Moving and copying Claude Code sessions

Claude Desktop keeps a small index file per local Claude Code session under `claude-code-sessions/<account>/<organization>/`, while the transcript itself is shared in `~/.claude/projects`. Claude Switch can carry the index to another account:

- **Move** (default) writes the index into the target account, then moves the source index into the protected transaction folder, so the source account no longer lists it.
- **Copy** writes the index into the target account and keeps the source.
- If the target already has the same session (same `sessionId` and `cliSessionId`), it is updated with the current version. A different session with the same name stops the operation instead of being overwritten.

Writes, the backup of the replaced target and the removal of the source are part of one file transaction, with the same journal and rollback as a switch. The transcript in `~/.claude/projects` is never moved or deleted.

Only the fields needed to resume the session are carried over (title, timestamps, working directory, model, session IDs). Permission settings are reset to the default; MCP secrets, tool approvals, remote control and organization permissions are not transferred.

**Follow** rules mark sessions that should come along whenever you switch accounts, using the same move-or-copy choice. They use a stable session ID, so they keep working after a session has been moved. Archived sessions are never followed.

Cowork sessions are listed for reference only, and cloud chats have no local file that could be transferred.

## What is never touched

- `~/.claude`, `~/.claude.json` and the Claude Code credentials in the Keychain. The separate Claude Code CLI login keeps its own account.
- MCP configuration, skills, plugins, hooks, projects, Cowork data and transcripts.
- Claude's "Claude Safe Storage" Keychain item is only read, and only when you refresh quota (see [usage-data.md](usage-data.md)).
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
