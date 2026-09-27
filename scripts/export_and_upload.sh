#!/bin/bash
# Archives the app, exports an App Store-signed IPA, and uploads it to
# TestFlight - automatic signing throughout (-allowProvisioningUpdates lets
# xcodebuild create/renew certs and profiles itself via the API key below,
# so this needs no manually-created Apple Distribution cert or provisioning
# profile on the machine running it). Requires SCHEME, TEAM_ID, ASC_KEY_ID,
# and ASC_ISSUER_ID in the environment, and the matching
# AuthKey_<ASC_KEY_ID>.p8 file at ~/.appstoreconnect/private_keys/ (the
# default location altool/Xcode look in).
set -euo pipefail

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

: "${SCHEME:?Set SCHEME (Xcode scheme name)}"
: "${TEAM_ID:?Set TEAM_ID (Apple Developer team ID)}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API key ID)}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect API issuer ID)}"

AUTH_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [ ! -f "$AUTH_KEY_PATH" ]; then
  echo "Missing $AUTH_KEY_PATH" >&2
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
  -allowProvisioningUpdates \
  -authenticationKeyPath "$AUTH_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  archive

# Fail loudly rather than silently uploading a wrongly-signed build - checks
# every top-level .app and any embedded .appex (widgets/share extensions)
# actually resolved to Apple Distribution/$TEAM_ID, not e.g. a stale
# Development identity from automatic signing picking the wrong team.
while IFS= read -r -d '' bundle; do
  identity="$(codesign -dvv "$bundle" 2>&1 | grep '^Authority=' | head -1)"
  team="$(codesign -dvv "$bundle" 2>&1 | grep '^TeamIdentifier=')"
  echo "Signed: ${bundle#"$BUILD_DIR/app.xcarchive/"} -> $identity | $team"
  if [[ "$identity" != *"Apple Distribution"* ]] || [[ "$team" != *"$TEAM_ID"* ]]; then
    echo "$bundle signed with '$identity' ($team), not Apple Distribution/$TEAM_ID" >&2
    exit 1
  fi
done < <(find "$BUILD_DIR/app.xcarchive/Products/Applications" -maxdepth 1 -name '*.app' -print0; find "$BUILD_DIR/app.xcarchive/Products/Applications" -name '*.appex' -print0)

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/app.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$AUTH_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

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
