# Hermes Agent over Signal (Qwen + Claude)

A self-hosted **Nous Hermes Agent** you chat with **directly over Signal**, running
as a Docker Compose stack on a machine with a GPU (Windows 11 is the reference
setup, and Ubuntu and macOS are covered below). The agent is stateful
(persistent memory + self-generated skills), can **message you on its own**
(scheduled or autonomous), and answers with either of two models you switch
between in chat:

- **Local Qwen 3.6** (via Ollama, on a dedicated GPU) — free, private. `/model qwen-local`
- **Claude** via the **Claude Code CLI on your Max subscription** — no API key, no credits. `/model claude-max`
- **Free web search** via self-hosted **SearXNG**, wired into the agent as an MCP tool.

There is no command router and no HTTP middle layer — you talk to the agent itself.
Nothing here costs API credits.

### Services (6)

| Service | Role |
|---|---|
| `hermes-agent` | The agent: owns the Signal conversation, memory/skills/sessions, cron, model routing |
| `signal-cli` | `signal-cli` HTTP daemon — the Signal transport the agent's native adapter speaks |
| `ollama` | Serves the Qwen model, pinned to one GPU, kept resident |
| `claude-adapter` | Claude via Claude Code (subscription) behind an OpenAI-compatible endpoint |
| `searxng` | Self-hosted metasearch — the free web-search backend |
| `searxng-mcp` | Exposes SearXNG to the agent as a streamable-HTTP MCP server (`/mcp`) |

(The shared folder is read/written via the agent's built-in `file` tools, so no separate filesystem MCP service is needed.)

---

## Prerequisites

Hardware

- A PC with **Docker** (Docker Desktop with the WSL 2 backend on Windows 11,
  Docker Engine on Ubuntu, Docker Desktop on macOS).
- An **NVIDIA GPU with at least 20 GB of VRAM** that you can dedicate to Ollama.
  The default model, `batiai/qwen3.6-27b:q3`, is about 13 GB on disk and needs
  the remaining headroom for its KV cache at the default `QWEN_NUM_CTX=8192`.
  An RTX A4500 (20 GB), an RTX 3090 or 4090 (24 GB), or anything larger is
  fine. With less VRAM, Ollama spills layers to the CPU and replies become very
  slow, so pick a smaller Qwen tag in `QWEN_MODEL` instead of fighting it.
- Roughly 20 GB of free disk for the model weights and the container images.
- On a Mac there is no GPU passthrough into Docker, so Ollama runs natively on
  the host instead. Plan on **32 GB or more of unified memory** for the default
  27B model (see *Linux and macOS* below).

Software and accounts

- The **NVIDIA driver** on the host, with GPU support enabled in Docker
  (Docker Desktop's WSL 2 GPU support on Windows, the NVIDIA Container Toolkit
  on Ubuntu). `docker run --rm --gpus all ubuntu nvidia-smi` should print your
  card.
- **Node.js**, so you can install the Claude Code CLI with
  `npm install -g @anthropic-ai/claude-code`. The CLI is only used to mint the
  subscription token, and the token is account scoped, so any machine that is
  logged into your subscription works.
- A **Claude Max subscription** if you want the `/model claude-max` lane. The
  stack runs on Qwen alone without it.
- A **phone with Signal** and a phone number for the bot. The bot is linked as
  a secondary device of that account, so the number can be your own (you then
  chat through Note to Self) or a dedicated one.

---

## Setup, step by step (Windows 11)

Run these from the repo root in PowerShell, in this order. Linux and macOS
users follow the same order with the shell scripts in the next section. Steps 1 to 3 are
one-time preparation, step 4 does the heavy lifting, and step 5 is the first
conversation.

**1. Clone the repo and create your `.env`.**

```powershell
git clone https://github.com/mohamedfarag/hermes-agent-with-local-qwen.git
cd hermes-agent-with-local-qwen
Copy-Item .env.example .env
notepad .env
```

Set at least `SIGNAL_ACCOUNT`, `SIGNAL_ALLOWED_USERS`, and `OLLAMA_GPU_ID`. If
you want the agent's data on another drive, set `HERMES_WORKSPACE` (forward
slashes). The full list is in the next section.

**2. Generate the Claude Code token** (skip this if you only want Qwen).

```powershell
.\scripts\setup-claude-token.ps1
```

