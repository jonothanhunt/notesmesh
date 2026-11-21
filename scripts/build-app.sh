#!/bin/zsh
# Builds "Notes Mesh.app" with swiftc (Xcode's Command Line Tools are enough).
#
#   scripts/build-app.sh            → build/Notes Mesh.app, signed for this Mac
#   scripts/build-app.sh install    → … and copies it to ~/Applications
#   scripts/build-app.sh debug      → includes test hooks (--click-channel); never ship this
#   scripts/build-app.sh release    → Developer ID signed, hardened, zipped and (with a notary
#                                     profile) notarized and stapled: build/NotesMesh.zip
#
# The app icon is Resources/NotesMesh.icon (made in Icon Composer). With Xcode installed it's
# compiled into a Liquid Glass icon; without Xcode, Resources/AppIcon.icns is used instead.
#
# Environment:
#   NOTESMESH_BUNDLE_ID  bundle identifier (default below; change it for your own fork)
#   NOTARY_PROFILE       a `xcrun notarytool store-credentials` profile name, for release
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:-}
NAME="Notes Mesh"
EXEC=NotesMesh
BUNDLE_ID=${NOTESMESH_BUNDLE_ID:-io.github.jonothanhunt.notesmesh}
VERSION=0.1.0
BUILD_NUMBER=$(date +%Y%m%d%H%M)
APP="build/$NAME.app"
ZIP=build/NotesMesh.zip
FLAGS=()
[[ "$MODE" == "debug" ]] && FLAGS+=(-D NOTEMESH_DEBUG)

mkdir -p build
echo "Compiling…"
swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos26.0" \
  -module-name NotesMesh \
  "${FLAGS[@]}" \
  Sources/NotesMesh/*.swift \
  -o "build/$EXEC"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$EXEC" "$APP/Contents/MacOS/$EXEC"
cp -R Web/fonts "$APP/Contents/Resources/Fonts"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

# The Liquid Glass icon, when Xcode's asset compiler is available.
ICON_NAME_KEY=""
if [[ -d Resources/NotesMesh.icon ]] && xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Resources/NotesMesh.icon --compile "$APP/Contents/Resources" \
    --app-icon NotesMesh --platform macosx --target-device mac --minimum-deployment-target 26.0 \
    --output-partial-info-plist build/icon-info.plist >/dev/null
  ICON_NAME_KEY="<key>CFBundleIconName</key><string>NotesMesh</string>"
  echo "Icon: Liquid Glass (NotesMesh.icon)"
else
  echo "Icon: AppIcon.icns (install Xcode to compile the Liquid Glass icon)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  $ICON_NAME_KEY
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Open source under the MIT License.</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSAppleEventsUsageDescription</key><string>Notes Mesh asks Notes to open the note you choose. It never changes or deletes notes.</string>
</dict>
</plist>
PLIST

# Hardened runtime everywhere, so what you test is what ships.
SIGN=(--force --options runtime --entitlements Resources/NotesMesh.entitlements)

if [[ "$MODE" == "release" ]]; then
  IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  if [[ -z "$IDENTITY" ]]; then
    echo "release needs a 'Developer ID Application' certificate in your keychain." >&2
    exit 1
  fi
  codesign "${SIGN[@]}" --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "Notarizing…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
  else
    echo "Set NOTARY_PROFILE to notarize (see README → Releasing)."
  fi
  echo "Signed with: $IDENTITY"
  echo "Built $ZIP"
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
  rm -rf ~/Applications/"$NAME.app"
  cp -R "$APP" ~/Applications/"$NAME.app"
  echo "Installed to ~/Applications/$NAME.app"
fi
