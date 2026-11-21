#!/bin/zsh
# Builds NoteMesh.app with swiftc (Xcode's Command Line Tools are enough).
#
#   scripts/build-app.sh            → build/NoteMesh.app, signed for this Mac
#   scripts/build-app.sh install    → … and copies it to ~/Applications
#   scripts/build-app.sh debug      → includes test hooks (--click-channel); never ship this
#   scripts/build-app.sh release    → Developer ID signed, hardened, zipped and (with a notary
#                                     profile) notarized and stapled: build/NoteMesh.zip
#
# Environment:
#   NOTEMESH_BUNDLE_ID   bundle identifier (default below; change it for your own fork)
#   NOTARY_PROFILE       a `xcrun notarytool store-credentials` profile name, for release
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:-}
BUNDLE_ID=${NOTEMESH_BUNDLE_ID:-io.github.jonothanhunt.notemesh}
VERSION=0.1.0
BUILD_NUMBER=$(date +%Y%m%d%H%M)
APP=build/NoteMesh.app
FLAGS=()
[[ "$MODE" == "debug" ]] && FLAGS+=(-D NOTEMESH_DEBUG)

mkdir -p build
echo "Compiling…"
swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos26.0" \
  -module-name NoteMesh \
  "${FLAGS[@]}" \
  Sources/NoteMesh/*.swift \
  -o build/NoteMesh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/NoteMesh "$APP/Contents/MacOS/NoteMesh"
cp -R Web/fonts "$APP/Contents/Resources/Fonts"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NoteMesh</string>
  <key>CFBundleDisplayName</key><string>NoteMesh</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>NoteMesh</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Open source under the MIT License.</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSAppleEventsUsageDescription</key><string>NoteMesh asks Notes to open the note you choose. It never changes or deletes notes.</string>
</dict>
</plist>
PLIST

# Hardened runtime everywhere, so what you test is what ships.
SIGN=(--force --options runtime --entitlements Resources/NoteMesh.entitlements)

if [[ "$MODE" == "release" ]]; then
  IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  if [[ -z "$IDENTITY" ]]; then
    echo "release needs a 'Developer ID Application' certificate in your keychain." >&2
    exit 1
  fi
  codesign "${SIGN[@]}" --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  rm -f build/NoteMesh.zip
  ditto -c -k --keepParent "$APP" build/NoteMesh.zip
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "Notarizing…"
    xcrun notarytool submit build/NoteMesh.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f build/NoteMesh.zip
    ditto -c -k --keepParent "$APP" build/NoteMesh.zip
  else
    echo "Set NOTARY_PROFILE to notarize (see README → Releasing)."
  fi
  echo "Signed with: $IDENTITY"
  echo "Built build/NoteMesh.zip"
  exit 0
fi

# Everyday builds: an Apple Development identity if there is one, so macOS keeps the
# Full Disk Access grant across rebuilds (ad-hoc signing loses it every time).
IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign "${SIGN[@]}" --sign "${IDENTITY:--}" "$APP" >/dev/null
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "$MODE" == "install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/NoteMesh.app
  cp -R "$APP" ~/Applications/NoteMesh.app
  echo "Installed to ~/Applications/NoteMesh.app"
fi
