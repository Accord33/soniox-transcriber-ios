#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/Signing.local.xcconfig"

if [[ ! -f "$CONFIG_FILE" ]]; then
  "$ROOT_DIR/Scripts/setup-signing.sh"
fi

DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17,OS=26.5}"
exec xcodebuild \
  -project "$ROOT_DIR/SonioxTranscriber.xcodeproj" \
  -scheme SonioxTranscriber \
  -destination "$DESTINATION" \
  -xcconfig "$CONFIG_FILE" \
  CODE_SIGNING_ALLOWED=NO \
  build