A browser window opens, you log in with the Max account, and the script saves
the token to `secrets\claude_code_oauth_token.txt`. If you skip this step,
`up.ps1` offers to run it for you, and `/model claude-max` fails until a real
token is in place.

**3. Confirm Docker can see the GPU.**

```powershell
docker run --rm --gpus "device=<your OLLAMA_GPU_ID>" ubuntu nvidia-smi
```

`up.ps1` repeats this check in its preflight, but running it by hand first
saves you a failed build later.

**4. Bring the stack up.**

```powershell
.\scripts\up.ps1
```

The script is interactive and walks through the following, in this order.

1. Preflight. Docker running, token present, `SIGNAL_ACCOUNT` and
   `SIGNAL_ALLOWED_USERS` set, GPU reachable through Docker.
2. Creates the agent data dir under `HERMES_WORKSPACE` and seeds
   `hermes/config.yaml` from `hermes/config.example.yaml`.
3. Builds the images and starts `ollama`, `searxng`, and `claude-adapter`.
4. Pulls the Qwen model (several GB, first run only) and warms it into the GPU.
5. Links Signal. Answer `N` to "already linked?" on the first run, then scan
   the QR code printed in the terminal from Signal, Settings, Linked devices, +.
6. Starts `signal-cli` and `hermes-agent`.
7. Offers the model provider wizard (`hermes model`). Answer it with the table
   under *Models & GPU*. Base URL `http://claude-adapter:8080/v1`, Chat
   Completions mode, default model `qwen-local`, context length `65536`.
8. Configures the dashboard on `http://localhost:9119` and prints the
   generated password.
9. Registers the SearXNG MCP server (`hermes mcp add`). Answer `n` to
   authentication and tick `searxng_web_search` and `web_url_read`.
10. Runs a health sweep over signal-cli, searxng-mcp, searxng, ollama, and
    claude-adapter.

**5. Send the first message.**

Open Signal on your phone and message the bot number (or Note to Self when the
bot is your own number). Try `/model` to see the two options, `/model claude-max`
to confirm the Claude lane works, then `/model qwen-local` to go back to the
free model. Teach the web search fallback preference once (see *Web search
with fallback* below).

Later restarts do not need the full script. `.\scripts\start.ps1` rebuilds and
brings everything back up, and `docker compose down` followed by
`.\scripts\up.ps1` also works (answer `y` to "already linked?").

### The same steps by hand

```powershell
Copy-Item .env.example .env                       # then edit it
.\scripts\setup-claude-token.ps1                  # Claude lane only
.\scripts\init-folders.ps1                        # creates <HERMES_WORKSPACE>/hermes
Copy-Item hermes\config.example.yaml <HERMES_WORKSPACE>\hermes\config.yaml
docker compose build
docker compose up -d ollama searxng claude-adapter
docker exec -it ollama-qwen ollama pull batiai/qwen3.6-27b:q3
docker compose run --rm signal-cli link.sh        # scan the QR
docker compose up -d                              # agent + signal daemon
docker compose exec hermes-agent hermes model     # register the gateway provider
docker compose exec hermes-agent hermes mcp add searxng --url "http://searxng-mcp:8090/mcp"
docker compose restart hermes-agent
```

---

## Linux (Ubuntu) and macOS

The stack is plain Docker Compose, so it runs wherever Compose does. Only the
helper scripts differ. `scripts/up.sh` and `scripts/setup-claude-token.sh` are
shell ports of the PowerShell scripts and follow the same order of operations.
The optional dashboard helper has no shell port yet, so leave
`HERMES_DASHBOARD=0` on these platforms.

Where Ollama runs is the one real difference, and `.env` controls it.
`COMPOSE_PROFILES=gpu` (the default) starts the `ollama` container on an NVIDIA
GPU. An empty `COMPOSE_PROFILES=` skips that container so you can run Ollama
natively on the host, with `OLLAMA_URL=http://host.docker.internal:11434`
telling the containers where to find it. `up.sh` reads both and adjusts its
preflight and model pull accordingly.

### Ubuntu with an NVIDIA GPU

1. Install Docker Engine with the Compose plugin and add your user to the
   `docker` group (log out and back in afterwards).
2. Install the NVIDIA driver and the NVIDIA Container Toolkit, then wire it into
   Docker and verify.

   ```bash
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   docker run --rm --gpus all ubuntu nvidia-smi
   ```

