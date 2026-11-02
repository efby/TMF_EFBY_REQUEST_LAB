#!/bin/bash

# Build the real SwiftPM app, then exercise it through Apple's UI test runner.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UI_BUILD_DIR="$ROOT_DIR/.build/ui-tests"
APP_DIR="$UI_BUILD_DIR/EFBY Request Lab UI Tests.app"
DERIVED_DATA_DIR="$UI_BUILD_DIR/DerivedData"
RESULT_BUNDLE="${EFBY_UI_TEST_RESULT_BUNDLE_PATH:-$UI_BUILD_DIR/Results/$(date +%Y%m%d-%H%M%S)-$$.xcresult}"
TEST_ACTION=test
XCODEBUILD_ARGUMENTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      TEST_ACTION=build-for-testing
      shift
      ;;
    --result-bundle)
      if [[ $# -lt 2 ]]; then
        echo "--result-bundle requires a path" >&2
        exit 2
      fi
      RESULT_BUNDLE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: ./Tools/test_ui.sh [--build-only] [--result-bundle PATH] [xcodebuild arguments]"
      echo "Example: ./Tools/test_ui.sh -only-testing:EfbyRequestLabUITests/RequestLabUITests"
      exit 0
      ;;
    --)
      shift
      XCODEBUILD_ARGUMENTS+=("$@")
      break
      ;;
    *)
      XCODEBUILD_ARGUMENTS+=("$1")
      shift
      ;;
  esac
done

cd "$ROOT_DIR"
swift build --configuration debug --product EfbyRequestLabs
BINARY_DIR="$(swift build --configuration debug --show-bin-path)"

# This bundle has its own identifier and never replaces an installed app.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
ditto "$BINARY_DIR/EfbyRequestLabs" "$APP_DIR/Contents/MacOS/EfbyRequestLabs"
chmod +x "$APP_DIR/Contents/MacOS/EfbyRequestLabs"
for RESOURCE_BUNDLE in "$BINARY_DIR"/*.bundle; do
  if [[ -d "$RESOURCE_BUNDLE" ]]; then
    ditto "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
  fi
done

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>EFBY Request Lab UI Tests</string>
    <key>CFBundleExecutable</key>
    <string>EfbyRequestLabs</string>
    <key>CFBundleIdentifier</key>
    <string>com.efby.requestlabs.uitesting</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>EFBY Request Lab UI Tests</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
export EFBY_UI_TEST_APP_PATH="$APP_DIR"
mkdir -p "$(dirname "$RESULT_BUNDLE")"

XCODEBUILD_COMMAND=(
  xcodebuild "$TEST_ACTION"
  -project "$ROOT_DIR/Tests/UITests/EfbyRequestLabUITests.xcodeproj"
  -scheme EfbyRequestLabUITests
  -configuration Debug
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA_DIR"
  -resultBundlePath "$RESULT_BUNDLE"
  -parallel-testing-enabled NO
  -collect-test-diagnostics never
)
# macOS ships Bash 3.2, where expanding an empty array with set -u is an error.
if [[ ${#XCODEBUILD_ARGUMENTS[@]} -gt 0 ]]; then
  XCODEBUILD_COMMAND+=("${XCODEBUILD_ARGUMENTS[@]}")
fi
"${XCODEBUILD_COMMAND[@]}"
