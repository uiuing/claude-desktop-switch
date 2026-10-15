# Claude Code task status

Settings → Menu bar → **Show Claude Code task status** controls the count beside the quota percentage and the menu's task section. It is on by default. The list covers local Claude Code engines owned by the current Claude Desktop instance, not terminal/editor sessions, cloud sessions or Cowork. Existing quota warning badges remain separate.

Followed conversations appear first, including followed conversations whose process is no longer running. The remaining rows are grouped by waiting, running, unknown and a collapsed idle section. Titles and project folders come from Desktop's Code indexes. Hover shows the full title, status and folder. Clicking a row opens the conversation in Claude; it does not send a prompt, grant permission or change accounts. Navigation is disabled in read-only builds. Demo mode only shows a preview message.

Menu navigation closes the popover through its native status-button action. Closing the window alone can leave MenuBarExtra selected and consume the next click without reopening it. The close/reopen regression is checked with an isolated synthetic MenuBarExtra and fixture-only AppKit tests; it does not open a real Claude conversation.

## Explicit states

| Published registry value | Display |
| --- | --- |
| `status: busy` or `shell` | Running |
| `status: waiting`, `waitingFor: permission prompt` | Waiting for permission |
| `status: waiting`, `waitingFor: input needed` | Waiting for your reply |
| `status: waiting`, other or absent reason | Waiting for you |
| `status: idle` | Idle |
| No matching live engine, with complete process/record coverage | Not running, for followed conversations |
| Missing, unsupported, ambiguous or unreadable evidence | Unknown / counts unavailable |

Idle is not completion. The reader does not report thinking, tool names, progress percentages, success, failure or pause without an explicit source. No timestamp, file modification age or transcript activity decides task state. The menu bar hides the entire task segment while reconnecting, switching, offline or unable to establish complete coverage; it shows no placeholder or separator. The popover can still explain unavailable states. Zero means a complete snapshot contained no running or waiting task.

The status item receives one composed image containing the quota and any available task counts. MenuBarExtra's native title/image extraction does not preserve a normal SwiftUI layout with several text and image segments; a standalone SwiftUI screenshot is not sufficient to verify the actual menu bar label.

When the confirmed running count is above zero, its indicator rotates once every 1.5 seconds, targeting 60 frames per second. The monochrome arc has a bright head and a fading tail; it follows the menu bar's white or black foreground, and the waiting icon uses the same neutral palette. A monotonic clock keeps rotation speed stable when a frame is delayed. The animation stops while waiting, idle, disabled, sleeping, switching or unavailable, and respects macOS Reduce Motion. A bounded ninety-frame cache avoids repeatedly laying out the whole label. Demo screenshots use a fixed frame; native animation is checked with synthetic task states in an isolated fixture app.

## Read-only adapter and identity

Anthropic documents [`claude agents --json --all`](https://code.claude.com/docs/en/agent-view#read-session-state-from-a-script) as the scripting interface. Switch does not execute it: CLI startup and registry cleanup can write files. Instead, `CodeTaskSource` takes native process snapshots and `CodeTaskReader` reads the same private PID registry with `SafeFiles`.

- A native process must descend from the single running Claude Desktop instance. Nested Code engines are not counted as additional tasks. No command line, process environment, transcript body or peer credential is inspected.
- Only `claude-desktop` and `claude-desktop-3p` interactive registrations are accepted. Prewarmed spare engines are excluded. A missing registration for a candidate engine makes the count unavailable.
- The registry PID and UTC `procStart` must match the native process birth. Registration time must be after that birth, protecting against PID reuse within one second. Process snapshots before and after the file reads must agree.
- The running Desktop login must match the requested account before and after the scan. A task must match a fresh index in that account and organization by both `hostSessionId` and `cliSessionId`. A host index present in multiple organizations is ambiguous and is not attributed. The CLI ID alone is insufficient because transfers can preserve it across accounts.
- File reads are bounded, reject symlinks and tolerate torn records by reporting incomplete coverage. Each snapshot accepts at most 128 root engines, 100 followed indexes and 16 MiB. Nothing is written to Claude's data, no hooks are installed, and no new network request or Keychain query is used by this feature.
- The standard `~/.claude/sessions` registry is supported. Missing fields in older engines or a custom registry location produce unavailable state rather than a fallback estimate. Format inspection used the official Claude Code 2.1.301 distribution; this is a private, version-sensitive adapter.

The poll runs every two seconds after startup access is ready, while enabled and awake. It is independent of quota refresh scheduling. State is never persisted. Account changes, operations and lifecycle changes invalidate pending reads with an epoch; previously associated process instances cannot be reused for a new account. A failed operation also requires a fresh inventory and process association. Late results from an earlier account are discarded, including A → B → A transitions.

Task polling caches only the signed-in result and its expiry in memory, scoped to the account, organization and native Desktop process birth. Every context check still validates safe paths and the inode, size and modification time of Cookies, WAL and rollback journal. An unchanged result is reused for at most sixty seconds and never past the supporting cookie's expiry. Changed files, clock rollback, process or scope changes and uncertain reads discard the cached evidence. Both account and process checks still run before and after reading tasks. General login capture and switching continue using uncached checks.

The conversation link follows Desktop's own local-session link format, `claude://claude.ai/epitaxy/<sessionId>`, statically inspected in Desktop 2.42304.0. Before opening it, Switch revalidates the account, index and current binding and directs the URL to the installed Claude app. Desktop ultimately handles navigation and may reject links if deep links are disabled by policy or its route changes. Opening a URL successfully is not proof that the conversation rendered.

## Validation boundary

All automated checks use synthetic records under `.build/` or `AppState(demo: true)`. They cover explicit states, changed titles, waiting reasons, malformed/oversized/symlinked records, PID reuse, other entrypoints, duplicate sessions, ambiguous organizations, followed ordering, epoch invalidation, rollback, navigation target validation and the settings toggle. Screenshots are generated with `scripts/screenshots.sh` in English, German and Simplified Chinese, light and dark. No running-Claude acceptance, account switch, real-data read or real deep-link dispatch is part of these checks.
