#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
APP_NAME="CodexUsage"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
BUILD_DIR="${ROOT_DIR}/.build/release"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
STAGE_DIR="${DIST_DIR}/dmg-stage"

cd "${ROOT_DIR}"
swift build -c release

rm -rf "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${STAGE_DIR}"

cp "${BUILD_DIR}/codexusage" "${APP_DIR}/Contents/MacOS/codexusage"
chmod +x "${APP_DIR}/Contents/MacOS/codexusage"

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>codexusage</string>
    <key>CFBundleIdentifier</key>
    <string>com.ree.codexusage</string>
    <key>CFBundleName</key>
    <string>CodexUsage</string>
    <key>CFBundleDisplayName</key>
    <string>CodexUsage</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

cp "${ROOT_DIR}/docs/GATEKEEPER.md" "${APP_DIR}/Contents/Resources/Gatekeeper Guide.md"
cp "${ROOT_DIR}/docs/OPEN_ANYWAY_GUIDE.txt" "${APP_DIR}/Contents/Resources/READ BEFORE INSTALL - Open Anyway Guide.txt"

codesign --force --deep --sign - "${APP_DIR}"

cp -R "${APP_DIR}" "${STAGE_DIR}/${APP_NAME}.app"
cp "${ROOT_DIR}/docs/GATEKEEPER.md" "${STAGE_DIR}/Gatekeeper Guide.md"
cp "${ROOT_DIR}/docs/OPEN_ANYWAY_GUIDE.txt" "${STAGE_DIR}/READ BEFORE INSTALL - Open Anyway Guide.txt"

cat > "${STAGE_DIR}/Install CodexUsage.command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SOURCE="${SOURCE_DIR}/CodexUsage.app"
APP_TARGET="${HOME}/Applications/CodexUsage.app"
CODEXUSAGE_HOME="${HOME}/.codexusage"
BACKUP_DIR="${CODEXUSAGE_HOME}/backups/apps"
BIN_DIR="${CODEXUSAGE_HOME}/bin"
TS="$(date +%Y%m%d-%H%M%S)"

if [[ ! -d "${APP_SOURCE}" ]]; then
  echo "CodexUsage.app was not found next to this installer."
  exit 1
fi

case "${APP_TARGET}" in
  "${HOME}/Applications/CodexUsage.app") ;;
  *)
    echo "Refusing to install to an unexpected path: ${APP_TARGET}"
    exit 1
    ;;
esac

osascript -e 'tell application "CodexUsage" to quit' >/dev/null 2>&1 || true
if pids=$(pgrep -f 'CodexUsage.app/Contents/MacOS/codexusage' 2>/dev/null); then
  while read -r pid; do
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  done <<< "${pids}"
fi

mkdir -p "${HOME}/Applications" "${BACKUP_DIR}" "${BIN_DIR}"
chmod 700 "${CODEXUSAGE_HOME}" "${BACKUP_DIR}" "${BIN_DIR}" 2>/dev/null || true
if [[ -d "${APP_TARGET}" ]]; then
  ditto "${APP_TARGET}" "${BACKUP_DIR}/CodexUsage.app.${TS}"
fi
if [[ -d "/Applications/CodexUsage.app" ]]; then
  echo "Note: /Applications/CodexUsage.app exists and was left untouched."
fi

rm -rf "${APP_TARGET}"
ditto "${APP_SOURCE}" "${APP_TARGET}"
xattr -dr com.apple.quarantine "${APP_TARGET}" 2>/dev/null || true
ln -sf "${APP_TARGET}/Contents/MacOS/codexusage" "${BIN_DIR}/codexusage"
if [[ -L "${HOME}/.local/bin/codexusage" ]]; then
  rm -f "${HOME}/.local/bin/codexusage"
fi
open "${APP_TARGET}"

echo "Installed CodexUsage to ${APP_TARGET}."
echo "CodexUsage data: ${CODEXUSAGE_HOME}"
echo "CLI helper: ${BIN_DIR}/codexusage"
EOF
chmod +x "${STAGE_DIR}/Install CodexUsage.command"

rm -f "${DIST_DIR}/${DMG_NAME}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DIST_DIR}/${DMG_NAME}"

echo "Created ${DIST_DIR}/${DMG_NAME}"
