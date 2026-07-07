#!/usr/bin/env bash
# install.sh — unified installer for the aih-security stack
# Usage: bash install.sh [--tier=1|2|3] [--dir=PATH] [--skip-clone]
#        bash install.sh --disable
#        bash install.sh --uninstall [--purge]
#
# Tiers:
#   1 — proxy only (transparent tokenization)
#   2 — proxy + middleware (hook-based PII guard)
#   3 — full stack: proxy + middleware + prompt-protection + supply-guard (default)
#
# Modes:
#   (default)    — install/update at the given tier
#   --disable    — stop the proxy and remove aih-security's hooks/env from
#                  ~/.claude/settings.json, leaving cloned repos and keys/vault
#                  data in place. Re-run install.sh normally to re-enable.
#   --uninstall  — everything --disable does, plus removes the shell RC
#                  source line. Add --purge to also delete cloned repos and
#                  ~/.llm-privacy (keys, vault, logs) after confirmation.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────

TIER=""
PROJECTS_DIR="${HOME}/Projects"
# Absolute path to this umbrella repo (where bin/aih-status lives), resolved
# independent of the caller's cwd so the SessionStart hook path is always correct.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKIP_CLONE=false
LLM_PRIVACY_DIR="${LLM_PRIVACY_DIR:-${HOME}/.llm-privacy}"
ENV_FILE="${LLM_PRIVACY_DIR}/.env.sh"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
DISABLE=false
UNINSTALL=false
PURGE=false

# ── Arg parsing ───────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --tier=*)  TIER="${arg#*=}" ;;
    --dir=*)   PROJECTS_DIR="${arg#*=}" ;;
    --skip-clone) SKIP_CLONE=true ;;
    --disable) DISABLE=true ;;
    --uninstall) UNINSTALL=true ;;
    --purge) PURGE=true ;;
    --help|-h)
      echo "Usage: bash install.sh [--tier=1|2|3] [--dir=PATH] [--skip-clone]"
      echo "       bash install.sh --disable"
      echo "       bash install.sh --uninstall [--purge]"
      exit 0
      ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────

print_step() { echo ""; echo "▶ $1"; }
ok() { echo "  ✓ $1"; }
warn() { echo "  ! $1"; }
err() { echo "  ✗ $1"; exit 1; }

ask_yes() {
  local prompt="$1" default="${2:-Y}"
  if [ ! -t 0 ]; then [[ "$default" =~ ^[Yy] ]] && return 0 || return 1; fi
  local hint="[Y/n]"; [[ "$default" =~ ^[Nn] ]] && hint="[y/N]"
  read -rp "  ${prompt} ${hint} " ans
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

# Shell RC file detection
detect_rc() {
  case "${SHELL:-}" in
    */zsh)  echo "${HOME}/.zshrc" ;;
    */fish) echo "${HOME}/.config/fish/config.fish" ;;
    *)      echo "${HOME}/.bashrc" ;;
  esac
}

wire_rc() {
  local rc="$1"
  local src_line='[ -f "$HOME/.llm-privacy/.env.sh" ] && source "$HOME/.llm-privacy/.env.sh"'
  if [ -f "$rc" ] && grep -q '.llm-privacy/.env.sh' "$rc" 2>/dev/null; then
    ok "${rc} already sources .env.sh"
  else
    printf '\n# aih-security: load LLM privacy keys\n%s\n' "$src_line" >> "$rc"
    ok "Source line added to ${rc}"
  fi
}

unwire_rc() {
  local rc="$1"
  [ -f "$rc" ] || return 0
  if grep -q '.llm-privacy/.env.sh' "$rc" 2>/dev/null; then
    # Remove the marker comment line and the source line that follows it
    sed -i.bak -e '/# aih-security: load LLM privacy keys/d' \
               -e '/\.llm-privacy\/\.env\.sh/d' "$rc" && rm -f "${rc}.bak"
    ok "Removed .env.sh sourcing from ${rc}"
  fi
}

# ── Disable / Uninstall ────────────────────────────────────────────────────

stop_proxy() {
  local candidate
  for candidate in "${PROJECTS_DIR}/aih-privacy-proxy/proxy.sh" "${HOME}/.claude/llm-privacy-proxy/proxy.sh"; do
    if [ -x "$candidate" ]; then
      "$candidate" stop 2>/dev/null || true
    fi
  done
  # Fallback: kill anything still listening on the proxy ports directly,
  # in case neither known proxy.sh copy is present/executable.
  local port pid
  for port in 4444 4445; do
    pid="$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      ok "Stopped process on port ${port} (was PID ${pid})"
    fi
  done
}

