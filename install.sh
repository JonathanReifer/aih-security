#!/usr/bin/env bash
# install.sh — unified installer for the aih-security stack
# Usage: bash install.sh [--tier=1|2|3] [--dir=PATH] [--skip-clone]
#
# Tiers:
#   1 — proxy only (transparent tokenization)
#   2 — proxy + middleware (hook-based PII guard)
#   3 — full stack: proxy + middleware + prompt-protection + supply-guard (default)

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────

TIER=""
PROJECTS_DIR="${HOME}/Projects"
SKIP_CLONE=false
LLM_PRIVACY_DIR="${LLM_PRIVACY_DIR:-${HOME}/.llm-privacy}"
ENV_FILE="${LLM_PRIVACY_DIR}/.env.sh"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

# ── Arg parsing ───────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --tier=*)  TIER="${arg#*=}" ;;
    --dir=*)   PROJECTS_DIR="${arg#*=}" ;;
    --skip-clone) SKIP_CLONE=true ;;
    --help|-h)
      echo "Usage: bash install.sh [--tier=1|2|3] [--dir=PATH] [--skip-clone]"
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

GITLAB_BASE="ssh://git@gitlab.rsolabs.com:223/ai"

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
clone_or_update "llm-privacy-proxy"   "${GITLAB_BASE}/llm-privacy-proxy.git"

if [ "$TIER" -ge 2 ]; then
  clone_or_update "llm-privacy-middleware" "${GITLAB_BASE}/llm-privacy-middleware.git"
fi

if [ "$TIER" -ge 3 ]; then
  clone_or_update "llm_prompt_protection"  "${GITLAB_BASE}/llm-prompt-protection.git"
  clone_or_update "supply-guard-hook"      "${GITLAB_BASE}/supply-guard-hook.git"
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

bun_install "${PROJECTS_DIR}/llm-privacy-proxy"       "llm-privacy-proxy"
[ "$TIER" -ge 2 ] && bun_install "${PROJECTS_DIR}/llm-privacy-middleware"    "llm-privacy-middleware"
[ "$TIER" -ge 3 ] && bun_install "${PROJECTS_DIR}/llm_prompt_protection"     "llm_prompt_protection"
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

PROXY_PATH="${PROJECTS_DIR}/llm-privacy-proxy"
MW_PATH="${PROJECTS_DIR}/llm-privacy-middleware"
PP_PATH="${PROJECTS_DIR}/llm_prompt_protection"
SG_PATH="${PROJECTS_DIR}/supply-guard-hook"

if [ ! -f "$CLAUDE_SETTINGS" ]; then
  warn "~/.claude/settings.json not found — skipping (run again after installing Claude Code)"
else
  python3 - "$CLAUDE_SETTINGS" "$PROXY_PATH" "$MW_PATH" "$PP_PATH" "$SG_PATH" "$TIER" <<'PYEOF'
import sys, json, re

settings_path = sys.argv[1]
proxy_path    = sys.argv[2]
mw_path       = sys.argv[3]
pp_path       = sys.argv[4]  # unused at tier<3 but kept for clarity
sg_path       = sys.argv[5]  # unused at tier<3
tier          = int(sys.argv[6])
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

if [ "$TIER" -ge 2 ] && [ -d "${PROJECTS_DIR}/llm-privacy-middleware" ]; then
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
echo "  Docs:"
echo "    QUICKSTART: ${PROJECTS_DIR}/aih-security/QUICKSTART.md"
echo "    Testing:    ${PROJECTS_DIR}/aih-security/docs/testing.md"
echo ""
