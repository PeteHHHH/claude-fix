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

# Deliberately NOT checking the archive's own codesign identity here - it's
# commonly Development-signed even for a perfectly good automatic-signing
# archive (confirmed empirically: a plain `xcodebuild archive` with
# CODE_SIGN_STYLE=Automatic and no identity override consistently resolves
# to the Development identity when both Development and Distribution are
# valid, yet -exportArchive below still correctly re-signs the result with
# Distribution). The archive's signature isn't what ships - the exported
# .ipa is, and that's what gets validated after export instead.
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

# Fail loudly rather than silently uploading a wrongly-signed build - unzip
# the actual .ipa that's about to be uploaded and check every top-level
# .app and embedded .appex (widgets/share extensions) really did end up
# Apple Distribution/$TEAM_ID after export's re-signing, not e.g. a stale
# Development identity from automatic signing picking the wrong team.
IPA_CHECK_DIR="$BUILD_DIR/ipa-check"
mkdir -p "$IPA_CHECK_DIR"
unzip -q "$IPA" -d "$IPA_CHECK_DIR"
while IFS= read -r -d '' bundle; do
  identity="$(codesign -dvv "$bundle" 2>&1 | grep '^Authority=' | head -1)"
  team="$(codesign -dvv "$bundle" 2>&1 | grep '^TeamIdentifier=')"
  echo "Signed: ${bundle#"$IPA_CHECK_DIR/"} -> $identity | $team"
  if [[ "$identity" != *"Apple Distribution"* ]] || [[ "$team" != *"$TEAM_ID"* ]]; then
    echo "$bundle signed with '$identity' ($team), not Apple Distribution/$TEAM_ID - not uploading" >&2
    exit 1
  fi
done < <(find "$IPA_CHECK_DIR/Payload" -maxdepth 1 -name '*.app' -print0; find "$IPA_CHECK_DIR/Payload" -name '*.appex' -print0)

xcrun altool --upload-app \
  -f "$IPA" \
  -t ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