cmd_disable() {
  print_step "Disabling aih-security"

  if [ -f "$CLAUDE_SETTINGS" ]; then
    local backup="${CLAUDE_SETTINGS}.bak-$(date +%Y%m%d%H%M%S)"
    cp "$CLAUDE_SETTINGS" "$backup"
    ok "Backed up settings to ${backup}"

    python3 - "$CLAUDE_SETTINGS" <<'PYEOF'
import sys, json, re

settings_path = sys.argv[1]

with open(settings_path, 'r') as f:
    raw = f.read()
raw = re.sub(r',(\s*[}\]])', r'\1', raw)
settings = json.loads(raw)

changed = []

env = settings.get('env', {})
if 'ANTHROPIC_BASE_URL' in env:
    del env['ANTHROPIC_BASE_URL']
    changed.append("  - ANTHROPIC_BASE_URL removed")

hooks = settings.get('hooks', {})

def strip(event, needle_fn):
    entries = hooks.get(event)
    if not entries:
        return
    kept = [e for e in entries if not needle_fn(e)]
    removed = len(entries) - len(kept)
    if removed:
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
        changed.append(f"  - {event}: removed {removed} aih-security hook(s)")

strip('SessionStart', lambda e: 'proxy.sh' in str(e) or 'aih-status' in str(e))
strip('UserPromptSubmit', lambda e: 'PrivacyPromptGuard' in str(e))
strip('PreToolUse', lambda e: 'PrivacyToolGuard' in str(e) or 'SupplyGuard.hook.ts' in str(e))
strip('Stop', lambda e: 'PrivacyResponseScanner' in str(e))

if changed:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    for msg in changed:
        print(msg)
    print(f"  ✓ {settings_path} updated")
else:
    print("  ✓ No aih-security entries found in settings.json — already disabled")
PYEOF
  else
    warn "${CLAUDE_SETTINGS} not found — nothing to unwire"
  fi

  stop_proxy

  echo ""
  echo "  aih-security disabled: proxy stopped, hooks removed, ANTHROPIC_BASE_URL cleared."
  echo "  New Claude Code sessions will talk to the real Anthropic API directly."
  echo "  NOTE: any session already running (including this one, if applicable) keeps"
  echo "  its old ANTHROPIC_BASE_URL in its own process environment until restarted."
  echo ""
  echo "  To re-enable: bash install.sh --tier=N"
}

cmd_uninstall() {
  cmd_disable

  print_step "Removing shell RC wiring"
  unwire_rc "${HOME}/.bashrc"
  unwire_rc "${HOME}/.zshrc"
  unwire_rc "${HOME}/.bash_profile"
  unwire_rc "${HOME}/.config/fish/config.fish"

  local repos=(aih-privacy-proxy aih-privacy-middleware aih-prompt-protection \
               supply-guard-hook supply-guard-proxy aih-observability aih-conversation-viewer)

  if [ "$PURGE" != "true" ]; then
    print_step "Uninstall complete (data preserved)"
    echo "  Left in place (re-run with --purge to remove):"
    for r in "${repos[@]}"; do
      [ -d "${PROJECTS_DIR}/${r}" ] && echo "    ${PROJECTS_DIR}/${r}"
    done
    [ -d "$LLM_PRIVACY_DIR" ] && echo "    ${LLM_PRIVACY_DIR} (keys, vault, logs)"
    echo ""
    return 0
  fi

  print_step "Purging data and cloned repos"
  echo "  This will permanently delete:"
  for r in "${repos[@]}"; do
    [ -d "${PROJECTS_DIR}/${r}" ] && echo "    ${PROJECTS_DIR}/${r}"
  done
  [ -d "$LLM_PRIVACY_DIR" ] && echo "    ${LLM_PRIVACY_DIR} (keys, vault, logs)"
  echo ""
  if ask_yes "Proceed with permanent deletion?" "N"; then
    for r in "${repos[@]}"; do
      if [ -d "${PROJECTS_DIR}/${r}" ]; then
        rm -rf "${PROJECTS_DIR}/${r}"
        ok "Removed ${PROJECTS_DIR}/${r}"
      fi
    done
    if [ -d "$LLM_PRIVACY_DIR" ]; then
      rm -rf "$LLM_PRIVACY_DIR"
      ok "Removed ${LLM_PRIVACY_DIR}"
    fi
  else
    warn "Purge cancelled — repos and ${LLM_PRIVACY_DIR} left in place"
  fi
}

