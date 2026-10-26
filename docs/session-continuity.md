# Code conversation integrity

Implementation contract for persisted Code conversations. Automatic task continuation is outside this implementation.

## Product behavior

A user selects an account and main conversations. Lists, search, switch confirmation and task menus group native descendants under their main conversation and display the visible subtask count. Selecting the main includes its complete native subtree, including archived descendants. Recent activity anywhere in the tree can trigger the existing five-minute preselection.

A transfer moves the selected conversation tree. Source indexes and pending-input manifests lose ownership only after destination verification.

## Preservation boundaries

| Information | Handling |
| --- | --- |
| Main/child session indexes | Preserve complete JSON minus evidenced identity, credentials, grants and live connection handles. Keep stable IDs and native ancestry. Missing parents, cycles, duplicate identities and changing descendant sets stop affected transfers. |
| Ordinary and future metadata | Preserve by default, including nested values and integer metadata. No complete field whitelist or version-specific metadata schema. |
| Shared history and native agents | Retain original JSONL and full session companion directories in place. Validate history syntax, unique main transcript, referenced native agent histories and sidecars; recheck hashes during commit. |
| Files and folders | Preserve workspace/worktree paths and effective additional-directory access. Bring all session-owned companion entries, including hidden/binary/new-format files and empty directories. Retain original payload paths and union non-conflicting historical target attachments. |
| Pending input | Preserve raw manifests and ordering; verify referenced blob hashes. Install target ownership before source manifest removal. No prompt is sent by Switch. |
| Persisted presentation | Merge selected task state from known renderer store namespaces while preserving unknown scoped fields. Preserve the target credential keyspace. Save a conversation-owned snapshot for delayed account switching and the Add account follow-up. |
| External worker information | Stable session IDs, original history, workspace/run paths and external directories remain unchanged. Switch does not replace these with a summary or spawn replacement workers. |
| Server-only resources | Preserve references and descriptive metadata. Access remains controlled by the target account; no remote resource transfer or new authorization is performed. |

Detailed exclusions are in [session fields](session-fields.md). Storage ownership is an allow-list boundary; ordinary contents inside it use default preservation. Shared account catalogs and unknown credential stores are not guessed to belong to one selected conversation.

## Persisted renderer state

`ConversationPresentation` handles the side-pane store family, terminal tab/prompt-line, side-chat and session-scroll stores. It selects local Code session entries by stable IDs, retains opaque scoped values and merges unrelated target entries. A representation-version conflict stops instead of guessing how to reinterpret it.

`LevelDBSnapshot` operates on stopped/offline snapshots. It follows CURRENT/MANIFEST membership, reads only active tables and applicable WALs, resolves sequence numbers and tombstones, verifies CRC32C and fragmented records, and supports raw/Snappy table blocks. Malformed or unsupported storage stops before replacements. The complete target keyspace is rebuilt after the scoped merge, so unrelated keys are retained without importing source authentication.

The format implementation follows the primary [LevelDB log](https://github.com/google/leveldb/blob/main/doc/log_format.md), [table](https://github.com/google/leveldb/blob/main/doc/table_format.md) and [version-edit](https://github.com/google/leveldb/blob/main/db/version_edit.cc) contracts. It has no third-party production dependency.

A credential-free presentation snapshot lives under `claude-code-sessions/<account>/<org>/switch-presentation/<sessionId>.json`. It is part of the conversation transaction and follows subsequent transfers. It is not stored solely in the seven-day login recovery archive. When transferring an inactive account's conversation, the account's saved snapshot can supply persisted presentation. When the target is already active, presentation is installed in the same transaction; otherwise the next account switch restores it.

A saved presentation can outlive its recorded CLI binding. Reuse requires the same stable Desktop session ID, valid file digests and UUID bindings, no previous-CLI reference in any logical key/value, and an exact keyspace match after selecting only that stable session ID into an empty store. Only then may the normal transaction rebuild the sidecar with the current CLI binding; the presentation payload is retained. A different session, previous-engine reference, lost/unrelated state or malformed storage still stops the operation. Transcript bindings and conversation indexes retain their existing identity checks.

Persistent `launch-preview-*` browser partitions can reuse authentication under stable session IDs. When persistent contexts are configured and present, the operation stops and directs the user to disable persistent browser storage in Claude. Switch does not erase those mixed stores or silently confer their credentials. Browser layout/reference data is distinct from website authentication.

## Transaction and failure recovery

1. Resolve the main conversation's complete graph from current indexes; preview exact source/target and companion expectations.
2. Require normal Claude shutdown and wait for its managed workers to stop. Never kill them.
3. Capture final records/resources and persisted presentation. Revalidate stable identities, ancestry, workspaces and previewed targets; retain newly flushed ordinary metadata.
4. Stage the login, complete destination graph, resources and conversation-owned presentation. Check that both originals and replacements fit recovery limits before any rename.
5. Install every destination. Verify installed hashes, target parent-child relationships and unchanged shared histories before removing any source index or pending manifest.
6. Remove source ownership with exact final fingerprints; verify again and commit. On failure, recover in reverse order. Preserve unexpected conflicting data in quarantine.
7. Reopen Claude after commit or confirmed rollback. Retain existing bounded login observation; do not report native UI/server acceptance merely because local files were committed.

Limits are explicit stops, never truncation: resource snapshots and LevelDB input are bounded; oversized recovery, unsafe paths, unknown authorization operations and conflicting artifacts keep the originals. Resource payloads stay outside login-backup retention. A failed encrypted archive retains its recoverable transaction files.

## Verification

Synthetic fixtures cover:

- Nested main/child trees, archived descendants, native parent precedence, missing parents, cycles, duplicates, detached sessions, child activity and root-only UI selection/search/task grouping.
- Unknown ordinary fields, nested structures, large integer values, native agent history and metadata, hidden/binary attachments, empty directories and effective folder grants.
- Queue message identity and blob presence/hash failures, stale target queues and resource conflicts; no source cleanup on failed verification.
- Interruption before every transaction entry, restart recovery, post-staging source mutation, corrupted installed targets and recovery-capacity rejection before any rename.
- Source credential exclusion, target credential preservation, unknown scoped presentation fields, schema conflicts, delayed presentation restoration and retention after transaction pruning.
- Native Chromium fixture interoperability: create an isolated synthetic profile, rebuild its WAL-backed storage, reopen with Chromium, then read/rebuild its compacted Snappy tables and reopen again. This uses no real user profile.
- Standard and write-enabled test suites, localization catalogs and demo-only screenshot rendering.

The native compatibility check is opt-in; see `scripts/check-chromium-fixture.mjs`. Production app code never launches Chrome for migration. Real Claude account switching, native tree rendering after a real login change and real remote-service access are separate acceptance steps, not claimed by fixture results.

## Runtime boundaries

This is data migration, not a process checkpoint. In-memory WebContents, unsaved editor buffers, PTYs, in-flight tools and external workers cannot be reconstructed from persisted indexes. The normal quit must succeed. Switch issues no task-resume command and does not replay uncertain side effects. Claude may still apply its own native startup/queued-input behavior.