3. Install Node.js and the Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
   if you want the Claude lane.
4. Clone the repo, create `.env`, and set `SIGNAL_ACCOUNT`, `SIGNAL_ALLOWED_USERS`,
   and `OLLAMA_GPU_ID`. Keep `COMPOSE_PROFILES=gpu`. `HERMES_WORKSPACE=./workspace`
   is fine on Linux.

   ```bash
   git clone https://github.com/mohamedfarag/hermes-agent-with-local-qwen.git
   cd hermes-agent-with-local-qwen
   cp .env.example .env
   nano .env
   chmod +x scripts/*.sh
   ```

5. Generate the Claude token (Claude lane only).

   ```bash
   ./scripts/setup-claude-token.sh
   ```

6. Bring the stack up. The script asks the same questions as `up.ps1` (Signal
   link, provider wizard, MCP registration) in the same order.

   ```bash
   ./scripts/up.sh
   ```

7. Message the bot from Signal, as in step 5 of the Windows walkthrough.

### macOS (Apple Silicon)

Docker Desktop on macOS cannot hand a GPU to a container, and a 27B model on the
CPU is unusable, so run Ollama natively (it uses the GPU through Metal) and let
the containers talk to it over `host.docker.internal`.

1. Install Docker Desktop for Mac, Node.js plus the Claude Code CLI (optional),
   and Ollama.

   ```bash
   brew install ollama
   ```

2. Start Ollama with the same two settings the container uses (keep the model
   resident, and cap the context to the memory budget), then pull the model.
   Leave this terminal running, or set the two variables with `launchctl setenv`
   before `brew services start ollama`.

   ```bash
   OLLAMA_KEEP_ALIVE=-1 OLLAMA_CONTEXT_LENGTH=8192 ollama serve
   # in a second terminal
   ollama pull batiai/qwen3.6-27b:q3
   ```

3. Clone the repo and create `.env`. Set `SIGNAL_ACCOUNT` and
   `SIGNAL_ALLOWED_USERS`, then switch to host Ollama mode.

   ```ini
   COMPOSE_PROFILES=
   OLLAMA_URL=http://host.docker.internal:11434
   ```

4. Generate the Claude token (Claude lane only) and bring the stack up.

   ```bash
   chmod +x scripts/*.sh
   ./scripts/setup-claude-token.sh
   ./scripts/up.sh
   ```

   `up.sh` sees the empty `COMPOSE_PROFILES`, checks that `localhost:11434`
   answers instead of probing a GPU, skips the `ollama` container, and pulls the
   model through the host Ollama.

5. Message the bot from Signal, as in step 5 of the Windows walkthrough.

Linux without an NVIDIA GPU (AMD, or CPU only) uses the same host-Ollama mode as
macOS. Install Ollama from ollama.com, start it with the two variables above,
and set the same two `.env` values.

### The same steps by hand (bash)

```bash
cp .env.example .env                              # then edit it
./scripts/setup-claude-token.sh                   # Claude lane only
mkdir -p workspace/hermes/shared workspace/hermes/skills   # or your HERMES_WORKSPACE
cp hermes/config.example.yaml workspace/hermes/config.yaml
docker compose build
docker compose up -d ollama searxng claude-adapter   # drop "ollama" in host-Ollama mode
docker exec -it ollama-qwen ollama pull batiai/qwen3.6-27b:q3   # or: ollama pull ... on the host
docker compose run --rm signal-cli link.sh        # scan the QR
docker compose up -d                              # agent + signal daemon
docker compose exec hermes-agent hermes model     # register the gateway provider
docker compose exec hermes-agent hermes mcp add searxng --url "http://searxng-mcp:8090/mcp"
docker compose restart hermes-agent
```

---

## Configuration (`.env`)

