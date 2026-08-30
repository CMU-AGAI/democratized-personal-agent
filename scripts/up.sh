#!/usr/bin/env bash
# up.sh - one-command bring-up for the Hermes-Agent-over-Signal stack on
# Linux / macOS (port of up.ps1; same order of operations).
#
#   - Creates .env + the agent data dir, seeds the Hermes config.
#   - Offers to generate the Claude Code subscription token if missing.
#   - Preflight: Docker running, SIGNAL_ACCOUNT / SIGNAL_ALLOWED_USERS, GPU or
#     host Ollama reachable.
#   - Builds images; starts Ollama (container or host) + claude-adapter +
#     searxng; pulls + warms Qwen.
#   - Links your Signal number (QR rendered in THIS terminal) unless already linked.
#   - Starts the Hermes agent, offers the provider wizard and the SearXNG MCP
#     registration, then runs a health sweep.
#
# Ollama placement is controlled by COMPOSE_PROFILES in .env:
#   COMPOSE_PROFILES=gpu   -> the ollama container with an NVIDIA GPU (Linux)
#   COMPOSE_PROFILES=      -> no container; Ollama runs natively on the host and
#                             OLLAMA_URL points at it (macOS, or Linux without
#                             an NVIDIA GPU)
#
# Run from anywhere:
#     ./scripts/up.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

get_env() {
  # get_env NAME [DEFAULT] - last value of NAME in .env, or DEFAULT
  local name="$1" default="${2:-}" line
  if [ -f .env ]; then
    line="$(grep -E "^[[:space:]]*${name}=" .env | tail -n 1 || true)"
    if [ -n "$line" ]; then
      printf '%s' "${line#*=}" | tr -d '\r'
      return
    fi
  fi
  printf '%s' "$default"
}

has_env_key() { [ -f .env ] && grep -qE "^[[:space:]]*$1=" .env; }

ask() {
  # ask PROMPT DEFAULT -> echoes the answer (DEFAULT when empty)
  local answer
  read -r -p "$1 " answer || true
  printf '%s' "${answer:-$2}"
}

# --- Preflight: Docker must be running --------------------------------------
if ! docker info >/dev/null 2>&1; then
  echo "Docker does not appear to be running (or your user cannot reach it). Start Docker and re-run."
  exit 1
fi

# --- 1. .env + Claude token -------------------------------------------------
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example. Set SIGNAL_ACCOUNT / SIGNAL_ALLOWED_USERS / OLLAMA_GPU_ID in .env, then re-run."
  exit 1
fi

token_file="secrets/claude_code_oauth_token.txt"
if [ ! -f "$token_file" ]; then
  mkdir -p secrets
  printf 'replace_with_your_claude_code_oauth_token' > "$token_file"
fi
if grep -q "replace_with" "$token_file"; then
  answer="$(ask "Claude token not set (needed for /model claude-max). Generate it now? (Y/n)" y)"
  case "$answer" in
    n|N|no|NO) ;;
    *) ./scripts/setup-claude-token.sh || echo "Token setup skipped/failed." ;;
  esac
fi

qwen_model="$(get_env QWEN_MODEL batiai/qwen3.6-27b:q3)"
gpu_id="$(get_env OLLAMA_GPU_ID 0)"
workspace="$(get_env HERMES_WORKSPACE ./workspace)"
ollama_url="$(get_env OLLAMA_URL http://ollama:11434)"
if has_env_key COMPOSE_PROFILES; then
  profiles="$(get_env COMPOSE_PROFILES)"
else
  profiles="gpu"
fi
case "$profiles" in
  *gpu*) container_ollama=1 ;;
  *)     container_ollama=0 ;;
esac
# The URL the containers use vs. the one this host script can reach.
host_ollama_url="${ollama_url/host.docker.internal/localhost}"

# --- Preflight checks -------------------------------------------------------
echo
echo "=== Preflight ==="
issues=()

