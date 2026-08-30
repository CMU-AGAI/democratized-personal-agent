<#
  up.ps1 - one-command bring-up for the Hermes-Agent-over-Signal stack.

  End-to-end:
    - Creates .env + the agent data dir, seeds the Hermes config.
    - Offers to generate the Claude Code subscription token if missing.
    - Preflight: Docker running, SIGNAL_ACCOUNT / SIGNAL_ALLOWED_USERS, GPU reachable.
    - Builds images; starts Ollama + claude-adapter + searxng; pulls + warms Qwen.
    - Links your Signal number (QR rendered in THIS terminal) unless already linked.
    - Starts the Hermes agent, which connects to Signal and is ready to chat.
    - Configures the dashboard with an auto-generated password.
    - Runs a post-start health sweep (signal-cli, searxng-mcp, ollama, providers).

  Run from the repo root:
      .\scripts\up.ps1
#>

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# --- Preflight: Docker must be running --------------------------------------
# native-command stderr + EAP=Stop = spurious terminating error in PS 5.1, so
# relax EAP around docker calls and trust $LASTEXITCODE.
$ErrorActionPreference = 'SilentlyContinue'
docker info 2>&1 | Out-Null
$dockerUp = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if (-not $dockerUp) {
  Write-Host "Docker does not appear to be running. Start Docker Desktop and re-run." -ForegroundColor Red
  exit 1
}

function Get-EnvValue {
  param([string]$Name, [string]$Default = "")
  if (Test-Path ".env") {
    foreach ($line in Get-Content ".env") {
      if ($line -match "^\s*$([regex]::Escape($Name))=(.*)$") { return $Matches[1].Trim() }
    }
  }
  return $Default
}

function Set-EnvValue {
  param([string]$Name, [string]$Value)
  $content = Get-Content ".env"
  if ($content -match "^\s*$([regex]::Escape($Name))=") {
    $content = $content -replace "^\s*$([regex]::Escape($Name))=.*$", "$Name=$Value"
  } else {
    $content += "$Name=$Value"
  }
  # ASCII (BOM-less) - a UTF8 BOM on line 1 can break Docker Compose .env parsing.
  Set-Content -Path ".env" -Value $content -Encoding ascii
}

# --- 1. .env + Claude token -------------------------------------------------
if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Created .env from .env.example. Set SIGNAL_ACCOUNT / SIGNAL_ALLOWED_USERS / OLLAMA_GPU_ID in .env, then re-run." -ForegroundColor Yellow
}

# Docker Compose fails if a `secrets:` file source is missing, so ensure a
# placeholder token exists before building. The adapter treats "replace_with..."
# as "no token" and only fails on Claude (/model claude-max) calls until a real one is set.
$tokenFile = "secrets\claude_code_oauth_token.txt"
if (-not (Test-Path $tokenFile)) {
  New-Item -ItemType Directory -Force -Path "secrets" | Out-Null
  Set-Content -Path $tokenFile -Value "replace_with_your_claude_code_oauth_token" -Encoding ascii -NoNewline
}
if ((Get-Content $tokenFile -Raw) -match "replace_with") {
  $ans = Read-Host "Claude token not set (needed for /model claude-max). Generate it now? (Y/n)"
  if ($ans -notmatch '^(n|no)$') {
    try { & "$PSScriptRoot\setup-claude-token.ps1" } catch { Write-Host "Token setup skipped/failed: $_" -ForegroundColor Yellow }
  }
}

$qwenModel = Get-EnvValue "QWEN_MODEL" "batiai/qwen3.6-27b:q3"
$gpuId     = Get-EnvValue "OLLAMA_GPU_ID" "0"
$dashPort  = Get-EnvValue "HERMES_DASHBOARD_PORT" "9119"

# --- Preflight checks -------------------------------------------------------
Write-Host "`n=== Preflight ===" -ForegroundColor Cyan
$issues = @()

if ((Get-Content $tokenFile -Raw) -match "replace_with") {
  $issues += "Claude token not set -> '/model claude-max' will fail. Fix: .\scripts\setup-claude-token.ps1"
} else { Write-Host "  [ok] Claude Code token present" -ForegroundColor Green }

