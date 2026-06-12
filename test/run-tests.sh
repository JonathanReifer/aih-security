#!/usr/bin/env bash
# run-tests.sh — smoke test suite for the aih-security stack
# Usage: bash run-tests.sh [--tier=1|2|3] [--docker]
#
# Runs end-to-end checks for each installed tier. Pass --tier to limit scope.
# Pass --docker to adjust paths for the Dockerfile.debian test image.

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────

PROJECTS_DIR="${HOME}/Projects"
TIER="${AIH_TEST_TIER:-3}"
DOCKER=false

for arg in "$@"; do
  case "$arg" in
    --tier=*) TIER="${arg#*=}" ;;
    --docker) DOCKER=true; PROJECTS_DIR="/workspace" ;;
  esac
done

PROXY_PORT=4444
PROXY_URL="http://localhost:${PROXY_PORT}"
PROXY_PATH="${PROJECTS_DIR}/llm-privacy-proxy"
MW_PATH="${PROJECTS_DIR}/llm-privacy-middleware"
SG_PATH="${PROJECTS_DIR}/supply-guard-hook"
FIXTURES_DIR="$(cd "$(dirname "$0")/fixtures"; pwd)"

PASS=0
FAIL=0
SKIP=0

# ── Helpers ───────────────────────────────────────────────────────────────

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  - $1 (skipped)"; SKIP=$((SKIP+1)); }
section() { echo ""; echo "▶ $1"; }

# Run hook script with JSON input; return its stdout and capture exit code
run_hook() {
  local hook_file="$1" input="$2"
  echo "$input" | bun "$hook_file" 2>/dev/null
  return ${PIPESTATUS[1]:-$?}
}

# ── Tier 1: Proxy ─────────────────────────────────────────────────────────

section "Tier 1 — Proxy"

if [ ! -d "$PROXY_PATH" ]; then
  skip "llm-privacy-proxy not found at ${PROXY_PATH}"
else
  # Start proxy if not running
  if ! curl -sf "${PROXY_URL}/health" >/dev/null 2>&1; then
    source "${HOME}/.llm-privacy/.env.sh" 2>/dev/null || true
    "${PROXY_PATH}/proxy.sh" start 2>/dev/null || true
    sleep 1
  fi

  if curl -sf "${PROXY_URL}/health" >/dev/null 2>&1; then
    pass "Proxy health endpoint responds"

    vault_mode="$(curl -sf "${PROXY_URL}/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vaultMode','?'))" 2>/dev/null || echo "?")"
    if [ "$vault_mode" = "sqlite" ]; then
      pass "Vault mode: sqlite (keys loaded)"
    elif [ "$vault_mode" = "memory" ]; then
      fail "Vault mode: memory — LLM_PRIVACY_VAULT_KEY not in proxy environment"
    else
      skip "Vault mode unknown: ${vault_mode}"
    fi
  else
    fail "Proxy not responding on ${PROXY_URL}"
  fi
fi

[ "$TIER" -lt 2 ] && { echo ""; echo "Tier 1 only — stopping here (--tier=${TIER})"; } && true

# ── Tier 2: Middleware ─────────────────────────────────────────────────────

if [ "$TIER" -ge 2 ]; then
  section "Tier 2 — Middleware"

  if [ ! -d "$MW_PATH" ]; then
    skip "llm-privacy-middleware not found at ${MW_PATH}"
  else
    PROMPT_GUARD="${MW_PATH}/src/hooks/PrivacyPromptGuard.hook.ts"
    TOOL_GUARD="${MW_PATH}/src/hooks/PrivacyToolGuard.hook.ts"

    # Benign prompts should allow
    while IFS= read -r prompt || [[ -n "$prompt" ]]; do
      [[ "$prompt" =~ ^#.*$ || -z "$prompt" ]] && continue
      result="$(echo "{\"prompt\":\"${prompt}\"}" | bun "$PROMPT_GUARD" 2>/dev/null || true)"
      if echo "$result" | grep -q '"decision":"allow"' 2>/dev/null || echo "$result" | grep -q '"continue":true' 2>/dev/null; then
        pass "Benign prompt allowed: ${prompt:0:50}"
      else
        fail "Benign prompt was NOT allowed: ${prompt:0:50} → ${result:0:80}"
      fi
    done < "${FIXTURES_DIR}/benign_prompts.txt"

    # Injection prompts should block or ask (non-zero exit or decision != allow)
    while IFS= read -r payload || [[ -n "$payload" ]]; do
      [[ "$payload" =~ ^#.*$ || -z "$payload" ]] && continue
      # Escape the payload for JSON
      escaped="$(echo "$payload" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().rstrip()))" 2>/dev/null | tr -d '"')"
      result="$(echo "{\"prompt\":\"${escaped}\"}" | bun "$PROMPT_GUARD" 2>/dev/null || echo "exit_nonzero")"
      if echo "$result" | grep -qE '"decision":"(block|ask)"' 2>/dev/null || [ "$result" = "exit_nonzero" ]; then
        pass "Injection payload blocked/asked: ${payload:0:50}"
      else
        fail "Injection payload was ALLOWED: ${payload:0:50} → ${result:0:80}"
      fi
    done < "${FIXTURES_DIR}/injection_payloads.txt"

    # Secrets in tool input should block/ask
    secret_input='{"tool_name":"Bash","tool_input":{"command":"echo OPENAI_API_KEY=sk-test-abc123defg456"}}'
    result="$(echo "$secret_input" | bun "$TOOL_GUARD" 2>/dev/null || echo "exit_nonzero")"
    if echo "$result" | grep -qE '"decision":"(block|ask)"' 2>/dev/null || [ "$result" = "exit_nonzero" ]; then
      pass "Secret in Bash command → blocked/asked"
    else
      fail "Secret in Bash command was NOT flagged → ${result:0:80}"
    fi
  fi
fi

# ── Tier 3: ATLAS + Supply Chain ──────────────────────────────────────────

if [ "$TIER" -ge 3 ]; then
  section "Tier 3 — Supply Chain"

  if [ ! -d "$SG_PATH" ]; then
    skip "supply-guard-hook not found at ${SG_PATH}"
  else
    SG_HOOK="${SG_PATH}/src/hooks/SupplyGuard.hook.ts"

    while IFS= read -r cmd || [[ -n "$cmd" ]]; do
      [[ "$cmd" =~ ^#.*$ || -z "$cmd" ]] && continue
      input="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${cmd}\"}}"
      exit_code=0
      echo "$input" | bun "$SG_HOOK" >/dev/null 2>&1 || exit_code=$?
      if [ "$exit_code" -ne 0 ]; then
        pass "Supply-guard blocked: ${cmd}"
      else
        fail "Supply-guard ALLOWED known-bad: ${cmd}"
      fi
    done < "${FIXTURES_DIR}/supply_chain_block.txt"

    # Legitimate install should pass
    legit_input='{"tool_name":"Bash","tool_input":{"command":"pip install requests"}}'
    exit_code=0
    echo "$legit_input" | bun "$SG_HOOK" >/dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
      pass "Legitimate package (requests) allowed"
    else
      fail "Legitimate package (requests) was blocked (false positive)"
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "════════════════════════════════"
echo ""

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