if grep -q "replace_with" "$token_file"; then
  issues+=("Claude token not set -> '/model claude-max' will fail. Fix: ./scripts/setup-claude-token.sh")
else
  echo "  [ok] Claude Code token present"
fi

if [ -z "$(get_env SIGNAL_ACCOUNT)" ]; then
  issues+=("SIGNAL_ACCOUNT is empty in .env -> the agent has no Signal number to link/use.")
else
  echo "  [ok] SIGNAL_ACCOUNT set"
fi

if [ -z "$(get_env SIGNAL_ALLOWED_USERS)" ]; then
  issues+=("SIGNAL_ALLOWED_USERS is empty -> unknown senders get pairing codes / could reach the agent.")
else
  echo "  [ok] SIGNAL_ALLOWED_USERS set"
fi

if [ "$container_ollama" -eq 1 ]; then
  echo "  ..  checking GPU passthrough (docker --gpus device=$gpu_id; may pull a small image)"
  if docker run --rm --gpus "device=$gpu_id" ubuntu nvidia-smi >/dev/null 2>&1; then
    echo "  [ok] GPU $gpu_id reachable via Docker"
  else
    issues+=("Docker cannot reach GPU $gpu_id -> the ollama container will fail to start. Install the NVIDIA Container Toolkit, or set COMPOSE_PROFILES= (empty) + OLLAMA_URL to run Ollama on the host instead.")
  fi
else
  echo "  ..  host Ollama mode (COMPOSE_PROFILES is empty): checking $host_ollama_url"
  if curl -fsS --max-time 5 "$host_ollama_url/api/tags" >/dev/null 2>&1; then
    echo "  [ok] host Ollama reachable at $host_ollama_url"
  else
    issues+=("No Ollama at $host_ollama_url. Start it first (e.g. 'ollama serve') and make sure OLLAMA_URL in .env is http://host.docker.internal:11434.")
  fi
fi

if [ "${#issues[@]}" -gt 0 ]; then
  echo
  echo "Preflight found issues:"
  for i in "${issues[@]}"; do echo "  - $i"; done
  answer="$(ask "Continue anyway? (y/N)" n)"
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted. Fix the above and re-run."; exit 1 ;;
  esac
else
  echo "All preflight checks passed."
fi

# --- 2. Workspace + seed config ---------------------------------------------
echo
echo "[1/6] Creating the agent data dir..."
hermes_dir="$workspace/hermes"
hermes_config="$hermes_dir/config.yaml"
mkdir -p "$hermes_dir/shared" "$hermes_dir/skills"
echo "Workspace initialized at: $workspace  (agent data dir: $hermes_dir)"
if [ ! -f "$hermes_config" ]; then
  cp hermes/config.example.yaml "$hermes_config"
  echo "Seeded Hermes config: $hermes_config"
fi

