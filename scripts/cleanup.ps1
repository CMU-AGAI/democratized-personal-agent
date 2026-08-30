<#
  cleanup.ps1 - reclaim disk the stack accumulates over time.

  Removes:
    1. Dangling Docker images + build cache (left over from `--build` rebuilds).
    2. Old per-request artifact files and daily audit logs in the shared folder.

  SAFE: does not touch running containers, named volumes (model weights, Signal
  link, Claude config), current images, or your scratch/ and hermes/ data.

  Usage:
    .\scripts\cleanup.ps1            # default: remove host files older than 14 days
    .\scripts\cleanup.ps1 -Days 30
#>
param([int]$Days = 14)

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

Write-Host "Docker disk usage (before):" -ForegroundColor Cyan
docker system df

# 1. Dangling images + build cache from rebuilds. In-use images are kept.
Write-Host "`nPruning dangling images and build cache..." -ForegroundColor Cyan
docker image prune -f
docker builder prune -f

# 2. Old agent log files under the shared workspace. Logs grow over time and are
#    safe to prune; memories/skills/sessions are NOT touched (the agent's state).
$ws = Get-EnvValue "HERMES_WORKSPACE" "./workspace"
$cutoff = (Get-Date).AddDays(-$Days)
$targets = @(
  (Join-Path $ws "hermes/logs")
)
foreach ($dir in $targets) {
  if (Test-Path $dir) {
    $old = Get-ChildItem -Path $dir -File -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Name -ne ".gitkeep" }
    if ($old) {
      Write-Host "Removing $($old.Count) file(s) older than $Days days from $dir" -ForegroundColor Yellow
      $old | Remove-Item -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host "`nDocker disk usage (after):" -ForegroundColor Green
docker system df
Write-Host "`nDone. Container logs are capped by docker-compose (10MB x 3 per service)." -ForegroundColor Green