if (-not (Get-EnvValue "SIGNAL_ACCOUNT")) {
  $issues += "SIGNAL_ACCOUNT is empty in .env -> the agent has no Signal number to link/use."
} else { Write-Host "  [ok] SIGNAL_ACCOUNT set" -ForegroundColor Green }

if (-not (Get-EnvValue "SIGNAL_ALLOWED_USERS")) {
  $issues += "SIGNAL_ALLOWED_USERS is empty -> unknown senders get pairing codes / could reach the agent."
} else { Write-Host "  [ok] SIGNAL_ALLOWED_USERS set" -ForegroundColor Green }

Write-Host "  ..  checking GPU passthrough (docker --gpus device=$gpuId; may pull a small image)" -ForegroundColor DarkGray
$ErrorActionPreference = 'SilentlyContinue'
docker run --rm --gpus "device=$gpuId" ubuntu nvidia-smi 2>&1 | Out-Null
$gpuOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if ($gpuOk) {
  Write-Host "  [ok] GPU $gpuId reachable via Docker" -ForegroundColor Green
} else {
  $issues += "Docker cannot reach GPU $gpuId -> the ollama container will fail to start. Check NVIDIA driver + Docker Desktop WSL2 GPU support, or change OLLAMA_GPU_ID in .env."
}

if ($issues.Count -gt 0) {
  Write-Host "`nPreflight found issues:" -ForegroundColor Yellow
  foreach ($i in $issues) { Write-Host "  - $i" -ForegroundColor Yellow }
  $ans = Read-Host "`nContinue anyway? (y/N)"
  if ($ans -notmatch '^(y|yes)$') { Write-Host "Aborted. Fix the above and re-run." -ForegroundColor Red; exit 1 }
} else {
  Write-Host "All preflight checks passed." -ForegroundColor Green
}

# --- 2. Workspace + seed config ---------------------------------------------
Write-Host "`n[1/6] Creating the agent data dir..." -ForegroundColor Cyan
& "$PSScriptRoot\init-folders.ps1"

$hermesDir    = Join-Path (Get-EnvValue "HERMES_WORKSPACE" "./workspace") "hermes"
$hermesConfig = Join-Path $hermesDir "config.yaml"
if (-not (Test-Path $hermesConfig)) {
  New-Item -ItemType Directory -Force -Path $hermesDir | Out-Null
  Copy-Item (Join-Path $repoRoot "hermes\config.example.yaml") $hermesConfig
  Write-Host "Seeded Hermes config: $hermesConfig" -ForegroundColor Cyan
}

# Seed agent skills from the repo (hermes\skills\*), if any are present:
#   - web-digest: seeded once, then left alone (host/agent-editable).
#   - everything else: force-refreshed on every run, so re-running up.ps1
#     deploys skill updates. Don't hand-edit those copies in the workspace -
#     they get overwritten here.
$skillsSrcRoot = Join-Path $repoRoot "hermes\skills"
$skillsDstRoot = Join-Path $hermesDir "skills"
if (Test-Path $skillsSrcRoot) {
  New-Item -ItemType Directory -Force -Path $skillsDstRoot | Out-Null
  foreach ($srcSkill in Get-ChildItem $skillsSrcRoot -Directory) {
    $dstSkill = Join-Path $skillsDstRoot $srcSkill.Name
    if ($srcSkill.Name -eq "web-digest") {
      if (-not (Test-Path $dstSkill)) {
        Copy-Item $srcSkill.FullName $dstSkill -Recurse
        Write-Host "Seeded skill: $($srcSkill.Name)" -ForegroundColor Cyan
      }
    } else {
      if (Test-Path $dstSkill) { Remove-Item $dstSkill -Recurse -Force }
      Copy-Item $srcSkill.FullName $dstSkill -Recurse
      Write-Host "Seeded skill (refreshed): $($srcSkill.Name)" -ForegroundColor Cyan
    }
  }
}

# --- 3. Build images --------------------------------------------------------
Write-Host "`n[2/6] Building images..." -ForegroundColor Cyan
docker compose build

# --- 4. Start Ollama (+ search/claude), pull + warm the model ---------------
Write-Host "`n[3/6] Starting Ollama, searxng, claude-adapter..." -ForegroundColor Cyan
docker compose up -d ollama searxng claude-adapter

