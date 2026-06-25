# Bypassing or Disabling the Proxy

Use this guide when the proxy is broken, you need a clean debug session, or you want to temporarily or permanently disable aih-security protections.

## Quick-reference decision table

| Scenario | Method | Proxy still running | settings.json changed |
|---|---|---|---|
| Hard-blocking too aggressive (400 errors) | 1 — Soft-disable | Yes | No |
| One-off debug session, no config changes | 2 — Per-session unset | Yes | No |
| Proxy is crashing or broken | 3 + 2 — Stop + unset | No | No |
| Cleanest temporary full bypass | 4 — Stop + unset | No | No |
| Permanent removal until reinstalled | 5 — Edit settings.json | No | Yes |

---

## Method 1 — Soft-disable (proxy runs, blocking off)

**When to use:** The proxy is detecting a secret/PII pattern and returning HTTP 400 errors, but you still want tokenization active (secrets appear as tokens in prompts rather than plaintext).

```bash
# Edit ~/.llm-privacy/.env.sh and add or change this line:
export LLM_PRIVACY_BLOCK_ENABLED=false

# Restart the proxy to pick up the change:
~/Projects/aih-privacy-proxy/proxy.sh restart

# Verify:
curl -s http://localhost:4444/health | jq .blockEnabled
# → false
```

**Re-enable:**
```bash
# In ~/.llm-privacy/.env.sh, set:
export LLM_PRIVACY_BLOCK_ENABLED=true
~/Projects/aih-privacy-proxy/proxy.sh restart
```

---

## Method 2 — Per-session bypass (current shell only)

**When to use:** You need one terminal session to talk directly to api.anthropic.com without any proxy. Settings stay untouched — other terminals and harnesses are unaffected.

```bash
# Unset the env var for this shell only:
unset ANTHROPIC_BASE_URL

# Or point directly at Anthropic:
export ANTHROPIC_BASE_URL=https://api.anthropic.com

# Then launch Claude Code (or any harness) normally.
```

**Re-enable for this shell:**
```bash
export ANTHROPIC_BASE_URL=http://localhost:4444
```

**For Cursor / OpenCode / Grok:** Same approach — unset in the shell that launches the harness, or remove `ANTHROPIC_BASE_URL` from that project's `.env` or harness config file for that session only.

---

## Method 3 — Stop the proxy daemon

**When to use:** The proxy process is crashing, consuming resources, or you need to confirm it is the cause of an issue.

```bash
~/Projects/aih-privacy-proxy/proxy.sh stop

# Confirm it is not running:
~/Projects/aih-privacy-proxy/proxy.sh status
# → Status: not running
```

After stopping the proxy, Claude Code will fail to connect if `ANTHROPIC_BASE_URL` still points at port 4444. Combine with Method 2 (unset the env var) unless you want connection errors to confirm the proxy was the issue.

**Restart:**
```bash
source ~/.llm-privacy/.env.sh
~/Projects/aih-privacy-proxy/proxy.sh start
```

---

## Method 4 — Cleanest temporary full bypass

**When to use:** You want a completely clean session with no proxy involvement, then a clean re-enable afterward. No config files are changed.

```bash
# 1. Stop the proxy:
~/Projects/aih-privacy-proxy/proxy.sh stop

# 2. Unset the env var for this shell:
unset ANTHROPIC_BASE_URL

# Confirm direct routing:
echo "${ANTHROPIC_BASE_URL:-"(unset — routing direct to api.anthropic.com)"}"

# ... do your work ...

# 3. Re-enable when done:
source ~/.llm-privacy/.env.sh
~/Projects/aih-privacy-proxy/proxy.sh start
export ANTHROPIC_BASE_URL=http://localhost:4444
```

---

## Method 5 — Permanent disable (edit settings.json)

**When to use:** You want to remove aih-security from Claude Code entirely until you manually re-enable it. This removes the proxy env var and the SessionStart auto-start hook from `~/.claude/settings.json`.

```bash
python3 -c "
import json, os
path = os.path.expanduser('~/.claude/settings.json')
with open(path) as f: s = json.load(f)
s.get('env', {}).pop('ANTHROPIC_BASE_URL', None)
s.get('hooks', {}).pop('SessionStart', None)
with open(path, 'w') as f: json.dump(s, f, indent=2)
print('Done — removed ANTHROPIC_BASE_URL and SessionStart hook')
"

# Stop the running proxy:
~/Projects/aih-privacy-proxy/proxy.sh stop

# Restart Claude Code for the change to take effect.
```

> **Note:** Middleware hooks (UserPromptSubmit, PreToolUse, Stop) remain in settings.json after this operation because they do not depend on the proxy being active. To remove those as well, edit the `hooks` block in `~/.claude/settings.json` manually.

**Re-enable (idempotent):**
```bash
bash ~/Projects/aih-security/install.sh --tier=<1|2|3>
```
`install.sh` is safe to re-run — it will not duplicate settings or regenerate keys that already exist.

---

## Troubleshooting bypass issues

**Claude Code still shows 400 errors after unsetting `ANTHROPIC_BASE_URL`**
→ Claude Code caches the env at startup. Fully quit and relaunch after unsetting.

**Proxy won't stop (`proxy.sh stop` hangs)**
```bash
# Find and kill the proxy PID directly:
cat ~/.llm-privacy/.proxy.pid | xargs kill -9
rm ~/.llm-privacy/.proxy.pid
```

**After re-enable, proxy starts but Claude Code still routes direct**
→ The env var was unset in the shell that launched Claude Code. Either restart Claude Code in a new shell (where `~/.llm-privacy/.env.sh` is sourced), or set it explicitly:
```bash
export ANTHROPIC_BASE_URL=http://localhost:4444
```
