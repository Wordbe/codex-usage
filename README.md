<p align="center">
  <img src="docs/assets/codexusage-icon.svg" width="112" alt="CodexUsage icon">
</p>

<h1 align="center">CodexUsage</h1>

<p align="center">
  A small open-source macOS menu bar app that shows Codex 5-hour usage as a percentage and bar.
</p>

<p align="center">
  <a href="https://github.com/Wordbe/codex-usage/releases/latest/download/CodexUsage.dmg">Download latest DMG</a>
  ·
  <a href="LICENSE">MIT License</a>
</p>

한국어 문서는 [README.ko.md](README.ko.md)를 참고하세요.

## Download And Install

1. Download the latest [CodexUsage.dmg](https://github.com/Wordbe/codex-usage/releases/latest/download/CodexUsage.dmg).
2. Open the DMG.
3. Read `READ BEFORE INSTALL - Open Anyway Guide.txt` inside the DMG.
4. Double-click `CodexUsage.app`.

If macOS shows `"CodexUsage" Not Opened`, open **System Settings > Privacy & Security**, click **Open Anyway** for CodexUsage, then double-click `CodexUsage.app` again.

On first launch from the DMG, CodexUsage copies itself to `~/Applications/CodexUsage.app`, starts the installed copy, creates a login item, and links the CLI at `~/.codexusage/bin/codexusage`.

CodexUsage does not edit your Codex `config.toml` or Codex status line unless you enable account switching.

## Open Source

CodexUsage is released as an open-source project under the [MIT License](LICENSE).

The repository includes:

- Swift source code for the macOS menu bar app.
- DMG build and GitHub release scripts.
- The SVG product icon at [docs/assets/codexusage-icon.svg](docs/assets/codexusage-icon.svg).
- English and Korean installation docs.
- Self-installing app launch from the DMG.
- The optional `codex-account` helper at [tools/codex-account](tools/codex-account).

Issues and pull requests are welcome at [Wordbe/codex-usage](https://github.com/Wordbe/codex-usage).

Security issues should be reported privately. See [SECURITY.md](SECURITY.md).

## Build

```bash
swift build -c release
scripts/build-dmg.sh 0.2.0
```

The DMG is written to `dist/CodexUsage-0.2.0.dmg`.

## CLI

```bash
~/.codexusage/bin/codexusage status
~/.codexusage/bin/codexusage status --json
~/.codexusage/bin/codexusage status --refresh
~/.codexusage/bin/codexusage status --diagnose
```

If the GUI app cannot find Codex, set:

```bash
export CODEXUSAGE_CODEX_PATH="$(command -v codex)"
```

## Account Switching (Optional)

Account switching is off by default. Choose **Enable Account Switching...** in the
menu to install the bundled `codex-account` helper at
`~/.codexusage/bin/codex-account`. It needs Python 3.11 or later
(for example `brew install python`); set `CODEXUSAGE_PYTHON` to pick one.

Once enabled, the menu lists your saved accounts with their last seen 5-hour and
weekly usage. Click an account to switch:

1. The helper quits the ChatGPT app. macOS asks once to let CodexUsage control ChatGPT.
2. It saves the current login and writes the selected one to `~/.codex/auth.json`.
3. It verifies the account with ChatGPT's bundled Codex, rolls back on failure, and reopens ChatGPT.

**Add Account...** opens Terminal and runs `codex-account add` (device-code login).
Logins and backups are kept in `~/.codex-accounts` with owner-only permissions.
They contain credentials, so do not share them. Switching sets
`cli_auth_credentials_store = "file"` in `~/.codex/config.toml` and backs up the
previous file.

The helper also works as a CLI when `python3` on your PATH is 3.11 or later:

```bash
~/.codexusage/bin/codex-account
~/.codexusage/bin/codex-account list
~/.codexusage/bin/codex-account switch <name>
~/.codexusage/bin/codex-account add
```

**Disable Account Switching...** removes the helper. Saved logins in
`~/.codex-accounts` are kept.

## Usage Source And Sync

CodexUsage follows the ChatGPT desktop app's file-based authentication at
`~/.codex/auth.json`. It explicitly uses `CODEX_HOME=~/.codex`, regardless of the
launching shell's `CODEX_HOME`. The installed ChatGPT app's bundled Codex is
preferred; `CODEXUSAGE_CODEX_PATH` can override executable discovery.

Each fresh read uses one app-server connection:

```text
account/read
account/rateLimits/read
```

The menu and CLI show the account email, plan, and last update time. The menu bar
shows the 300-minute quota window. If that window is absent, it shows `--%`
instead of interpreting missing quota as 0% used. Weekly quota is shown when the
server provides a 10080-minute window.

Cache files are isolated by a hash of the user and workspace identity:

```text
~/.codexusage/cache/accounts/<identity-hash>.json
```

Tokens are never written to the usage cache. Old unscoped caches are not reused.
API-key and keychain-only authentication are not supported by this file-based
account tracking. Usage tracking alone does not change your authentication settings.

Policy:

- Usage syncs every 60 seconds; cache TTL is 30 seconds.
- Account identity is checked every 2 seconds, including while the menu is open.
- Switching accounts clears the display and triggers a fresh read without restarting CodexUsage.
- Responses from a previous account are discarded; cached fallback is limited to the same user and workspace.
- `status --refresh` bypasses the fresh cache. On failure, an explicitly marked same-account stale cache may be returned for up to 6 hours; the menu bar hides stale percentages.
- Session logs are diagnostic only and never supply the default displayed quota.
- `status --diagnose` compares API, cache, and session values; a session may belong to a different account.

Other CodexUsage files stay under `~/.codexusage`, except the login item plist in
`~/Library/LaunchAgents`.

## Tests

```bash
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
```

The Python tests need Python 3.11 or later. They use the debug binary built by
`swift test`, a local fake app-server, and fake account logins. They do not use real credentials or make network requests.

## GitHub Release

After this directory is a GitHub repository with an `origin` remote:

```bash
scripts/release-github.sh v0.2.0
```
