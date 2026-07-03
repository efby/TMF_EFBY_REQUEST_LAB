#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="EfbyRequestLabs"
APP_NAME="EFBY Request Lab.app"
DIST_DIR="$ROOT_DIR/Distribution"
APP_DIR="$DIST_DIR/$APP_NAME"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_PATH="$DIST_DIR/EFBYRequestLab.dmg"
ZIP_PATH="$DIST_DIR/EFBYRequestLab.zip"
RESOURCES_DIR="$ROOT_DIR/Resources"
SOURCE_LOGO="${EFBY_SOURCE_LOGO:-$RESOURCES_DIR/AppIcon.png}"
SOURCE_LOGO_PREVIEW="$DIST_DIR/logo_source_preview.png"
ICON_PNG="$RESOURCES_DIR/AppIcon.png"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICON_ICNS="$RESOURCES_DIR/AppIcon.icns"
TEAM_ID="${APPLE_TEAM_ID:-FYU5QTGXLB}"
DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-Developer ID Application: EFBY SERVICIOS INFORMATICOS LIMITADA ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-efby-requestlabs-notary}"
ENABLE_SIGNING=0
ENABLE_NOTARIZATION=0

submit_for_notarization() {
  local artifact="$1"
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${TEAM_ID:-}" ]]; then
    echo "Submitting $(basename "$artifact") to Apple notarization (Apple ID credentials)…"
    xcrun notarytool submit "$artifact" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$TEAM_ID" \
      --wait
  else
    echo "Submitting $(basename "$artifact") to Apple notarization (keychain profile: $NOTARY_PROFILE)…"
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)
      ENABLE_SIGNING=1
      shift
      ;;
    --notarize)
      ENABLE_SIGNING=1
      ENABLE_NOTARIZATION=1
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: ./Tools/build_dmg.sh [--sign] [--notarize]"
      exit 1
      ;;
  esac
done

mkdir -p "$DIST_DIR"
mkdir -p "$RESOURCES_DIR"
rm -rf "$APP_DIR" "$DMG_ROOT" "$DMG_PATH" "$ZIP_PATH" "$ICONSET_DIR"

if [ -f "$SOURCE_LOGO" ] && [[ "$SOURCE_LOGO" == *.ai ]]; then
  qlmanage -t -s 1200 -o "$DIST_DIR" "$SOURCE_LOGO" >/dev/null 2>&1
  mv "$DIST_DIR/$(basename "$SOURCE_LOGO").png" "$SOURCE_LOGO_PREVIEW"
  swift "$ROOT_DIR/Tools/generate_app_icon.swift" "$SOURCE_LOGO_PREVIEW" "$ICON_PNG"
elif [ ! -f "$ICON_PNG" ] && [ -f "$SOURCE_LOGO" ]; then
  cp "$SOURCE_LOGO" "$ICON_PNG"
fi

if [ ! -f "$ICON_PNG" ]; then
  echo "Warning: App icon not found at $ICON_PNG — continuing without custom icon."
  touch "$ICON_PNG"
fi

mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"

swift build -c release --arch arm64 --arch x86_64 --product "$PRODUCT_NAME"

BINARY_PATH="$ROOT_DIR/.build/apple/Products/Release/$PRODUCT_NAME"

if [ -z "$BINARY_PATH" ]; then
  echo "Release binary not found."
  exit 1
fi

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>EFBY Request Lab</string>
    <key>CFBundleExecutable</key>
    <string>EfbyRequestLabs</string>
    <key>CFBundleIdentifier</key>
    <string>com.efby.requestlabs</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>EFBY Request Lab</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleURLName</key>
            <string>EFBY AWS portal OAuth callback</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>efbyrequestlabs</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

ditto "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

for RESOURCE_BUNDLE in "$ROOT_DIR"/.build/apple/Products/Release/*.bundle; do
  if [[ -d "$RESOURCE_BUNDLE" ]]; then
    ditto "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
  fi
done

if [[ "$ENABLE_SIGNING" -eq 1 ]]; then
  echo "Signing app with: $DEVELOPER_ID_APP"
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

if [[ "$ENABLE_NOTARIZATION" -eq 1 ]]; then
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  submit_for_notarization "$ZIP_PATH"
  xcrun stapler staple "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

mkdir -p "$DMG_ROOT"
ditto "$APP_DIR" "$DMG_ROOT/$APP_NAME"
ln -sfn /Applications "$DMG_ROOT/Applications"

hdiutil create -volname "EFBY Request Lab" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH"

if [[ "$ENABLE_SIGNING" -eq 1 ]]; then
  echo "Signing DMG with: $DEVELOPER_ID_APP"
  codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG_PATH"
fi

if [[ "$ENABLE_NOTARIZATION" -eq 1 ]]; then
  submit_for_notarization "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "App created at: $APP_DIR"
echo "DMG created at: $DMG_PATH"

if [[ "$ENABLE_NOTARIZATION" -eq 1 ]]; then
  echo "Signing and notarization completed."
elif [[ "$ENABLE_SIGNING" -eq 1 ]]; then
  echo "Signing completed."
else
  echo "Local build completed without signing or notarization."
fi