```ini
HERMES_WORKSPACE=D:/hermes-shared-data    # host folder bind-mounted to the agent's /opt/data (forward slashes!)
SIGNAL_ACCOUNT=+1...               # the bot's Signal number (the one you link)
SIGNAL_ALLOWED_USERS=+1...         # who may talk to the agent (comma-separated). Empty = pairing codes
SIGNAL_HOME_CHANNEL=+1...          # where proactive/scheduled messages go (defaults to SIGNAL_ACCOUNT)
OLLAMA_GPU_ID=1                    # GPU index, OR a UUID from `nvidia-smi -L` (deterministic)
QWEN_MODEL=batiai/qwen3.6-27b:q3
QWEN_NUM_CTX=8192                  # Qwen context window = the VRAM knob; 8192 fits a 20 GB card
CLAUDE_MODEL=claude-opus-4-8       # Claude Code model the adapter drives
COMPOSE_PROFILES=gpu               # gpu = ollama container (default); empty = Ollama runs on the host
OLLAMA_URL=http://ollama:11434     # host-native Ollama: http://host.docker.internal:11434
```

> Generating the Claude token: `setup-claude-token.ps1` logs in with your Max
> subscription and stores the token in `secrets\claude_code_oauth_token.txt`.
> Driving a personal subscription from an automated backend is a ToS gray area and
> is subject to your subscription's rate limits.

---

## How you use it

Talk to the agent in plain language over Signal — it keeps context across messages.
A few built-ins:

| In chat | What it does |
|---|---|
| *(just chat)* | Normal conversation; the agent remembers and uses its skills/tools |
| `/model` | Show the current model and options |
| `/model qwen-local` | Switch this conversation to local Qwen 3.6 (free) |
| `/model claude-max` | Switch to Claude (your Max subscription) |

| "search the web for …" | Uses the free SearXNG MCP tool |
| "every morning at 8am send me my agenda" | Schedules a proactive (cron) message to your home channel |
| `/learn …` | Teaches the agent a reusable skill from your description |

> Always switch models with these **collision-proof names**. The gateway also
> answers to bare `qwen`/`claude`, but typing those into `/model` can
> fuzzy-match Hermes's *built-in* model catalog (OpenRouter, Qwen Cloud, …)
> instead of your provider and land on an entry with no API key
> ("No LLM provider configured" — see Troubleshooting).

Default model on a fresh conversation is **Qwen** (no subscription usage until you
`/model claude-max`). Model aliases and the SearXNG tool are defined in
`hermes/config.example.yaml` (seeded to `D:\hermes-shared-data\hermes\config.yaml`).

---

## Linking / re-linking Signal

The agent talks to a `signal-cli` **HTTP daemon** (not the old REST gateway). Link
your number once — `up.ps1` does this, or run it directly:

```powershell
docker compose run --rm signal-cli link.sh
```

It prints a QR code in the terminal; scan it from **Signal → Settings → Linked
devices → +**. The link is stored in the `signal_data` Docker volume and survives
rebuilds. Verify the daemon is reachable from the agent:

```powershell
docker compose exec hermes-agent sh -c "wget -qO- http://signal-cli:8080/api/v1/check"
```

---

## Models & GPU

### Provider registration — the wizard answers (reference)

The agent talks to both models through ONE custom provider: the claude-adapter
gateway. `up.ps1` offers the registration wizard on first bring-up (skipped once
`<HERMES_WORKSPACE>\hermes\.provider-registered` exists — delete that file to be
offered again, or run it directly any time:
`docker compose exec hermes-agent hermes model`, then
`docker compose restart hermes-agent`). The answers:

| Wizard prompt | Answer |
|---|---|
| Provider | `custom (direct API)` (or `Custom endpoint (enter URL manually)`) |
| Gateway / base URL | `http://claude-adapter:8080/v1` |
| API compatibility mode | **Chat Completions** |
| API key | anything (the gateway ignores it) |
| Default model | `qwen-local` |
| Context length / num tokens | `65536` |
| Display name | your choice (e.g. `gateway`) |

The model list is auto-discovered from the gateway; switch in chat with
`/model qwen-local` / `/model claude-max` (never the bare names — see the note
in *How you use it*).

### Qwen on the GPU

```powershell
docker exec -it ollama-qwen ollama pull batiai/qwen3.6-27b:q3
docker exec -it ollama-qwen ollama run batiai/qwen3.6-27b:q3 "Reply with: ok"
docker exec -it ollama-qwen ollama ps         # PROCESSOR should read ~100% GPU
```

`OLLAMA_GPU_ID` accepts an **index** or a **UUID** (`nvidia-smi -L`) — use the UUID
for deterministic selection. Inside the container the dedicated GPU always shows as
index 0; verify the physical card via the host `nvidia-smi`. Keep the single
`device_ids` reservation rather than `gpus: all`, so the second A4500 stays free.

