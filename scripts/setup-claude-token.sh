#!/usr/bin/env bash
# setup-claude-token.sh - generate a Claude Code OAuth token from your Max
# subscription and store it for the claude-adapter container (Linux / macOS
# port of setup-claude-token.ps1).
#
# Requires the Claude Code CLI on this machine:
#     npm install -g @anthropic-ai/claude-code
#
# The token is account-scoped, so you can run this on any machine logged into
# your subscription and the token works inside the container.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
secret="$repo_root/secrets/claude_code_oauth_token.txt"

if ! command -v claude >/dev/null 2>&1; then
  echo "Claude Code CLI not found. Install it first:"
  echo "  npm install -g @anthropic-ai/claude-code"
  exit 1
fi

echo "A browser window will open. Log in with your Claude Max subscription account."
echo "When it finishes, the terminal prints a token starting with 'sk-ant-oat...'."
echo

claude setup-token

read -r -p "Paste the token here: " token
token="${token//[[:space:]]/}"
if [ -z "$token" ]; then
  echo "No token entered. Aborting."
  exit 1
fi

mkdir -p "$repo_root/secrets"
printf '%s' "$token" > "$secret"
chmod 600 "$secret"
echo
echo "Saved token to $secret"
echo "Restart the adapter to pick it up:  docker compose up -d claude-adapter"
