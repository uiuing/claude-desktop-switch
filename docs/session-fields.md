# Code conversation preservation policy

The boundary is layered: allow only established storage ownership locations; inside those locations preserve ordinary data by default; exclude evidenced identity, credentials, grants and unusable live handles. This is not a whitelist of title/model/settings fields, and there is no per-Claude-version gate for opaque metadata.

## Complete records and relationships

Indexes retain their complete JSON values, including future fields, nested objects, integer metadata, titles, model/effort preferences, workspace/worktree/branch associations, artifacts, cloud task descriptions and links, scheduling descriptions, interrupted intent and native lineage. Serialization may change whitespace and key order. Session and CLI transcript IDs remain unchanged. Native descendants, including archived ones, travel with their main conversation.

Cloud IDs and publication references are retained as information. They do not confer access to the old account's server resources. SSH/WSL destinations remain descriptive execution context; the transfer neither provisions remote access nor restores a remote process.

## Excluded data

The authoritative implementation is [`SessionTransferRecord.swift`](../Sources/SwitchMac/SessionTransferRecord.swift).

| Boundary | Treatment |
| --- | --- |
| Index account identity | Exclude `emailAddress`, `accountId`, `accountUuid`, `organizationId`, `organizationUuid`, `envScopeId` and recognized credential keys. |
| Live bindings | Exclude `bridgeSessionIds`, `remoteControlSpawn`, `remoteControlLiveAtUpdateQuit`, `sshRemoteProcessId` and `sshReattach`. |
| Browser/computer authority | Exclude `chromePermissionMode`, `chromeAllowedDomains`, `cuAllowedApps`, `cuGrantFlags`, `cuFlagsGrantedAt` and `alwaysAllowedReasons`. Persistent browser credential contexts require reauthorization through Claude before transfer. |
| `sessionPermissionUpdates` | Preserve complete `addDirectories` and `removeDirectories` objects. Exclude tool-rule grants and permission-mode operations. An unknown authorization operation stops the transfer. |
| Connector/SSH configuration | Preserve `remoteMcpServersConfig` and `sshConfig` recursively, excluding recognized credentials/authorization headers, cookies, token/secret/password/key fields and SSH identity-file/agent references. Credential-bearing URLs stop the operation. |
| Task presentation stores | Import only scoped task data; exclude recognized embedded credential keys. All other target Local Storage keys remain byte-for-byte values from the target login. |

Credential classification examines keys inside evidenced authorization/presentation boundaries. It does not redact transcript text, attachment bytes or arbitrary task metadata because they contain a word such as “token”. Unknown ordinary fields remain. An as-yet-unidentified credential encoding still requires an explicit policy update; preservation is not proof that every future field has known semantics.

## Files and ownership

`ConversationResources` retains every file and directory inside a selected session/CLI-owned companion root, including hidden files, empty directories and new extensions. Overlapping directories retain both sets of attachments; conflicting content at the same path stops the operation. Target-only pending manifests stop rather than accepting stale work.

Main JSONL histories and complete native subagent directories remain shared in place. Referenced native agent histories must exist; missing or ambiguous histories stop the operation. Working directories, worktrees and effective additional-folder grants must be available. Removed folder grants are not incorrectly required to exist.

Account-scoped waiting-input manifests retain their original message IDs, order, data and future metadata. Blob references must resolve to the expected SHA-256 bytes. The target is verified before the source manifest is removed, so a committed operation has one queue owner. Switch does not send those messages.

Original non-queue companion payload paths remain available for historical references. Active resources never depend solely on a login recovery archive. `switch-presentation/<sessionId>.json` is conversation-owned and contains only selected non-credential view data; it supports a transfer performed before the eventual login switch.

## Revalidation and recovery

The preview and pre-quit check pin source and target fingerprints. After normal quit, Claude may flush ordinary metadata and resources. The final complete values are retained while session identity, transcript identity, ancestry, cwd/worktree and the previewed destinations stay pinned. A changed descendant set stops the operation.

The journal installs all target records, companions and presentation first. It verifies installed hashes, the full target tree and unchanged retained shared histories before source cleanup and again before commit. Each source removal uses its exact final digest. Recovery capacity is checked before the first rename. Old journals keep their original file-level semantics; removing copy capability does not add deletions to old recovery operations.

Failure logs contain fixed operation stages and rollback results, without identities, paths or record contents. See [the integrity contract and verification](session-continuity.md) for coverage and runtime boundaries.
