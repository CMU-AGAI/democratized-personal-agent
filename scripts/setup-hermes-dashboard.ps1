<#
  setup-hermes-dashboard.ps1 - enable the Hermes agent web dashboard.

  The dashboard refuses to bind without an auth provider, so this:
    1. computes a password hash inside the hermes-agent container,
    2. writes dashboard.basic_auth into the agent's config.yaml (host),
    3. sets HERMES_DASHBOARD=1 in .env,
    4. recreates the agent.
  Published on localhost only (http://localhost:9119).

  Usage:
    .\scripts\setup-hermes-dashboard.ps1
    .\scripts\setup-hermes-dashboard.ps1 -Username me -Password s3cret
#>
param([string]$Username = "admin", [string]$Password)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Get-EnvValue {
  param([string]$Name, [string]$Default = "")
  if (Test-Path ".env") {
    foreach ($line in Get-Content ".env") {
      if ($line -match "^\s*$([regex]::Escape($Name))=(.*)$") { return $Matches[1].Trim() }
    }
  }
  return $Default
}

if (-not $Password) {
  $sec = Read-Host "Set a dashboard password" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
}
if (-not $Password) { Write-Host "No password entered." -ForegroundColor Red; return }
if ($Password.Contains([char]39)) { Write-Host "Avoid single quotes in the password." -ForegroundColor Red; return }

$ws = Get-EnvValue "HERMES_WORKSPACE" "./workspace"
$configPath = Join-Path $ws "hermes\config.yaml"
if (-not (Test-Path $configPath)) {
  Write-Host "Hermes config not found at $configPath - run up.ps1 first." -ForegroundColor Red
  return
}

Write-Host "Starting hermes-agent (needed to compute the password hash)..." -ForegroundColor Cyan
docker compose up -d hermes-agent | Out-Null
Start-Sleep -Seconds 4

Write-Host "Computing password hash inside the container..." -ForegroundColor Cyan
$pyCmd = "from plugins.dashboard_auth.basic import hash_password; print(hash_password('" + $Password + "'))"
$out = docker compose exec -T hermes-agent python -c $pyCmd
$hash = ($out | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
if ($hash) { $hash = $hash.Trim() }
if (-not $hash) {
  Write-Host "Failed to compute the password hash inside the container." -ForegroundColor Red
  Write-Host "Check: docker compose logs --tail=30 hermes-agent" -ForegroundColor Red
  return
}
Write-Host "Password hash: $hash" -ForegroundColor DarkGray

# Write through the agent's native config writer (`hermes config set`) - NEVER
# edit config.yaml by hand here. The old truncate-at-`dashboard:`-and-append
# approach destroyed every key after the dashboard block once the agent had
# rewritten the file in its native schema (it deleted mcp_servers, tts, memory,
# ... - anything ordered after `dashboard:`).
docker compose exec -T hermes-agent hermes config set dashboard.basic_auth.username $Username
if ($LASTEXITCODE -ne 0) { Write-Host "Failed to set dashboard username." -ForegroundColor Red; return }
docker compose exec -T hermes-agent hermes config set dashboard.basic_auth.password_hash $hash
if ($LASTEXITCODE -ne 0) { Write-Host "Failed to set dashboard password hash." -ForegroundColor Red; return }
Write-Host "Wrote dashboard.basic_auth via 'hermes config set'" -ForegroundColor Green

# Enable the dashboard in .env.
$envContent = Get-Content ".env"
if ($envContent -match "^\s*HERMES_DASHBOARD=") {
  $envContent = $envContent -replace "^\s*HERMES_DASHBOARD=.*$", "HERMES_DASHBOARD=1"
} else {
  $envContent += "HERMES_DASHBOARD=1"
}
Set-Content -Path ".env" -Value $envContent -Encoding ascii

Write-Host "Recreating hermes-agent with the dashboard enabled..." -ForegroundColor Cyan
docker compose up -d hermes-agent | Out-Null

$port = Get-EnvValue "HERMES_DASHBOARD_PORT" "9119"
Write-Host "Dashboard: http://localhost:$port  (user: $Username)" -ForegroundColor Green
Write-Host "Verify it started: docker compose logs --tail=20 hermes-agent" -ForegroundColor Green