if [ "$DISABLE" = "true" ]; then
  cmd_disable
  exit 0
fi

if [ "$UNINSTALL" = "true" ]; then
  cmd_uninstall
  exit 0
fi

# ── Step 1: Detect platform ───────────────────────────────────────────────

print_step "Detecting platform"

PLATFORM="$(uname -s)"
case "$PLATFORM" in
  Darwin) ok "macOS detected" ;;
  Linux)
    if [ -f /etc/debian_version ]; then
      ok "Debian/Ubuntu detected ($(cat /etc/debian_version))"
    else
      ok "Linux detected (non-Debian)"
    fi
    ;;
  *)
    warn "Unknown platform: ${PLATFORM} — proceeding but YMMV"
    ;;
esac

# ── Step 2: Check/install dependencies ────────────────────────────────────

print_step "Checking dependencies"

# git
if command -v git &>/dev/null; then
  ok "git $(git --version | awk '{print $3}')"
else
  if [[ "$PLATFORM" == "Darwin" ]]; then
    err "git not found. Install via Homebrew: brew install git"
  else
    err "git not found. Install: sudo apt-get install -y git"
  fi
fi

# openssl
if command -v openssl &>/dev/null; then
  ok "openssl $(openssl version | awk '{print $2}')"
else
  warn "openssl not found — will use bun fallback for key generation"
fi

# bun
if command -v bun &>/dev/null; then
  ok "bun $(bun --version)"
else
  print_step "Installing Bun runtime"
  if ask_yes "Bun not found. Install now?"; then
    curl -fsSL https://bun.sh/install | bash
    # Add bun to PATH for this session
    export BUN_INSTALL="${HOME}/.bun"
    export PATH="${BUN_INSTALL}/bin:${PATH}"
    if command -v bun &>/dev/null; then
      ok "bun $(bun --version) installed"
    else
      err "Bun install failed. Add ~/.bun/bin to PATH and re-run."
    fi
  else
    err "Bun is required. Install from https://bun.sh and re-run."
  fi
fi

# Ensure bun is in PATH for this session (handles cases where it was pre-installed)
export PATH="${HOME}/.bun/bin:${PATH}"

# ── Step 3: Tier selection ────────────────────────────────────────────────

print_step "Tier selection"

if [ -z "$TIER" ]; then
  echo ""
  echo "  Select installation tier:"
  echo "    1 — Proxy only       (transparent tokenization)"
  echo "    2 — Standard         (+ hook-based PII/secrets guard)"
  echo "    3 — Full stack       (+ ATLAS injection detection + supply chain) [default]"
  echo ""
  read -rp "  Tier [1/2/3, default=3]: " TIER_INPUT
  TIER="${TIER_INPUT:-3}"
fi

case "$TIER" in
  1|2|3) ok "Tier ${TIER} selected" ;;
  *) err "Invalid tier '${TIER}'. Must be 1, 2, or 3." ;;
esac

# ── Step 4: Clone repos ────────────────────────────────────────────────────

print_step "Cloning repositories"

GITHUB_BASE="https://github.com/JonathanReifer"

clone_or_update() {
  local name="$1" remote="$2"
  local dest="${PROJECTS_DIR}/${name}"
  if [ -d "${dest}/.git" ]; then
    ok "${name} already cloned — pulling latest"
    git -C "$dest" pull --quiet --ff-only 2>/dev/null || warn "${name}: pull skipped (local changes or network)"
  elif [ "$SKIP_CLONE" = "true" ]; then
    warn "Skipping clone of ${name} (--skip-clone)"
  else
    echo "  Cloning ${name}..."
    git clone --quiet "$remote" "$dest"
    ok "${name} cloned to ${dest}"
  fi
}

mkdir -p "$PROJECTS_DIR"

# Always clone proxy (required at all tiers)
clone_or_update "aih-privacy-proxy"   "${GITHUB_BASE}/aih-privacy-proxy.git"

if [ "$TIER" -ge 2 ]; then
  clone_or_update "aih-privacy-middleware" "${GITHUB_BASE}/aih-privacy-middleware.git"