# Seed agent skills from the repo (hermes/skills/*), if any are present:
#   - web-digest: seeded once, then left alone (host/agent-editable).
#   - everything else: force-refreshed on every run.
if [ -d hermes/skills ]; then
  for src in hermes/skills/*/; do
    [ -d "$src" ] || continue
    name="$(basename "$src")"
    dst="$hermes_dir/skills/$name"
    if [ "$name" = "web-digest" ]; then
      if [ ! -d "$dst" ]; then
        cp -R "$src" "$dst"
        echo "Seeded skill: $name"
      fi
    else
      rm -rf "$dst"
      cp -R "$src" "$dst"
      echo "Seeded skill (refreshed): $name"
    fi
  done
fi

# --- 3. Build images --------------------------------------------------------
echo
echo "[2/6] Building images..."
docker compose build

# --- 4. Start Ollama (+ search/claude), pull + warm the model ---------------
echo
if [ "$container_ollama" -eq 1 ]; then
  echo "[3/6] Starting Ollama, searxng, claude-adapter..."
  docker compose up -d ollama searxng claude-adapter

  echo "Waiting for Ollama to come up..."
  ready=0
  for _ in $(seq 1 30); do
    if docker exec ollama-qwen ollama list >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
  done
  if [ "$ready" -ne 1 ]; then
    echo "Ollama did not become ready in time."
    exit 1
  fi

  echo "Pulling model '$qwen_model' (first run can take a while)..."
  docker exec ollama-qwen ollama pull "$qwen_model"
  echo "Warming the model into the GPU..."
  docker exec ollama-qwen ollama run "$qwen_model" "Reply with: ok" >/dev/null 2>&1 || true
else
  echo "[3/6] Starting searxng, claude-adapter (Ollama runs on the host)..."
  docker compose up -d searxng claude-adapter

  echo "Pulling model '$qwen_model' on the host Ollama (first run can take a while)..."
  if command -v ollama >/dev/null 2>&1; then
    ollama pull "$qwen_model"
    echo "Warming the model..."
    ollama run "$qwen_model" "Reply with: ok" >/dev/null 2>&1 || true
  else
    curl -fsS "$host_ollama_url/api/pull" -d "{\"name\":\"$qwen_model\"}" >/dev/null
  fi
fi

# --- 5. Link Signal (QR in this terminal) -----------------------------------
echo
echo "[4/6] Signal device link"
answer="$(ask "Is this Signal number ALREADY linked from a previous run? (y/N)" n)"
case "$answer" in
  y|Y|yes|YES) ;;
  *)
    echo "Linking now. A QR code will print below - scan it from the Signal app:"
    echo "  Signal -> Settings -> Linked devices -> +"
    echo
    docker compose run --rm signal-cli link.sh
    ;;
esac

# --- 6. Start the agent + Signal daemon -------------------------------------
echo
echo "[5/6] Starting the Signal daemon and the Hermes agent..."
docker compose up -d

# --- Model provider registration (one-time, wizard-written schema) -----------
provider_marker="$hermes_dir/.provider-registered"
if [ -f "$provider_marker" ]; then
  echo
  echo "Model provider: already registered (marker: $provider_marker)"
  echo "  Delete that file and re-run up.sh to be offered the wizard again (e.g. after a Hermes upgrade)."
else
  echo
  echo "Model provider registration (one-time)"
  echo "  The agent needs the claude-adapter gateway registered as its custom provider."
  echo "  In the wizard, answer:"
  echo "    provider:       'custom (direct API)' or 'Custom endpoint (enter URL manually)'"
  echo "    base URL:       http://claude-adapter:8080/v1"
  echo "    API mode:       Chat Completions"
  echo "    API key:        anything (the gateway ignores it)"
  echo "    models:         auto-discovered from the gateway; prefer qwen-local and claude-max"
  echo "    default model:  qwen-local   (keeps day-to-day chat local/free)"
  echo "    context length: 65536 or higher (metadata only; Hermes refuses <64K)"
  answer="$(ask "Run the registration wizard now? (Y/n)" y)"
  case "$answer" in
    n|N|no|NO)
      answer2="$(ask "Is the provider ALREADY registered? Mark as done so this stops asking? (y/N)" n)"
      case "$answer2" in
        y|Y|yes|YES) touch "$provider_marker"; echo "Marked as registered ($provider_marker)." ;;
        *) echo "Skipped. If chat errors with 'No LLM provider configured', run:"
           echo "  docker compose exec hermes-agent hermes model    (then docker compose restart hermes-agent)" ;;
      esac
      ;;
    *)
      sleep 3   # give the agent container a moment to finish booting
      if docker compose exec hermes-agent hermes model; then
        echo "Restarting the agent to pick up the provider config..."
        docker compose restart hermes-agent
        touch "$provider_marker"
        echo "Provider registered. In Signal: /reset once, then switch with /model qwen-local or /model claude-max."
      else
        echo "Wizard exited without saving - not marking as done. Re-run: docker compose exec hermes-agent hermes model"
      fi
      ;;
  esac
fi

# --- Ensure the SearXNG MCP server is registered ------------------------------
# LAST config-writing step on purpose (see up.ps1 for why hand-editing
# config.yaml does not survive the agent's own saves).
if [ -f "$hermes_config" ]; then
  if grep -q 'searxng-mcp:8090' "$hermes_config"; then
    echo "SearXNG MCP server registered in config.yaml"
  else
    echo
    echo "SearXNG MCP server not registered."
    answer="$(ask "Register it now via 'hermes mcp add'? Interactive: answer 'n' to authentication, pick searxng_web_search + web_url_read in the tool list. (Y/n)" y)"
    case "$answer" in
      n|N|no|NO)
        echo "Skipped. Register later: docker compose exec hermes-agent hermes mcp add searxng --url http://searxng-mcp:8090/mcp" ;;
      *)
        docker compose exec hermes-agent hermes mcp add searxng --url "http://searxng-mcp:8090/mcp"
        docker compose restart hermes-agent
        sleep 8
        if grep -q 'searxng-mcp:8090' "$hermes_config"; then
          echo "SearXNG MCP registered and loaded (survives future config saves once loaded)."
          echo "Verify: docker compose exec hermes-agent hermes mcp test searxng"
        else
          echo "Registration did not persist - inspect: docker compose exec hermes-agent hermes mcp list"
        fi
        ;;
    esac
  fi
fi

# --- Health sweep -----------------------------------------------------------
# Probe the internal endpoints from INSIDE claude-adapter (it's on agent_net and
# ships httpx), since none of these are published to the host.
echo
echo "=== Health sweep ==="
sleep 5   # give the agent a moment to connect to Signal

test_in_net() {
  # "Reachable" = the service answered with ANY HTTP status.
  local py="import httpx
try:
    httpx.get('$1', timeout=5); print('UP')
except Exception:
    print('DOWN')"
  docker compose exec -T claude-adapter python3 -c "$py" 2>/dev/null | grep -q UP
}

health_issues=()
check() {
  if test_in_net "$2"; then
    echo "  [ok]   $1"
  else
    echo "  [warn] $1 unreachable"
    health_issues+=("$1")
  fi
}
check "signal-cli daemon (/api/v1/check)" "http://signal-cli:8080/api/v1/check"
check "searxng-mcp (/health)"             "http://searxng-mcp:8090/health"
check "searxng (/)"                       "http://searxng:8080/"
check "ollama (/api/tags)"                "$ollama_url/api/tags"
check "claude-adapter (/health)"          "http://localhost:8080/health"

if docker compose logs --no-color --tail=200 hermes-agent 2>/dev/null | grep -qi signal; then
  echo "  [ok]   hermes-agent Signal platform active (seen in logs)"
else
  echo "  [warn] no 'signal' lines in hermes-agent logs yet - still starting, or the Signal platform isn't enabled."
  echo "         If chat doesn't work, enable it once: docker compose exec hermes-agent hermes gateway setup"
  health_issues+=("hermes-agent Signal platform")
fi

if [ -f "$hermes_config" ] && grep -q 'claude-adapter' "$hermes_config"; then
  echo "  [ok]   model gateway (claude-adapter) wired in config.yaml"
else
  echo "  [warn] config.yaml model.base_url is not the claude-adapter gateway - check hermes/config.yaml"
  health_issues+=("model gateway")
fi

if [ "${#health_issues[@]}" -eq 0 ]; then
  echo "All health checks passed."
else
  echo "Some checks need attention (warnings above) - the stack is up regardless."
fi

echo
echo "[6/6] Done. Chat with the agent directly from Signal."
echo "Logs:   docker compose logs -f hermes-agent"
echo
echo "From Signal (Note to Self, or DM the bot number):"
echo "  just talk to it normally - it remembers across messages."
echo "  /model               show current model / options"
echo "  /model qwen-local    switch to local Qwen 3.6"
echo "  /model claude-max    switch to Claude (your subscription)"
echo "  'search the web for ...'      -> uses the free SearXNG tool"
echo "  'every morning at 8am send me my agenda'  -> proactive cron message"
