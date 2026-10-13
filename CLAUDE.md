# CLAUDE.md

@AGENTS.md

## Claude Code in this repository

- **Project commands** (in `.claude/commands/`):
  - `/check` runs the localization check and both test suites and summarizes failures.
  - `/add-string <English text>` adds a user-facing string to all ten catalogs with reviewed translations.
  - `/safety-review` reviews the current diff against the hard rules above.
  - `/screenshots` re-renders the README images and reviews them.
  - `/release <X.Y.Z>` prepares a release (version, changelog, checks) without pushing.
- **Permissions** (`.claude/settings.json`) pre-approve building, testing and the repository scripts, and deny reading Claude's real data folders and `~/.claude.json`, Keychain access through `security`, and killing processes. Put personal overrides in `.claude/settings.local.json`, which is not committed.
- Use plan mode before changing `SwitchEngine`, `FileTransaction`, `CredentialVault`, `MigrationBuilder`, `DesktopTokenReader` or anything in [docs/claude-internals.md](docs/claude-internals.md). Explain in the plan which files of Claude's are read or written and how the change fails closed.
- When a change touches the UI, run `/screenshots` and look at the images: text must not truncate in English or German, and the menu bar panel must still fit.
- Keep answers and commit messages in English unless the maintainer writes in another language.
