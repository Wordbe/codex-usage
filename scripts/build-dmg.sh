#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.1}"
APP_NAME="CodexUsage"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
BUILD_DIR="${ROOT_DIR}/.build/release"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
STAGE_DIR="${DIST_DIR}/dmg-stage"
ICON_SVG="${ROOT_DIR}/docs/assets/codexusage-icon.svg"
ICONSET_DIR="${DIST_DIR}/${APP_NAME}.iconset"

cd "${ROOT_DIR}"
swift build -c release

rm -rf "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${STAGE_DIR}"

cp "${BUILD_DIR}/codexusage" "${APP_DIR}/Contents/MacOS/codexusage"
chmod +x "${APP_DIR}/Contents/MacOS/codexusage"

rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"
sips -s format png -z 16 16 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -s format png -z 32 32 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -s format png -z 32 32 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -s format png -z 64 64 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -s format png -z 128 128 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -s format png -z 256 256 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -s format png -z 256 256 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -s format png -z 512 512 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -s format png -z 512 512 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -s format png -z 1024 1024 "${ICON_SVG}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${APP_DIR}/Contents/Resources/CodexUsage.icns"
rm -rf "${ICONSET_DIR}"

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
    <key>CFBundleIconFile</key>
    <string>CodexUsage</string>
    <key>CFBundleIconName</key>
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
cp "${ICON_SVG}" "${APP_DIR}/Contents/Resources/CodexUsage Icon.svg"

codesign --force --deep --sign - "${APP_DIR}"

cp -R "${APP_DIR}" "${STAGE_DIR}/${APP_NAME}.app"
cp "${ROOT_DIR}/docs/GATEKEEPER.md" "${STAGE_DIR}/Gatekeeper Guide.md"
cp "${ROOT_DIR}/docs/OPEN_ANYWAY_GUIDE.txt" "${STAGE_DIR}/READ BEFORE INSTALL - Open Anyway Guide.txt"
cp "${ICON_SVG}" "${STAGE_DIR}/CodexUsage Icon.svg"

rm -f "${DIST_DIR}/${DMG_NAME}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DIST_DIR}/${DMG_NAME}"

echo "Created ${DIST_DIR}/${DMG_NAME}"
