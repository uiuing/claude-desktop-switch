# Security Policy

Claude Switch handles Claude Desktop login data on your Mac, so security reports are taken seriously.

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Include:

- what an attacker could do and under which conditions,
- steps to reproduce, using a test account where possible,
- the Claude Switch, Claude Desktop and macOS versions.

Never include real tokens, cookies, account IDs or email addresses in a report. Replace them with placeholders.

You should receive an acknowledgement within a few days. Once a fix is released, the advisory is published with credit to the reporter unless you prefer to stay anonymous.

## Scope

In scope:

- exposure of saved logins, tokens or cookies outside the encrypted vault,
- writes to Claude files outside the documented allow-list,
- network requests other than the documented quota, profile and public GitHub release checks, or account data sent with a release check,
- loss of data during a switch or a session transfer that the recovery flow cannot undo.

Out of scope: issues that require an attacker who already runs code as your macOS user, and changes in Claude Desktop's private storage formats (please file those as regular bugs).

How the app protects data is described in [docs/how-it-works.md](../docs/how-it-works.md).
