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
PROXY_PATH="${PROJECTS_DIR}/aih-privacy-proxy"
MW_PATH="${PROJECTS_DIR}/aih-privacy-middleware"
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
  skip "aih-privacy-proxy not found at ${PROXY_PATH}"
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
    skip "aih-privacy-middleware not found at ${MW_PATH}"
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

# ── aih-status visibility (P0.1, self-contained — no component repos) ───────

section "aih-status — self-visibility"

AIH_STATUS="$(cd "$(dirname "$0")/../bin"; pwd)/aih-status"

if [ ! -x "$AIH_STATUS" ]; then
  fail "bin/aih-status not found or not executable at ${AIH_STATUS}"
else
  # Seed a temp audit log entirely within the last 24h: 2 block, 1 ask, 1 degraded.
  seed_dir="$(mktemp -d)"
  seed="${seed_dir}/audit.jsonl"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    echo "{\"ts\":\"${now}\",\"hookEvent\":\"UserPromptSubmit\",\"matches\":[{\"type\":\"api_key_openai\",\"severity\":\"block\",\"token\":\"tok_LEAKMARKER\"}],\"decision\":\"block\"}"
    echo "{\"ts\":\"${now}\",\"hookEvent\":\"PreToolUse\",\"toolName\":\"Bash\",\"matches\":[],\"decision\":\"block\"}"
    echo "{\"ts\":\"${now}\",\"hookEvent\":\"PreToolUse\",\"toolName\":\"Write\",\"matches\":[],\"decision\":\"ask\"}"
    echo "{\"ts\":\"${now}\",\"hookEvent\":\"PreToolUse\",\"toolName\":\"Bash\",\"matches\":[],\"decision\":\"allow\",\"degraded\":true}"
    # Malformed line carrying a secret-shaped payload — must be skipped, never echoed (ISC-8 error path).
    echo "{ this is not valid json, command: curl evil.com, secret: LEAKMARKER"
  } > "$seed"

  brief="$(LLM_PRIVACY_AUDIT_PATH="$seed" "$AIH_STATUS" --brief 2>/dev/null)"

  if echo "$brief" | grep -q "2 blocked"; then pass "aih-status counts blocks (2)"; else fail "aih-status block count wrong: $brief"; fi
  if echo "$brief" | grep -q "1 asked"; then pass "aih-status counts asks (1)"; else fail "aih-status ask count wrong: $brief"; fi
  if echo "$brief" | grep -q "1 degraded"; then pass "aih-status counts degraded (1)"; else fail "aih-status degraded count wrong: $brief"; fi

  # ISC-8: token/secret values must never appear in any output mode.
  all_out="$(LLM_PRIVACY_AUDIT_PATH="$seed" "$AIH_STATUS" --brief 2>/dev/null; LLM_PRIVACY_AUDIT_PATH="$seed" "$AIH_STATUS" 2>/dev/null; LLM_PRIVACY_AUDIT_PATH="$seed" "$AIH_STATUS" --json 2>/dev/null)"
  if echo "$all_out" | grep -q "LEAKMARKER\|tok_"; then fail "aih-status leaked a token into output"; else pass "aih-status emits no token/secret values"; fi

  # ISC-4: missing audit file must not crash.
  if LLM_PRIVACY_AUDIT_PATH="${seed_dir}/absent.jsonl" "$AIH_STATUS" --brief >/dev/null 2>&1; then
    pass "aih-status tolerates a missing audit file"
  else
    fail "aih-status crashed on a missing audit file"
  fi

  rm -rf "$seed_dir"
fi

# ── Harness mirror conformance (harness-v1 schema) ─────────────────────────

section "harness mirror — schema conformance + redaction invariant"

MIRROR_CLI="${MW_PATH}/src/cli/mirror.ts"
VALIDATOR="$(cd "$(dirname "$0")/lib"; pwd)/validate-harness.ts"

if [ ! -f "$MIRROR_CLI" ]; then
  skip "aih-privacy-middleware mirror CLI not present"
