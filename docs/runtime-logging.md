# Runtime logging

`RuntimeLog` is the single event boundary for runtime diagnostics. Callers supply typed levels, components, events, stages and validation checks. They never supply a free-form message or arbitrary metadata dictionary. `RuntimeFailure` reduces errors to a fixed category and, for Cocoa/POSIX/OSStatus, a numeric code; it does not inspect or serialize error descriptions or `userInfo`.

## Storage and retention

- Location: `~/Library/Logs/Claude Switch/`.
- Files: `runtime.jsonl` plus `runtime.1.jsonl` through `runtime.4.jsonl`, newest first.
- Limit: 1 MiB per file, at most five files. Rotation happens before an append would exceed the limit. The oldest file is removed; existing history survives app restarts.
- Access: directory mode `0700`, file mode `0600`; symbolic links and non-regular files are rejected.
- A single actor serializes append, rotation and export. Errors are synced before their awaited logging call returns. A partial final line is rotated before new events are appended.
- File-sink failures are reported through the same service to the macOS system log, without recursion. Startup reports an unavailable file sink; reports mark unreadable or malformed history as incomplete.

The app enables file logging before the account-access gate. Demo mode, fixture tests and `switch-inspect` leave the shared file sink disabled. The system-log mirror uses subsystem `dev.claudeswitch.desktop`, category `runtime`; there are no separate per-file loggers.

## Event schema

Each JSON line has schema version 1, a UTC ISO 8601 timestamp, per-run sequence, random run ID, app version/build, executable SHA-256 (`buildID`), severity, component and event. Optional fields identify the operation UUID, fixed stage, error category/code, validator source/line, validation check and quota failure kind. Only operation UUIDs created by the transaction planner are used for correlation; account and conversation IDs are not logged. The executable fingerprint distinguishes local builds that share a product version.

`RuntimeLogContext` carries the operation ID through switching and recovery, including validation callbacks. Awaited operation events record start, preparation phases, completion, failure and rollback outcomes. Synchronous validators enqueue typed events through this service. General application errors, startup access failures, quota errors and update failures use the same schema.

Tokens, cookies, emails, account/session IDs, titles, conversation bodies, attachments, private paths, request headers and arbitrary server/error text never enter the event API. Source locations are fixed enum names and line numbers, not absolute build paths.

## Export and feedback

Settings → About and failed-operation notices offer **Export diagnostics…**. A save panel chooses the destination. The JSON report contains retained typed events plus app/macOS version and CPU architecture. It does not read credentials, query the Keychain, add conversation files or issue network requests. The existing **Report an issue** link opens GitHub; the user chooses whether to attach the exported report.

Export decodes and re-encodes the known schema. Foreign fields are dropped, invalid records are skipped, and version/fingerprint strings are validated. The report's `incomplete` field is true if writing, reading or decoding history failed. A report contains only retained history; rotation does not claim full lifetime coverage.

## Adding diagnostics

Use `RuntimeLog.shared.record` in async paths and `RuntimeLog.validation` for synchronous validators. Use `RuntimeLog.failure` for synchronous application error presentation. Add a typed event/check when a new failure boundary needs distinction; never interpolate private data into a log line. Successful operations may carry warning events for a failed recovery archive or manual reopen requirement.

Fixture tests cover concurrent append and operation context, retention limits, permissions, restart and partial-tail recovery, unsafe paths, disabled sinks and export filtering. Switching fixtures separately cover stale display bindings, retained payloads and transaction rollback. Real account switching remains a separate acceptance step.
