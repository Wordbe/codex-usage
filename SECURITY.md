# Security Policy

## Reporting Security Issues

Please report security issues privately to the maintainer instead of opening a public issue.

Use GitHub to contact the repository owner:

https://github.com/Wordbe/codex-usage

Include:

- A short description of the issue.
- Steps to reproduce it.
- The affected version or commit.
- Any relevant logs or screenshots.

## Scope

CodexUsage is a macOS menu bar app that reads Codex usage data from local Codex session files or the local Codex CLI app-server.

CodexUsage should not:

- edit Codex `config.toml`;
- edit the Codex status line;
- collect or upload telemetry;
- require elevated privileges;
- write outside `~/Applications`, `~/.codexusage`, and `~/Library/LaunchAgents/com.ree.codexusage.plist`.

Optional account switching is the exception and runs only after you enable it. The
bundled `codex-account` helper then writes `~/.codex-accounts`, `~/.codex/auth.json`,
and `cli_auth_credentials_store` in `~/.codex/config.toml`, and quits and reopens the
ChatGPT app. It does not upload credentials.
