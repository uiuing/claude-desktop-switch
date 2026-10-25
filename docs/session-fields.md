# Code session transfer fields

Claude Switch transfers the selected Code session index as a complete JSON object, removing account authorization, cloud bindings and live connection state through `SessionTransferRecord`. Local transcripts remain in place. JSON formatting and key order may change; nested values and integer metadata are preserved.

## Preserved data

- Session and transcript IDs, titles, models, effort, permission modes and their provenance.
- Working directories, worktrees, branches, PR metadata and repository associations.
- Local preferences, resume settings, history, local task lineage and display selection.
- SSH/WSL execution targets and transcript locations. Transferring an index does not provision remote access or move external resources.
- New fields and nested metadata outside the explicit exclusions below.

## Excluded data

The complete top-level exclusion list lives in [`SessionTransferRecord.swift`](../Sources/SwitchMac/SessionTransferRecord.swift). It covers:

| Category | Examples |
| --- | --- |
| Account and connector authorization | `emailAddress`, `envScopeId`, `enabledMcpTools`, `remoteMcpServersConfig`, `withheldConnectorHosts` |
| Browser and computer-use grants | `chromePermissionMode`, `chromeAllowedDomains`, `cuAllowedApps`, `cuGrantFlags`, `sessionPermissionUpdates` |
| Live connections and processes | Bridge IDs, remote-control state, SSH process and reattachment state, prior screenshot geometry |
| Cloud handoffs and tasks | `cloudSessionId`, `movedToCloud`, `cloudSpawnedTasks`, `spaceId`, `scheduledTaskId`, `scheduledRunContinued` |
| Cloud publications and process settings | `publishedArtifacts`, `armedWorkAtQuit`, `violinBow` and its settings/prompt companions |

Some containers need narrower cleanup:

| Path | Handling |
| --- | --- |
| `dispatchParentId`, `dispatchParentOrigin` | Keep only explicitly local ancestry. |
| `pendingFirstStart.options.remoteControlAtStart` | Remove this member; preserve other startup options. |
| `backgroundTaskSuggestions` | Remove cloud suggestions. Keep local suggestions and remove unused cloud environment/pool choices from them and their accepted choices. |
| `resolvedBackgroundTaskSuggestions` | Remove results belonging to removed cloud suggestions or cloud child tasks. |

## Source selection and validation

The current account's copy is authoritative for followed sessions, including preference changes without new activity. If it has no copy and the target already does, the target stays intact. A fallback from another account is offered only when the target has no copy. An archived current copy is not resurrected from a different account. Manual transfers use the explicitly selected source and show target replacements in the preview.

Every transfer requires valid JSON, matching session and transcript IDs, an absolute working directory, an available local transcript and a verified destination. The preview and pre-quit check require exact source and destination file fingerprints. After Claude quits, source formatting and already-excluded state may differ only when `SessionTransferRecord` produces identical transfer bytes to the pre-quit check. Every preserved field, including unknown metadata, must remain unchanged; destination fingerprints stay exact. Source removals use the exact post-quit digest, so later writes still stop removal. Unsafe paths and conflicting identities stop the operation. Writes and target replacements use the same journal and rollback as account switching.

Transaction failures log only their fixed operation stage and rollback outcome to the macOS log (`dev.claudeswitch.desktop`, category `operations`). Account identities, paths, record contents and error descriptions are not logged.

Claude owns the metadata format. Preserving unknown fields avoids discarding ordinary settings, but does not establish that every future field is safe to carry between accounts. Add a specific exclusion when an account-bound field is identified; do not infer authorization from keywords in arbitrary metadata or user content.
