# CodexUsage

CodexUsage is a macOS menu bar app that shows Codex usage as a percentage and bar.

한국어 문서는 [README.ko.md](README.ko.md)를 참고하세요.

## Download And Install

1. Download the latest `CodexUsage-*.dmg` from [GitHub Releases](https://github.com/Wordbe/codex-usage/releases/latest).
2. Open the DMG.
3. Read `READ BEFORE INSTALL - Open Anyway Guide.txt` inside the DMG.
4. Double-click `Install CodexUsage.command`.

If macOS blocks the unsigned installer, Control-click `Install CodexUsage.command`, choose `Open`, then click `Open` again. If it still blocks, open **System Settings > Privacy & Security** and click **Open Anyway** for CodexUsage.

The installer copies the app to `~/Applications/CodexUsage.app`, starts it, creates a login item, and links the CLI at `~/.codexusage/bin/codexusage`.

CodexUsage does not edit your Codex `config.toml` or Codex status line.

## Build

```bash
swift build -c release
scripts/build-dmg.sh 0.1.0
```

The DMG is written to `dist/CodexUsage-0.1.0.dmg`.

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

## Usage Source And Sync

CodexUsage prefers the same session rate-limit event that Codex `/status` uses:

```text
~/.codex/sessions/**/*.jsonl
event_msg.payload.rate_limits.primary.used_percent
```

If no current session event is available, CodexUsage falls back to:

```text
codex app-server --stdio
account/rateLimits/read
rateLimitsByLimitId.codex.primary.usedPercent
```

The primary window is the 5-hour Codex limit. The app displays current 5-hour usage, not weekly usage.

Cache file:

```text
~/.codexusage/cache/rate-limits.json
```

Other CodexUsage files are also kept under `~/.codexusage`, except the macOS login item plist, which must live in `~/Library/LaunchAgents`.

Policy:

- App syncs every 60 seconds.
- Cache TTL is 30 seconds.
- `~/.codexusage/bin/codexusage status --refresh` forces a fresh sync.
- `~/.codexusage/bin/codexusage status --diagnose` compares app-server, cache, and the latest Codex session `token_count` rate-limit event.

## GitHub Release

After this directory is a GitHub repository with an `origin` remote:

```bash
scripts/release-github.sh v0.1.0
```
