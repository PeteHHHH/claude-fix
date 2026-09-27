#!/bin/bash
# Archives the app, exports an App Store-signed IPA, and uploads it to
# TestFlight. Requires SCHEME, TEAM_ID, ASC_KEY_ID, and ASC_ISSUER_ID in the
# environment, and the matching AuthKey_<ASC_KEY_ID>.p8 file at
# ~/.appstoreconnect/private_keys/ (the default location altool/Xcode look in).
set -euo pipefail

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

: "${SCHEME:?Set SCHEME (Xcode scheme name)}"
: "${TEAM_ID:?Set TEAM_ID (Apple Developer team ID)}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API key ID)}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect API issuer ID)}"

if [ ! -f "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" ]; then
  echo "Missing $HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" >&2
  exit 1
fi

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$BUILD_DIR/app.xcarchive" \
  archive

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/app.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

IPA="$(find "$BUILD_DIR/export" -name '*.ipa' -print -quit)"
if [ -z "$IPA" ]; then
  echo "No .ipa found in $BUILD_DIR/export" >&2
  exit 1
fi

xcrun altool --upload-app \
  -f "$IPA" \
  -t ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
