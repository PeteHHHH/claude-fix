#!/bin/bash
# Interactive "ship this to TestFlight" pipeline - the one script every
# claude-fix caller repo uses for a real, user-requested release (as opposed
# to the /fix pipeline's own automatic build-number-only bump+upload). Run
# from the target repo's root, e.g.:
#
#   .claude-fix-tools/scripts/ship.sh          # auto-bump: 1.0 -> 1.1
#   .claude-fix-tools/scripts/ship.sh 1.2      # explicit MARKETING_VERSION
#
# Reads scheme/bundle_id/team_id/xcodeproj_path from the repo's own
# .github/workflows/claude-fix.yml `with:` block - the same config the /fix
# pipeline already uses - so there's exactly one place per repo to declare
# this instead of a second, driftable copy. Signs with the exact same
# approach as the /fix pipeline: automatic signing + an App Store Connect
# API key (see export_and_upload.sh) rather than a manually-created
# Apple Distribution cert/provisioning profile - see ship_env below for the
# one-time credential setup this needs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"
CALLER_WORKFLOW="$REPO_ROOT/.github/workflows/claude-fix.yml"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED:\033[0m %s\n' "$1" >&2; exit 1; }

[[ -f "$CALLER_WORKFLOW" ]] || fail "No .github/workflows/claude-fix.yml here - run this from a claude-fix caller repo's root."

read_input() {
  sed -n "s/^ *$1: *//p" "$CALLER_WORKFLOW" | head -1 | sed -e 's/ *#.*//' -e "s/^['\"]//" -e "s/['\"]\$//"
}

SCHEME="$(read_input scheme)"
BUNDLE_ID="$(read_input bundle_id)"
TEAM_ID="$(read_input team_id)"
XCODEPROJ_PATH="$(read_input xcodeproj_path)"
for name in SCHEME BUNDLE_ID TEAM_ID XCODEPROJ_PATH; do
  [[ -n "${!name}" ]] || fail "Could not read '$name' from $CALLER_WORKFLOW's with: block."
done
log "Config: scheme=$SCHEME bundle_id=$BUNDLE_ID team_id=$TEAM_ID xcodeproj=$XCODEPROJ_PATH"

# One shared App Store Connect API key config for every repo, since it's the
# same Apple Developer account/team across all of them - see this repo's
# README "Adding claude-fix to a repo" step 2. A repo can still override with
# its own scripts/.ship_env (gitignored) if it ever needs a different key.
[[ -f "$HOME/.appstoreconnect/ship_env" ]] && source "$HOME/.appstoreconnect/ship_env"
[[ -f "$REPO_ROOT/scripts/.ship_env" ]] && source "$REPO_ROOT/scripts/.ship_env"
: "${ASC_KEY_ID:?Set ASC_KEY_ID - see ~/.appstoreconnect/ship_env (create it: export ASC_KEY_ID=...; export ASC_ISSUER_ID=...)}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID - see ~/.appstoreconnect/ship_env}"
export ASC_KEY_ID ASC_ISSUER_ID

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  fail "Working tree isn't clean - commit or stash first."
fi

log "Syncing with origin/main"
git -C "$REPO_ROOT" fetch origin main
if [[ "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)" == "main" ]]; then
  git -C "$REPO_ROOT" merge --ff-only origin/main || fail "main has diverged from origin/main - resolve manually."
else
  git -C "$REPO_ROOT" merge origin/main --no-edit || fail "Merging origin/main into this branch hit a conflict - resolve manually."
fi

log "Smoke build (Release) before touching any version numbers"
xcodebuild build \
  -project "$XCODEPROJ_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  || fail "Build isn't clean - fix before shipping."

log "Bumping MARKETING_VERSION and CURRENT_PROJECT_VERSION"
BUMP_OUT="$(cd "$REPO_ROOT" && python3 "$SCRIPT_DIR/bump_build_number.py" --xcodeproj "$XCODEPROJ_PATH" --bundle-id "$BUNDLE_ID" --marketing-version "${1:-auto}")"
echo "$BUMP_OUT"
NEW_MARKETING="$(sed -n 's/^MARKETING_VERSION=//p' <<<"$BUMP_OUT")"
NEW_BUILD="$(sed -n 's/^CURRENT_PROJECT_VERSION=//p' <<<"$BUMP_OUT")"

log "Committing + pushing ${NEW_MARKETING} (${NEW_BUILD})"
git -C "$REPO_ROOT" add -A
git -C "$REPO_ROOT" commit -m "Ship ${NEW_MARKETING} (${NEW_BUILD}) to TestFlight

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
git -C "$REPO_ROOT" push origin HEAD:main

log "Archiving, exporting, and uploading to App Store Connect"
SHIP_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
if ( cd "$REPO_ROOT" && SCHEME="$SCHEME" TEAM_ID="$TEAM_ID" ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" "$SCRIPT_DIR/export_and_upload.sh" ); then
  bash "$SCRIPT_DIR/notify.sh" "$(basename "$REPO_ROOT"): shipped" "${NEW_MARKETING} (${NEW_BUILD}) is uploading to TestFlight." 2>/dev/null || true
else
  bash "$SCRIPT_DIR/notify.sh" "$(basename "$REPO_ROOT"): ship failed" "Code+version bump for ${NEW_MARKETING} (${NEW_BUILD}) landed on main, but the archive/export/upload failed - see the output above." 2>/dev/null || true
  fail "Version bump landed on main, but archive/export/upload failed - see output above. ${NEW_MARKETING} (${NEW_BUILD}) is already committed and pushed; re-running this script will bump to the next build number rather than retry this exact one - that's fine (TestFlight just sees an unused build number go by), just don't hand-edit the version back to retry the same one."
fi

if [[ "$SHIP_BRANCH" != "main" ]]; then
  log "Cleaning up branch $SHIP_BRANCH (fully merged into main by the push above)"
  git -C "$REPO_ROOT" checkout main
  git -C "$REPO_ROOT" pull --ff-only origin main
  git -C "$REPO_ROOT" branch -d "$SHIP_BRANCH" || true
  git -C "$REPO_ROOT" push origin --delete "$SHIP_BRANCH" || true
fi

log "Shipped ${NEW_MARKETING} (${NEW_BUILD}) - check App Store Connect for TestFlight processing."