Write-Host "Waiting for Ollama to come up..." -ForegroundColor Cyan
$ollamaReady = $false
for ($i = 0; $i -lt 30; $i++) {
  $ErrorActionPreference = 'SilentlyContinue'
  docker exec ollama-qwen ollama list 2>&1 | Out-Null
  $listed = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = 'Stop'
  if ($listed) { $ollamaReady = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $ollamaReady) { throw "Ollama did not become ready in time." }

Write-Host "Pulling model '$qwenModel' (first run can take a while)..." -ForegroundColor Cyan
docker exec ollama-qwen ollama pull $qwenModel
Write-Host "Warming the model into the GPU..." -ForegroundColor Cyan
$ErrorActionPreference = 'SilentlyContinue'
docker exec ollama-qwen ollama run $qwenModel "Reply with: ok" 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'

# --- 5. Link Signal (QR in this terminal) -----------------------------------
Write-Host "`n[4/6] Signal device link" -ForegroundColor Cyan
$linked = Read-Host "Is this Signal number ALREADY linked from a previous run? (y/N)"
if ($linked -notmatch '^(y|yes)$') {
  Write-Host "Linking now. A QR code will print below - scan it from the Signal app:" -ForegroundColor Green
  Write-Host "  Signal -> Settings -> Linked devices -> +`n" -ForegroundColor Green
  # One-off container: prints the QR, waits for you to approve, writes keys to the
  # signal_data volume, then exits.
  docker compose run --rm signal-cli link.sh
}

# --- 6. Start the agent + Signal daemon -------------------------------------
Write-Host "`n[5/6] Starting the Signal daemon and the Hermes agent..." -ForegroundColor Cyan
docker compose up -d

# --- Model provider registration (one-time, wizard-written schema) -----------
# The seeded config.yaml carries a best-effort `model:` block, but the provider
# schema varies by Hermes version. If the agent doesn't accept it, `/model claude`
# falls through to the BUILT-IN Anthropic catalog (e.g. claude-3-haiku) which has
# no API key -> "No LLM provider configured" at chat time. The reliable fix is the
# interactive `hermes model` wizard, which writes the correct schema for the
# installed version. Offer it once; delete the marker file to run it again.
$providerMarker = Join-Path $hermesDir ".provider-registered"
if (Test-Path $providerMarker) {
  Write-Host "`nModel provider: already registered (marker: $providerMarker)" -ForegroundColor Green
  Write-Host "  Delete that file and re-run up.ps1 to be offered the wizard again (e.g. after a Hermes upgrade)." -ForegroundColor DarkGray
} else {
  Write-Host "`nModel provider registration (one-time)" -ForegroundColor Cyan
  Write-Host "  The agent needs the claude-adapter gateway registered as its custom provider."
  Write-Host "  In the wizard, answer:" -ForegroundColor DarkGray
  Write-Host "    provider:       'custom (direct API)' or 'Custom endpoint (enter URL manually)'" -ForegroundColor DarkGray
  Write-Host "    base URL:       http://claude-adapter:8080/v1" -ForegroundColor DarkGray
  Write-Host "    API mode:       Chat Completions" -ForegroundColor DarkGray
  Write-Host "    API key:        anything (the gateway ignores it)" -ForegroundColor DarkGray
  Write-Host "    models:         auto-discovered from the gateway; prefer the collision-proof" -ForegroundColor DarkGray
  Write-Host "                    names qwen-local and claude-max (bare 'qwen'/'claude' can" -ForegroundColor DarkGray
  Write-Host "                    fuzzy-match Hermes's BUILT-IN catalog and break /model)" -ForegroundColor DarkGray
  Write-Host "    default model:  qwen-local   (keeps day-to-day chat local/free)" -ForegroundColor DarkGray
  Write-Host "    context length: 65536 or higher (metadata only; Hermes refuses <64K)" -ForegroundColor DarkGray
  $ans = Read-Host "Run the registration wizard now? (Y/n)"
  if ($ans -notmatch '^(n|no)$') {
    Start-Sleep -Seconds 3   # give the agent container a moment to finish booting
    docker compose exec hermes-agent hermes model
    if ($LASTEXITCODE -eq 0) {
      Write-Host "Restarting the agent to pick up the provider config..." -ForegroundColor Cyan
      docker compose restart hermes-agent
      New-Item -ItemType File -Force -Path $providerMarker | Out-Null
      Write-Host "Provider registered. In Signal: /reset once, then switch with /model qwen-local or /model claude-max." -ForegroundColor Green
    } else {
      Write-Host "Wizard exited without saving - not marking as done. Re-run: docker compose exec hermes-agent hermes model" -ForegroundColor Yellow
    }
  } else {
    $ans2 = Read-Host "Is the provider ALREADY registered (e.g. you ran the wizard manually)? Mark as done so this stops asking? (y/N)"
    if ($ans2 -match '^(y|yes)$') {
      New-Item -ItemType File -Force -Path $providerMarker | Out-Null
      Write-Host "Marked as registered ($providerMarker)." -ForegroundColor Green
    } else {
      Write-Host "Skipped. If chat errors with 'No LLM provider configured', run:" -ForegroundColor Yellow
      Write-Host "  docker compose exec hermes-agent hermes model    (then docker compose restart hermes-agent)" -ForegroundColor Yellow
    }
  }
}

# --- Dashboard (auto-configured; localhost only) ----------------------------
$dashLogin = $null
if (Test-Path $hermesConfig) {
  # NB: the agent's native saves write password_hash UNQUOTED - accept both
  # forms, else this guard fails and dashboard setup re-runs on every up.
  if ((Get-Content $hermesConfig -Raw) -match 'password_hash:\s*\S') {
    $dashLogin = "http://localhost:$dashPort  (already configured)"
  } else {
    Write-Host "`nConfiguring the Hermes dashboard (one-time)..." -ForegroundColor Cyan
    $dashUser = Get-EnvValue "HERMES_DASHBOARD_USER" "admin"
    $dashPass = Get-EnvValue "HERMES_DASHBOARD_PASSWORD"
    if (-not $dashPass -or $dashPass -match "change") { $dashPass = [guid]::NewGuid().ToString("N").Substring(0, 16) }
    try {
      & "$PSScriptRoot\setup-hermes-dashboard.ps1" -Username $dashUser -Password $dashPass
      $dashLogin = "http://localhost:$dashPort  (user: $dashUser  password: $dashPass)"
    } catch {
      Write-Host "Dashboard setup failed (non-fatal): $_" -ForegroundColor Yellow
      Write-Host "Run it later: .\scripts\setup-hermes-dashboard.ps1" -ForegroundColor Yellow
    }
  }
}

# --- Ensure the SearXNG MCP server is registered ------------------------------
# LAST config-writing step on purpose: nothing after this touches config.yaml.
# Hand-appending an mcp_servers block does NOT survive this build (the agent
# serializes its in-memory config back to disk on saves and erases keys it
# didn't load), and the old dashboard script truncated the file. The durable
# path is the agent's own CLI - `hermes mcp add` writes through the native
# config writer, and the restart loads the entry into memory so later saves
# re-serialize it instead of dropping it.
if (Test-Path $hermesConfig) {
  if ((Get-Content $hermesConfig -Raw) -match 'searxng-mcp:8090') {
    Write-Host "SearXNG MCP server registered in config.yaml" -ForegroundColor Green
  } else {
    Write-Host "`nSearXNG MCP server not registered." -ForegroundColor Yellow
    $ans = Read-Host "Register it now via 'hermes mcp add'? Interactive: answer 'n' to authentication, pick searxng_web_search + web_url_read in the tool list. (Y/n)"
    if ($ans -notmatch '^(n|no)$') {
      docker compose exec hermes-agent hermes mcp add searxng --url "http://searxng-mcp:8090/mcp"
      docker compose restart hermes-agent
      Start-Sleep -Seconds 8
      if ((Get-Content $hermesConfig -Raw) -match 'searxng-mcp:8090') {
        Write-Host "SearXNG MCP registered and loaded (survives future config saves once loaded)." -ForegroundColor Green
        Write-Host "Verify: docker compose exec hermes-agent hermes mcp test searxng" -ForegroundColor DarkGray
      } else {
        Write-Host "Registration did not persist - inspect: docker compose exec hermes-agent hermes mcp list" -ForegroundColor Yellow
      }
    } else {
      Write-Host "Skipped. Register later: docker compose exec hermes-agent hermes mcp add searxng --url http://searxng-mcp:8090/mcp" -ForegroundColor Yellow
    }
  }
}

# --- Health sweep -----------------------------------------------------------
# Probe the internal endpoints from INSIDE claude-adapter (it's on agent_net and
# ships httpx), since none of these are published to the host.
Write-Host "`n=== Health sweep ===" -ForegroundColor Cyan
Start-Sleep -Seconds 5   # give the agent a moment to connect to Signal

function Test-InNet {
  param([string]$Url)
  # "Reachable" = the service answered with ANY HTTP status. MCP endpoints often
  # return 4xx to a bare GET but are still up; a connection error/timeout = down.
  $py = "import httpx`ntry:`n    httpx.get('$Url', timeout=5); print('UP')`nexcept Exception:`n    print('DOWN')"
  $ErrorActionPreference = 'SilentlyContinue'
  # NB: the adapter image has python3 only (no `python` alias).
  $out = docker compose exec -T claude-adapter python3 -c $py 2>$null
  $ErrorActionPreference = 'Stop'
  return ([string]$out -match 'UP')
}

$checks = [ordered]@{
  "signal-cli daemon (/api/v1/check)" = "http://signal-cli:8080/api/v1/check"
  "searxng-mcp (/health)"             = "http://searxng-mcp:8090/health"
  "searxng (/)"                       = "http://searxng:8080/"
  "ollama (/api/tags)"                = "http://ollama:11434/api/tags"
  "claude-adapter (/health)"          = "http://localhost:8080/health"
}
$healthIssues = @()
foreach ($name in $checks.Keys) {
  if (Test-InNet $checks[$name]) {
    Write-Host "  [ok]   $name" -ForegroundColor Green
  } else {
    Write-Host "  [warn] $name unreachable" -ForegroundColor Yellow
    $healthIssues += $name
  }
}

# Did the agent actually bring up the Signal platform?
$ErrorActionPreference = 'SilentlyContinue'
$agentLog = docker compose logs --no-color --tail=200 hermes-agent 2>$null | Out-String
$ErrorActionPreference = 'Stop'
if ($agentLog -match '(?i)signal') {
  Write-Host "  [ok]   hermes-agent Signal platform active (seen in logs)" -ForegroundColor Green
} else {
  Write-Host "  [warn] no 'signal' lines in hermes-agent logs yet - still starting, or the Signal platform isn't enabled." -ForegroundColor Yellow
  Write-Host "         If chat doesn't work, enable it once: docker compose exec hermes-agent hermes gateway setup" -ForegroundColor Yellow
  $healthIssues += "hermes-agent Signal platform"
}

# Is the model provider wired to the claude-adapter gateway (/model qwen-local|claude-max)?
$ErrorActionPreference = 'SilentlyContinue'
$cfgRaw = if (Test-Path $hermesConfig) { Get-Content $hermesConfig -Raw } else { "" }
$ErrorActionPreference = 'Stop'
if ($cfgRaw -match 'claude-adapter') {
  Write-Host "  [ok]   model gateway (claude-adapter) wired in config.yaml" -ForegroundColor Green
} else {
  Write-Host "  [warn] config.yaml model.base_url is not the claude-adapter gateway - check hermes/config.yaml" -ForegroundColor Yellow
  $healthIssues += "model gateway"
}

if ($healthIssues.Count -eq 0) {
  Write-Host "All health checks passed." -ForegroundColor Green
} else {
  Write-Host "Some checks need attention (warnings above) - the stack is up regardless." -ForegroundColor Yellow
}

Write-Host "`n[6/6] Done. Chat with the agent directly from Signal." -ForegroundColor Green
Write-Host "Logs:   docker compose logs -f hermes-agent" -ForegroundColor Green
Write-Host "`nFrom Signal (Note to Self, or DM the bot number):" -ForegroundColor Green
Write-Host "  just talk to it normally - it remembers across messages."
Write-Host "  /model               show current model / options"
Write-Host "  /model qwen-local    switch to local Qwen 3.6"
Write-Host "  /model claude-max    switch to Claude (your subscription)"
Write-Host "  (bare 'qwen'/'claude' also work IF they resolve to your provider - the"
Write-Host "   -local/-max names exist because bare names can match built-in catalogs)"
Write-Host "  'search the web for ...'      -> uses the free SearXNG tool"
Write-Host "  'every morning at 8am send me my agenda'  -> proactive cron message"
if ($dashLogin) { Write-Host "`nHermes dashboard: $dashLogin" -ForegroundColor Green }
