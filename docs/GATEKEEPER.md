# Gatekeeper Guide

CodexUsage is unsigned, so macOS may show this warning:

`Apple cannot verify that CodexUsage is free of malware.`

This is expected for an unsigned build.

## Install

1. Open the DMG.
2. Read `READ BEFORE INSTALL - Open Anyway Guide.txt`.
3. Double-click `Install CodexUsage.command`.
4. If macOS blocks it, Control-click `Install CodexUsage.command`.
5. Choose `Open`.
6. Click `Open` again if macOS asks.

Do not open `CodexUsage.app` directly from the DMG.

The installer copies the app to `~/Applications`, removes quarantine from the installed copy, and starts CodexUsage.

CodexUsage keeps its cache, backups, and CLI helper in `~/.codexusage`.

## If The App Is Still Blocked

If you already copied the app and macOS closes it, run this in Terminal:

```bash
xattr -dr com.apple.quarantine ~/Applications/CodexUsage.app
open ~/Applications/CodexUsage.app
```

CodexUsage appears in the menu bar and starts automatically after login.

CodexUsage does not edit your Codex `config.toml` or Codex status line.