fi

if [ "$TIER" -ge 3 ]; then
  clone_or_update "aih-prompt-protection"  "${GITHUB_BASE}/aih-prompt-protection.git"
  clone_or_update "supply-guard-hook"      "${GITHUB_BASE}/supply-guard-hook.git"
  clone_or_update "supply-guard-proxy"     "${GITHUB_BASE}/supply-guard-proxy.git"
fi

# ── Step 5: Install dependencies ──────────────────────────────────────────

print_step "Installing project dependencies"

bun_install() {
  local dir="$1" name="$2"
  if [ ! -d "$dir" ]; then warn "${name} not found — skipping bun install"; return; fi
  echo "  Installing ${name} deps..."
  (cd "$dir" && bun install --silent)
  ok "${name} deps installed"
}

bun_install "${PROJECTS_DIR}/aih-privacy-proxy"       "aih-privacy-proxy"
[ "$TIER" -ge 2 ] && bun_install "${PROJECTS_DIR}/aih-privacy-middleware"    "aih-privacy-middleware"
[ "$TIER" -ge 3 ] && bun_install "${PROJECTS_DIR}/aih-prompt-protection"     "aih-prompt-protection"
[ "$TIER" -ge 3 ] && bun_install "${PROJECTS_DIR}/supply-guard-hook"         "supply-guard-hook"

# ── Step 6: Generate and write encryption keys ─────────────────────────────

print_step "Encryption keys"

mkdir -p "$LLM_PRIVACY_DIR" && chmod 700 "$LLM_PRIVACY_DIR"
touch "$ENV_FILE" && chmod 600 "$ENV_FILE"

write_key() {
  local var="$1"
  if grep -q "^export ${var}=" "$ENV_FILE" 2>/dev/null; then
    ok "${var} already present — skipping (never regenerate after vault has entries)"
  else
    local val
    if command -v openssl &>/dev/null; then
      val="$(openssl rand -base64 32)"
    else
      val="$(bun -e 'const b=Buffer.alloc(32);for(let i=0;i<32;i++)b[i]=Math.floor(Math.random()*256);console.log(b.toString("base64"))')"
    fi
    printf 'export %s="%s"\n' "$var" "$val" >> "$ENV_FILE"
    ok "${var} generated and written to ${ENV_FILE}"
  fi
}

write_key "LLM_PRIVACY_HMAC_KEY"
write_key "LLM_PRIVACY_VAULT_KEY"

# Write an env var (create or update) in ENV_FILE
write_env() {
  local var="$1" val="$2"
  if grep -q "^export ${var}=" "$ENV_FILE" 2>/dev/null; then
    sed -i.bak "s|^export ${var}=.*|export ${var}=\"${val}\"|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
    ok "${var} updated in ${ENV_FILE}"
  else
    printf 'export %s="%s"\n' "$var" "$val" >> "$ENV_FILE"
    ok "${var} written to ${ENV_FILE}"
  fi
}

# ── Step 6.4: Blocking mode ───────────────────────────────────────────────

print_step "Blocking mode"
echo ""
echo "  When a secret or PII pattern is detected in a prompt or tool call, the proxy can:"
echo "    Y) Monitor only — log the finding, tokenize, and continue (recommended)"
echo "    N) Hard-block   — return HTTP 400 and refuse to forward the request"
echo ""

if ask_yes "Enable hard-blocking? (default: No — monitor only)" "N"; then
  write_env "LLM_PRIVACY_BLOCK_ENABLED" "true"
  ok "Hard-blocking enabled (LLM_PRIVACY_BLOCK_ENABLED=true)"
else
  write_env "LLM_PRIVACY_BLOCK_ENABLED" "false"
  ok "Monitor-only mode (LLM_PRIVACY_BLOCK_ENABLED=false) — tokenization still active"
fi

# ── Step 6.45: Prompt logging (feeds aih-conversation-viewer) ──────────────

print_step "Prompt logging"
echo ""
echo "  aih-conversation-viewer reads its session list from the proxy's prompt log."
echo "  Without this, the viewer will show zero sessions even with a healthy proxy."
echo ""

write_env "LLM_PRIVACY_LOG_PROMPTS" "tokenized"
write_env "LLM_PRIVACY_LOG_PATH" "${LLM_PRIVACY_DIR}/prompts.jsonl"
ok "Prompt logging enabled (LLM_PRIVACY_LOG_PROMPTS=tokenized)"