Claude runs on your **Max subscription**: `claude-adapter` shells out to the
`claude` CLI with `CLAUDE_CODE_OAUTH_TOKEN` and explicitly unsets
`ANTHROPIC_API_KEY`, so billing can never fall back to API credits.

---

## Memory, skills, tools (MCP)

Everything the agent persists lives in **one host-mounted folder**:
`D:\hermes-shared-data\hermes\` → the container's `/opt/data` (`config.yaml`, `.env`,
`memories/`, `skills/`, `sessions/`, `cron/`). Manage it as files on Windows, or via
the `hermes` CLI / dashboard.

- **Skills**: drop a skill folder under `hermes\skills\`, install via
  `docker compose exec hermes-agent hermes skills install <id|url>`, or teach one in
  chat with `/learn …`. Skills apply to whichever model is active.
- **Web search**: the agent's **built-in DuckDuckGo** search is the primary, and a
  self-hosted **SearXNG MCP server** (under `mcp_servers:` in `config.yaml`) is the
  block-resistant **fallback**. See *Web search with fallback* below for the one
  thing you set to wire the fallback order.
- **More MCP tools**: add servers under `mcp_servers:` (stdio `command`/`args` or a
  remote `url:`). Credentials go in the agent's own `hermes\.env` on the host.

> First-run verification (on the box): confirm `/model qwen-local` ↔ `/model claude-max`
> switches over Signal, that "search the web …" invokes the `mcp_searxng_*` tools,
> and that a scheduled message is delivered to `SIGNAL_HOME_CHANNEL`. If `/model`
> needs a provider registered first, run `docker compose exec hermes-agent hermes model`.

---

## Web search with fallback (DuckDuckGo -> SearXNG)

Both search paths stay enabled: the built-in **DuckDuckGo** as primary and the
**SearXNG MCP** as a fallback for when DuckDuckGo is rate-limited or blocked. MCP
has no automatic tool failover, so you teach the agent the order **once** - it
stores it in memory and applies it from then on. Send this to the agent over
Signal:

```
Remember this preference: when you search the web, use the built-in DuckDuckGo
search first. If it errors, is rate-limited/blocked, or returns nothing useful,
immediately retry the same query with the SearXNG tool (mcp_searxng_*) before
answering. Note which engine you used.
```

Confirm it took: ask *"what's my web-search preference?"* - it should repeat the
DuckDuckGo-first, SearXNG-fallback rule. To watch the fallback actually happen,
tail `docker compose logs -f searxng-mcp` while you run a search that DuckDuckGo
blocks.


## Dashboard (optional)

`up.ps1` can configure the Hermes web dashboard — it generates a password, writes
the auth config, and binds to **localhost** at `http://localhost:9119`.

```powershell
.\scripts\setup-hermes-dashboard.ps1 -Password "your-password"
```

If it won't bind and `docker compose logs hermes-agent` shows *"Refusing to bind
dashboard … no auth providers registered"*, **re-run** the script — it rewrites the
`basic_auth` block correctly, then recreates the agent. It's localhost-only; tunnel
in (SSH / Tailscale) for remote access rather than exposing it.

---

## Operating

```powershell
docker compose ps
docker compose logs -f hermes-agent

# Teardown / bring-up (KEEPS the model, Signal link, and agent data):
docker compose down
.\scripts\up.ps1
```

Do **not** use `docker compose down -v` — that wipes the named volumes
(`ollama_data` = the model, `signal_data` = the Signal link).

### Maintenance & disk usage