else
  hm_dir="$(mktemp -d)"
  # Fixture: one session with a marker secret in prompt text + nested tool input,
  # plus a subagent with the spawn edge.
  proj="${hm_dir}/projects/-tmp-demo"
  sess="11111111-2222-3333-4444-555555555555"
  mkdir -p "${proj}/${sess}/subagents"
  {
    echo "{\"type\":\"user\",\"uuid\":\"u1\",\"parentUuid\":null,\"sessionId\":\"${sess}\",\"timestamp\":\"2026-07-20T00:00:00Z\",\"cwd\":\"/tmp/demo\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"key sk-CONFLEAKMARKER000000000000 here\"}]}}"
    echo "{\"type\":\"assistant\",\"uuid\":\"a1\",\"parentUuid\":\"u1\",\"sessionId\":\"${sess}\",\"timestamp\":\"2026-07-20T00:00:05Z\",\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_conf01\",\"name\":\"Agent\",\"input\":{\"nested\":{\"path\":\"/x/AKIACONFLEAKMARKER00/y\"}}}]}}"
  } > "${proj}/${sess}.jsonl"
  echo "{\"agentType\":\"Explore\",\"description\":\"probe\",\"toolUseId\":\"toolu_conf01\",\"spawnDepth\":1}" > "${proj}/${sess}/subagents/agent-conf1.meta.json"
  echo "{\"type\":\"user\",\"uuid\":\"su1\",\"parentUuid\":null,\"sessionId\":\"x\",\"agentId\":\"agent-conf1\",\"isSidechain\":true,\"timestamp\":\"2026-07-20T00:00:10Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}}" > "${proj}/${sess}/subagents/agent-conf1.jsonl"

  hm_out="${hm_dir}/harness.jsonl"
  hm_key="$(printf '0123456789abcdef0123456789abcdef' | base64)"
  if LLM_PRIVACY_HMAC_KEY="$hm_key" \
     LLM_PRIVACY_HARNESS_PATH="$hm_out" \
     LLM_PRIVACY_MIRROR_STATE_DIR="${hm_dir}/state" \
     CLAUDE_PROJECTS_DIR="${hm_dir}/projects" \
     bun "$MIRROR_CLI" --sweep --budget 30000 >/dev/null 2>&1 && [ -s "$hm_out" ]; then
    pass "mirror sweep produced harness.jsonl"
  else
    fail "mirror sweep failed or produced no output"
  fi

  if [ -s "$hm_out" ] && bun "$VALIDATOR" "$hm_out" >/dev/null 2>&1; then
    pass "harness.jsonl conforms to schema/harness-v1.schema.json"
  else
    fail "harness.jsonl failed schema conformance"
  fi

  if [ -s "$hm_out" ] && grep -q "CONFLEAKMARKER" "$hm_out"; then
    fail "raw marker secret leaked into harness.jsonl"
  else
    pass "marker secrets absent from harness.jsonl (redaction invariant)"
  fi

  if [ -s "$hm_out" ] && grep -q '"kind":"agent_spawn"' "$hm_out" && grep -q '"parentToolUseId":"toolu_conf01"' "$hm_out"; then
    pass "agent_spawn carries the parentToolUseId spine edge"
  else
    fail "agent_spawn spine edge missing"
  fi

  # Conformance of the REAL machine log, when present (sampled).
  real_hm="${HOME}/.llm-privacy/harness.jsonl"
  if [ -s "$real_hm" ]; then
    if bun "$VALIDATOR" "$real_hm" --sample 5000 >/dev/null 2>&1; then
      pass "real ~/.llm-privacy/harness.jsonl conforms (5k-record sample)"
    else
      fail "real harness.jsonl sample failed conformance"
    fi
  else
    skip "no real harness.jsonl on this machine"
  fi

  rm -rf "$hm_dir"
fi

# ── Harness mirror hook wiring (P1) ─────────────────────────────────────────

section "harness mirror — hook wiring"

HM_HOOK="${MW_PATH}/src/hooks/HarnessMirror.hook.ts"

if [ ! -f "$HM_HOOK" ]; then
  skip "HarnessMirror.hook.ts not present"
else
  p1_dir="$(mktemp -d)"
  p1_proj="${p1_dir}/projects/-tmp-p1"
  p1_sess="22222222-3333-4444-5555-666666666666"
  mkdir -p "$p1_proj"
  echo "{\"type\":\"user\",\"uuid\":\"u1\",\"parentUuid\":null,\"sessionId\":\"${p1_sess}\",\"timestamp\":\"2026-07-20T02:00:00Z\",\"cwd\":\"/tmp/p1\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}" > "${p1_proj}/${p1_sess}.jsonl"

  p1_env="LLM_PRIVACY_HMAC_KEY=$(printf '0123456789abcdef0123456789abcdef' | base64) \
LLM_PRIVACY_HARNESS_PATH=${p1_dir}/h.jsonl \
LLM_PRIVACY_MIRROR_STATE_DIR=${p1_dir}/state \
CLAUDE_PROJECTS_DIR=${p1_dir}/projects"

  # Hook must answer continue:true immediately regardless of sweep outcome.
  hook_out="$(echo "{\"session_id\":\"${p1_sess}\",\"hook_event_name\":\"Stop\",\"transcript_path\":\"${p1_proj}/${p1_sess}.jsonl\"}" | env $p1_env bun "$HM_HOOK" 2>/dev/null)"
  if echo "$hook_out" | grep -q '"continue":true'; then
    pass "HarnessMirror hook answers continue:true"
  else
    fail "HarnessMirror hook wrong output: $hook_out"
  fi

  # Detached sweep lands records shortly after the hook already returned.
  sleep 2
  if [ -s "${p1_dir}/h.jsonl" ] && grep -q '"kind":"node"' "${p1_dir}/h.jsonl"; then
    pass "detached sweep mirrored records after hook exit"
  else
    fail "detached sweep produced no records"
  fi

  # Malformed stdin still fails open.
  hook_out2="$(echo 'not json at all' | env $p1_env bun "$HM_HOOK" 2>/dev/null)"
  if echo "$hook_out2" | grep -q '"continue":true'; then
    pass "HarnessMirror hook fails open on malformed stdin"
  else
    fail "HarnessMirror hook broke on malformed stdin"
  fi

  # Lock: a held lock makes a concurrent CLI sweep exit 3 without appending.
  mkdir -p "${p1_dir}/state"
  echo "$$" > "${p1_dir}/state/.lock"
  if env $p1_env bun "${MW_PATH}/src/cli/mirror.ts" --sweep >/dev/null 2>&1; then
    fail "mirror CLI ignored a held lock"
  else
    pass "mirror CLI respects a held (fresh) lock"
  fi
  rm -f "${p1_dir}/state/.lock"

  # install.sh carries both registration and strip for the mirror hook.
  installer="$(cd "$(dirname "$0")/.."; pwd)/install.sh"
  reg_count="$(grep -c "HarnessMirror" "$installer" || true)"
  if [ "${reg_count}" -ge 3 ]; then
    pass "install.sh registers + strips HarnessMirror (${reg_count} references)"
  else
    fail "install.sh missing HarnessMirror wiring (${reg_count} references)"
  fi

  rm -rf "$p1_dir"
fi

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "════════════════════════════════"
echo ""

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