# ── Step 6.5: Observability (optional) ────────────────────────────────────

print_step "Observability (optional)"
echo ""
echo "  Choose an observability mode:"
echo "    1) Local  — run aih-observability stack on this machine (requires Docker)"
echo "    2) Remote — connect to an existing observability instance"
echo "    3) Skip   — configure later (see docs/observability.md)"
echo ""

if [ ! -t 0 ]; then
  OBS_CHOICE="3"
  warn "Non-interactive mode — skipping observability setup"
else
  read -rp "  Choice [1/2/3, default=3]: " OBS_INPUT
  OBS_CHOICE="${OBS_INPUT:-3}"
fi

case "$OBS_CHOICE" in
  1)
    if ! command -v docker &>/dev/null; then
      warn "Docker not found — install Docker first: https://docs.docker.com/engine/install/"
      warn "Skipping. Re-run install.sh after installing Docker to set up observability."
    else
      clone_or_update "aih-observability" "${GITHUB_BASE}/aih-observability.git"
      OBS_DIR="${PROJECTS_DIR}/aih-observability"
      if [ -d "$OBS_DIR" ]; then
        OTEL_CONFIG="${OBS_DIR}/config/otel/config.yaml"
        OTEL_EXAMPLE="${OBS_DIR}/config/otel/config.yaml.example"
        if [ ! -f "$OTEL_CONFIG" ] && [ -f "$OTEL_EXAMPLE" ]; then
          cp "$OTEL_EXAMPLE" "$OTEL_CONFIG"
          ok "Created config/otel/config.yaml from example"
        fi
        echo "  Starting aih-observability..."
        (cd "$OBS_DIR" && docker compose up -d) 2>/dev/null
        ok "aih-observability started — Grafana: http://localhost:3001 (admin/aih)"
        write_env "OTEL_EXPORTER_OTLP_ENDPOINT" "http://localhost:4317"
        write_env "LOKI_URL" "http://localhost:3100"
      fi
    fi
    ;;
  2)
    echo ""
    read -rp "  OTEL endpoint (e.g. http://192.168.1.10:4317): " OTEL_ENDPOINT_INPUT
    read -rp "  Loki URL      (e.g. http://192.168.1.10:3100): " LOKI_URL_INPUT
    if [ -n "$OTEL_ENDPOINT_INPUT" ] && [ -n "$LOKI_URL_INPUT" ]; then
      write_env "OTEL_EXPORTER_OTLP_ENDPOINT" "$OTEL_ENDPOINT_INPUT"
      write_env "LOKI_URL" "$LOKI_URL_INPUT"
      ok "Remote observability configured"
    else
      warn "Empty input — observability not configured. Edit ${ENV_FILE} manually."
    fi
    ;;
  3)
    ok "Observability skipped — see docs/observability.md to configure later"
    ;;
  *)
    warn "Invalid choice '${OBS_CHOICE}' — skipping observability"
    ;;
esac

# ── Step 6.6: Conversation Viewer (optional) ──────────────────────────────

print_step "Conversation Viewer (optional)"
echo ""
echo "  aih-conversation-viewer shows sessions, PII detection, and"
echo "  ATLAS security findings. Requires Bun — no Docker needed."
echo ""

if ask_yes "Install aih-conversation-viewer?" "Y"; then
  clone_or_update "aih-conversation-viewer" "${GITHUB_BASE}/aih-conversation-viewer.git"
  VIEWER_DIR="${PROJECTS_DIR}/aih-conversation-viewer"
  if [ -d "$VIEWER_DIR" ]; then
    bun_install "$VIEWER_DIR" "aih-conversation-viewer"
    ok "Viewer installed — start with:"
    ok "  bun ${VIEWER_DIR}/src/server.ts"
    ok "  → http://localhost:4446"
  fi
else
  ok "Viewer skipped — clone manually: git clone ${GITHUB_BASE}/aih-conversation-viewer.git"
fi

# ── Step 7: Wire shell RC file ─────────────────────────────────────────────

print_step "Configuring shell environment"

RC_FILE="$(detect_rc)"
wire_rc "$RC_FILE"
# On macOS, login shells source .bash_profile, not .bashrc
if [[ "$PLATFORM" == "Darwin" ]] && [ "$RC_FILE" != "${HOME}/.bash_profile" ]; then
  wire_rc "${HOME}/.bash_profile"
