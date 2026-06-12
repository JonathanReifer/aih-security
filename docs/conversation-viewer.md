# Conversation Viewer Integration

The [aih-conversation-viewer](../../../aih-conversation-viewer) displays Claude Code sessions
with full context: conversation bubbles, tool decisions, hook execution timing, cost, and
PII detection. With the proxy running, it also shows ATLAS security findings in each session.

---

## What Works Without Any Changes (Tier 1)

If the proxy is running with `LLM_PRIVACY_LOG_PROMPTS=tokenized`, it writes
`~/.llm-privacy/prompts.jsonl`. The viewer reads this file automatically and shows:

- Conversation bubbles (tokenized, no real secrets)
- PII match count per session (from `matchCount` field)
- Model used

Start the viewer:
```bash
cd ~/Projects/aih-conversation-viewer
bun src/server.ts
# → listening on http://localhost:4446
```

Select "Proxy" source in the top bar to see proxy sessions.

---

## Security Findings in the Viewer (Tier 3)

When the proxy pipeline runs ATLAS scanners (via `LlmProtectionProxyModule`), it writes
`findings` and `decision` fields to each `prompts.jsonl` entry. The viewer surfaces these
as:

- A **Security Findings panel** above the conversation bubbles showing each finding,
  severity badge, and ATLAS technique ID
- A **🛡 N blocked / ⚠ N findings** badge in the session header

To enable this:

1. Register `LlmProtectionProxyModule` in the proxy pipeline (see QUICKSTART.md §Tier 3)
2. Set `LLM_PRIVACY_LOG_PROMPTS=tokenized` so the proxy writes the log file
3. Start the proxy and the viewer

The proxy writes findings only when `LLM_PRIVACY_LOG_PROMPTS` is not `none`.

---

## OTEL (Optional — Loki Required)

If you have a Loki instance running (default: `localhost:3100`) and Claude Code is
instrumented with the PAI OTEL hook, the viewer also shows:

- Full hook execution timeline (`claude_code.hook_execution_complete` events)
- Per-tool decision history (auto/approved/blocked/rejected)
- API cost per session

Set the Loki URL:
```bash
LOKI_URL=http://your-loki:3100 bun src/server.ts
```

Select "Unified" source to see both proxy content and OTEL events correlated into a single
timeline.

---

## Data Flows

```
Proxy (Tier 1+)
  POST /v1/messages
    → tokenize → forward → detokenize
    → write ~/.llm-privacy/prompts.jsonl
         { ts, sessionId, matchCount, tokenized, model,
           findings?, decision? }  ← findings added by Tier 3 scanner

Viewer reads prompts.jsonl every request
  → segment into sessions (90-min gap heuristic)
  → aggregate findings per session
  → serve via /api/sessions

OTEL (optional, Tier 3 with Loki)
  Claude Code hook → OTEL exporter → Loki
  Viewer queries Loki via /loki/api/v1/query_range
  Correlated by session ID ± 10 minutes
```

---

## Starting Both Together

```bash
# Terminal 1: proxy
source ~/.llm-privacy/.env.sh
LLM_PRIVACY_LOG_PROMPTS=tokenized ~/Projects/llm-privacy-proxy/proxy.sh start

# Terminal 2: viewer
cd ~/Projects/aih-conversation-viewer
bun src/server.ts

# Then open: http://localhost:4446
```

Or add a start script:
```bash
# ~/Projects/aih-security/start-viewer.sh
source ~/.llm-privacy/.env.sh
LLM_PRIVACY_LOG_PROMPTS=tokenized ~/Projects/llm-privacy-proxy/proxy.sh start
echo "Starting viewer at http://localhost:4446..."
bun ~/Projects/aih-conversation-viewer/src/server.ts
```
