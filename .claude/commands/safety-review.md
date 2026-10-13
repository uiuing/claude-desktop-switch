---
description: Review the current changes against the project's safety rules
---

Review the uncommitted changes (`git diff` and `git diff --staged`; if both are empty, the last commit) against the hard rules in AGENTS.md and the design in docs/how-it-works.md.

Check specifically:

- Writes to Claude's files or processes: do they go through `BuildAccess.requireClaudeWrites()`, `SwitchEngine` and a `FileTransaction`, and are they re-validated right before they happen?
- Allow-list: are only `IdentitySchema` items and whitelisted session index fields touched?
- Failure handling: do unknown formats, changed fingerprints and partial failures stop and roll back, without leaving Claude in a mixed state?
- Network: any new request, host, header or trigger? Anything sent for an account that is not signed in?
- Secrets and personal data: tokens, cookies, emails or account IDs in logs, errors, UI text, tests, fixtures, docs or screenshots?
- Processes: any force quit or kill?
- Localization: new user-facing text present in all ten catalogs?

Report findings ordered by severity with file and line references, and say explicitly when an area has no issues. Do not modify files.
