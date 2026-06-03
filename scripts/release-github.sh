#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

if [[ -z "${VERSION}" ]]; then
  echo "Usage: scripts/release-github.sh v0.1.0"
  exit 2
fi

cd "${ROOT_DIR}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "This directory is not a git repository. Initialize it and add a GitHub remote first."
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "No origin remote found. Add a GitHub remote first."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login"
  exit 1
fi

"${ROOT_DIR}/scripts/build-dmg.sh" "${VERSION#v}"

NOTES_FILE="${ROOT_DIR}/dist/release-notes-${VERSION}.md"
cat > "${NOTES_FILE}" <<EOF
# CodexUsage ${VERSION}

- macOS menu bar Codex 5-hour usage meter.
- Uses Codex app-server rate-limit data with local caching under ~/.codexusage.
- Download the DMG, open it, read "READ BEFORE INSTALL - Open Anyway Guide.txt", then run "Install CodexUsage.command".
- If macOS blocks the unsigned installer, Control-click it and choose Open, or use System Settings > Privacy & Security > Open Anyway.
- Does not edit Codex config.toml or the Codex status line.
- Unsigned DMG. See the included Gatekeeper Guide.
EOF

gh release create "${VERSION}" \
  "${ROOT_DIR}/dist/CodexUsage-${VERSION#v}.dmg" \
  --title "CodexUsage ${VERSION}" \
  --notes-file "${NOTES_FILE}"
