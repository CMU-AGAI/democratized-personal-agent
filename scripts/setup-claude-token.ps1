<#
  setup-claude-token.ps1 - generate a Claude Code OAuth token from your Max
  subscription and store it for the claude-adapter container.

  Requires the Claude Code CLI on this machine:
      npm install -g @anthropic-ai/claude-code

  The token is account-scoped, so you can run this on any machine logged into
  your subscription and the token works inside the container.
#>

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$secret = Join-Path $repoRoot "secrets\claude_code_oauth_token.txt"

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Host "Claude Code CLI not found. Install it first:" -ForegroundColor Yellow
  Write-Host "  npm install -g @anthropic-ai/claude-code" -ForegroundColor Yellow
  return
}

Write-Host "A browser window will open. Log in with your Claude Max subscription account." -ForegroundColor Cyan
Write-Host "When it finishes, the terminal prints a token starting with 'sk-ant-oat...'." -ForegroundColor Cyan
Write-Host ""

claude setup-token

$token = (Read-Host "Paste the token here").Trim()
if (-not $token -or $token -eq "") {
  Write-Host "No token entered. Aborting." -ForegroundColor Red
  return
}

Set-Content -Path $secret -Value $token -Encoding ascii -NoNewline
Write-Host "`nSaved token to $secret" -ForegroundColor Green
Write-Host "Restart the adapter to pick it up:  docker compose up -d claude-adapter" -ForegroundColor Green
