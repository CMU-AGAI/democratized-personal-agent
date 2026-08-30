$ErrorActionPreference = "Stop"

# The only durable host-visible state now is the Hermes agent's data dir, which
# is bind-mounted to /opt/data (config.yaml, .env, memories/, skills/, sessions/,
# cron/). signal-cli keys and the Ollama model live in named Docker volumes.
$workspace = "workspace"
if (Test-Path ".env") {
  foreach ($line in Get-Content ".env") {
    if ($line -match "^HERMES_WORKSPACE=(.+)$") {
      $workspace = $Matches[1].Trim()
    }
  }
}

$dirs = @(
  "$workspace/hermes",
  "$workspace/hermes/shared",                # host-visible agent files (-> /opt/data/shared)
  "$workspace/hermes/skills"                 # agent skills (seeded + self-authored)
)

foreach ($d in $dirs) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $d ".gitkeep") | Out-Null
}

Write-Host "Workspace initialized at: $workspace  (agent data dir: $workspace/hermes)"
