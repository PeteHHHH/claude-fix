#!/bin/bash
# Sends a local macOS notification (always works, zero config) and, if
# NTFY_TOPIC is set, a push to a phone subscribed to that ntfy.sh topic.
set -euo pipefail

TITLE="${1:?usage: notify.sh <title> <message>}"
MESSAGE="${2:?usage: notify.sh <title> <message>}"

ESCAPED_TITLE=${TITLE//\"/\\\"}
ESCAPED_MESSAGE=${MESSAGE//\"/\\\"}
osascript -e "display notification \"$ESCAPED_MESSAGE\" with title \"$ESCAPED_TITLE\"" || true

if [ -n "${NTFY_TOPIC:-}" ]; then
  curl -fsS -H "Title: $TITLE" -d "$MESSAGE" "https://ntfy.sh/$NTFY_TOPIC" > /dev/null || true
fi