fi

# Load keys for the rest of this install session
# shellcheck disable=SC1090
source "$ENV_FILE"

# ── Step 8: Configure ~/.claude/settings.json ─────────────────────────────

print_step "Configuring Claude Code"

PROXY_PATH="${PROJECTS_DIR}/aih-privacy-proxy"
MW_PATH="${PROJECTS_DIR}/aih-privacy-middleware"
PP_PATH="${PROJECTS_DIR}/aih-prompt-protection"
SG_PATH="${PROJECTS_DIR}/supply-guard-hook"

if [ ! -f "$CLAUDE_SETTINGS" ]; then
  warn "~/.claude/settings.json not found — skipping (run again after installing Claude Code)"
else
  python3 - "$CLAUDE_SETTINGS" "$PROXY_PATH" "$MW_PATH" "$PP_PATH" "$SG_PATH" "$TIER" "$SELF_DIR" <<'PYEOF'
import sys, json, re

settings_path = sys.argv[1]
proxy_path    = sys.argv[2]
mw_path       = sys.argv[3]
pp_path       = sys.argv[4]  # unused at tier<3 but kept for clarity
sg_path       = sys.argv[5]  # unused at tier<3
tier          = int(sys.argv[6])
self_dir      = sys.argv[7]  # aih-security umbrella repo (bin/aih-status)
proxy_url     = "http://localhost:4444"

with open(settings_path, 'r') as f:
    raw = f.read()
raw = re.sub(r',(\s*[}\]])', r'\1', raw)
settings = json.loads(raw)

changed = []

env = settings.setdefault('env', {})
if env.get('ANTHROPIC_BASE_URL') != proxy_url:
    env['ANTHROPIC_BASE_URL'] = proxy_url
    changed.append(f"  + ANTHROPIC_BASE_URL → {proxy_url}")

hooks = settings.setdefault('hooks', {})

# SessionStart: auto-start proxy
ss = hooks.setdefault('SessionStart', [])
if not any('llm-proxy' in str(g) or 'proxy.sh' in str(g) for g in ss):
    ss.append({'hooks': [{'type': 'command', 'command': f'{proxy_path}/proxy.sh start'}]})
    changed.append("  + SessionStart hook (proxy auto-start)")

# SessionStart: default-on visibility line (aih-status --brief)
status_cmd = f'{self_dir}/bin/aih-status --brief'
if not any('aih-status' in str(g) for g in ss):
    ss.append({'hooks': [{'type': 'command', 'command': status_cmd}]})
    changed.append("  + SessionStart hook (aih-status visibility)")

if tier >= 2:
    # UserPromptSubmit: prompt guard
    ups = hooks.setdefault('UserPromptSubmit', [])
    cmd_ups = f'bun {mw_path}/src/hooks/PrivacyPromptGuard.hook.ts'
    if not any(cmd_ups in str(g) for g in ups):
        ups.append({'hooks': [{'type': 'command', 'command': cmd_ups}]})
        changed.append("  + UserPromptSubmit: PrivacyPromptGuard")

    # PreToolUse: Bash, Write, Edit tool guard
    ptu = hooks.setdefault('PreToolUse', [])
    cmd_tool = f'bun {mw_path}/src/hooks/PrivacyToolGuard.hook.ts'
    for matcher in ['Bash', 'Write', 'Edit']:
        entry = {'matcher': matcher, 'hooks': [{'type': 'command', 'command': cmd_tool}]}
        if not any(g.get('matcher') == matcher and cmd_tool in str(g) for g in ptu):
            ptu.append(entry)
            changed.append(f"  + PreToolUse/{matcher}: PrivacyToolGuard")

    # Stop: response scanner
    stop = hooks.setdefault('Stop', [])
    cmd_stop = f'bun {mw_path}/src/hooks/PrivacyResponseScanner.hook.ts'
    if not any(cmd_stop in str(g) for g in stop):
        stop.append({'hooks': [{'type': 'command', 'command': cmd_stop}]})
        changed.append("  + Stop: PrivacyResponseScanner")

