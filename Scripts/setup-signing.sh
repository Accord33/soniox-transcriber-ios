#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/Signing.local.xcconfig"

printf 'Apple Development Team ID (10文字): '
read -r team_id
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo 'Team IDは英大文字・数字10文字で入力してください。' >&2
  exit 1
fi

printf 'Bundle Identifier [com.example.SonioxTranscriber]: '
read -r bundle_id
bundle_id="${bundle_id:-com.example.SonioxTranscriber}"
if [[ ! "$bundle_id" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo 'Bundle Identifierに使用できない文字が含まれています。' >&2
  exit 1
fi

umask 077
cat > "$CONFIG_FILE" <<EOF
// Generated locally by Scripts/setup-signing.sh. Never commit this file.
DEVELOPMENT_TEAM = $team_id
APP_BUNDLE_IDENTIFIER = $bundle_id
EOF

echo "ローカル署名設定を作成しました: $CONFIG_FILE"
echo 'このファイルは.gitignoreで除外され、GitHubには公開されません。'