- **Container logs are capped** (10 MB × 3 files per service) in `docker-compose.yml`.
- **Reclaim space periodically:**
  ```powershell
  .\scripts\cleanup.ps1            # prune dangling images/build cache
  ```
  Stays fixed and is never cleaned: `ollama_data` (~13 GB model), `signal_data`.
  The agent accumulates `sessions/` and `logs/` under `D:\hermes-shared-data\hermes\` —
  prune those host folders directly if they grow.

---

## Troubleshooting

- **Agent not receiving Signal messages** — check the daemon is up and linked:
  `docker compose logs --tail=40 signal-cli` and the `/api/v1/check` curl above. If
  the account isn't linked, re-run `docker compose run --rm signal-cli link.sh`.
- **`/model claude` switches to some `claude-3-*` model, or chat errors with
  "No LLM provider configured"** — the custom provider (the claude-adapter
  gateway) isn't registered in the agent's config, so `/model claude` matched
  Hermes's *built-in* Anthropic catalog, which has no API key. `up.ps1` offers
  the registration wizard on first bring-up; run it manually any time:
  `docker compose exec hermes-agent hermes model` — the full answer sheet is in
  *Models & GPU → Provider registration* above — then
  `docker compose restart hermes-agent` and `/reset` in chat. To make `up.ps1`
  offer it again, delete `<HERMES_WORKSPACE>\hermes\.provider-registered`.
  **Switch with the collision-proof names** — `/model claude-max` /
  `/model qwen-local` — because bare `claude`/`qwen` can fuzzy-match Hermes's
  built-in catalog (OpenRouter etc.) instead of your provider and re-break the
  session. The gateway advertises both spellings; any name containing "claude"
  routes to the Claude lane. Note the model NAME hermes displays is a label;
  the Claude lane always runs the adapter's `CLAUDE_MODEL` (`.env`, default
  `claude-opus-4-8`) — confirm with
  `docker compose logs claude-adapter | Select-String gateway`.
- **`/model claude-max` routes correctly but replies fail** — the Claude token is
  missing/expired. Re-run `.\scripts\setup-claude-token.ps1`, then
  `docker compose up -d claude-adapter`.
- **Claude replies fail with "provider failed after retries" and the
  claude-adapter log shows `PermissionError: ... '/opt/data'`** — the Windows
  bind mount is root-only inside the container and the adapter was running as
  a non-root user. Current compose runs it as in-container root (`user: "0:0"`
  + `IS_SANDBOX=1`, with only the DAC file caps re-added); if you see this,
  your running container predates that: re-extract the update and
  `docker compose up -d --force-recreate claude-adapter`.
- **Claude asks you to "approve the WebFetch/Bash tool calls"** — those are
  Claude Code's own tools inside the claude-adapter, and headless mode has no
  way to approve prompts, so the calls were silently failing. Current setup
  pre-authorizes them (`CLAUDE_BYPASS_PERMISSIONS=true` → 
  `--dangerously-skip-permissions`) and mounts the agent data dir at
  `/opt/data` so Claude can read your shared folder. If you still see this
  message, the adapter is running an old image/config: rebuild and recreate it
  (`docker compose build claude-adapter; docker compose up -d --force-recreate
  claude-adapter`).
- **Web search does nothing / searxng missing from the agent's MCP list** — the
  agent serializes its in-memory config back to `config.yaml` on saves (model
  switches, migrations), erasing any hand-appended `mcp_servers:` block. Do NOT
  edit the YAML by hand; register through the agent's own CLI (then restart so
  the entry is loaded into memory and survives future saves):
  ```powershell
  docker compose exec hermes-agent hermes mcp add searxng --url "http://searxng-mcp:8090/mcp"
  #   prompts: authentication -> n; tool checklist -> searxng_web_search + web_url_read
  docker compose exec hermes-agent hermes mcp test searxng
  docker compose restart hermes-agent
  ```
  `up.ps1` detects a missing registration and offers this same flow. Also
  confirm `searxng` and `searxng-mcp` are healthy:
  `docker compose logs hermes-agent | Select-String mcp`.
  Check the MCP server directly: `docker compose exec hermes-agent sh -c "wget -qO- http://searxng-mcp:8090/health"`.
  The agent connects to it by URL (`http://searxng-mcp:8090/mcp`), so no `npx` is
  needed; a stdio/npx alternative is documented in `hermes/config.example.yaml`.
- **Dashboard won't bind** — re-run `.\scripts\setup-hermes-dashboard.ps1` (see above).

---

## Security model

- Signal keys live only in the `signal-cli` volume; the Claude Code subscription
  token only in `claude-adapter` (Docker secret), with `ANTHROPIC_API_KEY` unset so
  billing can't fall back to API credits; the Qwen model only in `ollama`.
- `SIGNAL_ALLOWED_USERS` gates who can talk to the agent — set it.
- `searxng`, `ollama`, and `claude-adapter` are internal-only (not published to the
  host); only the optional dashboard is exposed, and only on localhost.
- The agent runs self-generated skills and MCP tools — keep `SIGNAL_ALLOWED_USERS`
  tight, since whoever can chat with it can drive those tools.
```