if tier >= 3:
    # PreToolUse/Bash: supply-guard (separate entry, has higher latency)
    ptu = hooks.setdefault('PreToolUse', [])
    cmd_sg = f'bun {sg_path}/src/hooks/SupplyGuard.hook.ts'
    bash_entries = [g for g in ptu if g.get('matcher') == 'Bash']
    already = any(cmd_sg in str(g) for g in bash_entries)
    if not already:
        ptu.append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': cmd_sg}]})
        changed.append("  + PreToolUse/Bash: SupplyGuard")

if changed:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    for msg in changed:
        print(msg)
    print(f"  ✓ {settings_path} updated")
else:
    print("  ✓ settings.json already up to date")
PYEOF
fi

# ── Step 9: Verify installation ────────────────────────────────────────────

print_step "Verification smoke test"

echo "  Starting proxy..."
"${PROXY_PATH}/proxy.sh" start 2>/dev/null || true
sleep 1

if curl -sf "http://localhost:4444/health" > /dev/null 2>&1; then
  health="$(curl -sf http://localhost:4444/health)"
  vault_mode="$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vaultMode','?'))" 2>/dev/null || echo "?")"
  ok "Proxy running — vault mode: ${vault_mode}"
  if [ "$vault_mode" = "memory" ]; then
    warn "Vault mode is 'memory' — LLM_PRIVACY_VAULT_KEY not in proxy's environment"
    warn "Run: source ${ENV_FILE} && ${PROXY_PATH}/proxy.sh restart"
  fi
else
  warn "Proxy health check failed — check ${LLM_PRIVACY_DIR}/proxy.log"
fi

if [ "$TIER" -ge 2 ] && [ -d "${PROJECTS_DIR}/aih-privacy-middleware" ]; then
  result="$(echo '{"prompt":"fix the null check in auth.ts"}' | bun "${MW_PATH}/src/hooks/PrivacyPromptGuard.hook.ts" 2>/dev/null || echo 'error')"
  if echo "$result" | grep -q '"decision":"allow"' 2>/dev/null; then
    ok "Middleware: benign prompt → allow"
  else
    warn "Middleware smoke test inconclusive (result: ${result:0:80})"
  fi
fi

if [ "$TIER" -ge 3 ] && [ -d "${PROJECTS_DIR}/supply-guard-hook" ]; then
  sc_result="$(echo '{"tool_name":"Bash","tool_input":{"command":"pip install coloama"}}' | \
    bun "${SG_PATH}/src/hooks/SupplyGuard.hook.ts" 2>/dev/null; echo "exit:$?")"
  if echo "$sc_result" | grep -q 'exit:[12]'; then
    ok "Supply-guard: pip install coloama → blocked"
  else
    warn "Supply-guard smoke test inconclusive"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo " aih-security Tier ${TIER} install complete"
echo "════════════════════════════════════════"
echo ""
echo "  Keys location:   ${ENV_FILE}"
echo "  Proxy logs:      ${LLM_PRIVACY_DIR}/proxy.log"
echo "  Audit logs:      ${LLM_PRIVACY_DIR}/audit.jsonl"
echo ""
echo "  Load keys now:"
echo "    source ${ENV_FILE}"
echo ""
echo "  Restart Claude Code to pick up settings.json changes."
echo ""
if [ -d "${PROJECTS_DIR}/aih-conversation-viewer" ]; then
  echo "  Conversation Viewer:"
  echo "    source ${ENV_FILE}"
  echo "    bun ${PROJECTS_DIR}/aih-conversation-viewer/src/server.ts"
  echo "    → http://localhost:4446"
  echo ""
fi
if [ "$TIER" -ge 3 ] && [ -d "${PROJECTS_DIR}/supply-guard-proxy" ]; then
  echo "  supply-guard-proxy (optional, not auto-configured):"
  echo "    Network-level companion to supply-guard-hook. Patches pip/npm/cargo"
  echo "    config to route through a local policy-enforcing proxy — a system-wide"
  echo "    change, so it's cloned but not run automatically. To enable:"
  echo "      cd ${PROJECTS_DIR}/supply-guard-proxy"
  echo "      pip install -r requirements.txt && ./scripts/setup.sh"
  echo "      ./scripts/proxy.sh start"
  echo ""
fi
echo "  Docs:"
echo "    QUICKSTART:    ${PROJECTS_DIR}/aih-security/QUICKSTART.md"
echo "    Observability: ${PROJECTS_DIR}/aih-security/docs/observability.md"
echo "    Testing:       ${PROJECTS_DIR}/aih-security/docs/testing.md"
echo ""
