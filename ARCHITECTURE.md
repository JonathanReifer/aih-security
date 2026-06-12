# aih-security — Architecture

Four component projects compose into a unified LLM security layer. This repo (`aih-security`)
is the umbrella: it documents how they fit together and provides the installer, test harness,
and harness adapter templates for extending the stack beyond Claude Code.

---

## System Overview

```
 Claude Code (or Cursor / OpenCode / Grok Build)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                       AI Harness Session                                 │
 └───────────┬─────────────────────────────────────────┬────────────────────┘
             │ prompt events / tool calls / responses   │
             ▼                                          │
 ┌────────────────────────────────────┐                 │ (if proxy enabled)
 │   llm-privacy-middleware           │                 │
 │   (hook layer)                     │                 ▼
 │                                    │  ┌──────────────────────────────────┐
 │  UserPromptSubmit                  │  │  llm-privacy-proxy               │
 │    └─ HookPipeline                 │  │  (HTTP layer, port 4444)         │
 │         ├─ PrivacyHookModule       │  │                                  │
 │         ├─ LlmProtectionHookModule │  │  request phase:                  │
 │         └─ SupplyChainHookModule   │  │    ProxyPipeline                 │
 │                                    │  │      ├─ PrivacyProxyModule       │
 │  PreToolUse (Bash/Write/Edit)      │  │      └─ LlmProtectionProxyModule │
 │    └─ HookPipeline (same modules)  │  │                                  │
 │                                    │  │  → upstream api.anthropic.com    │
 │  Stop                              │  │                                  │
 │    └─ HookPipeline (advisory only) │  │  response phase (advisory):      │
 │                                    │  │    ProxyPipeline                 │
 │  ┌──────────────────────────────┐  │  └──────────────────────────────────┘
 │  │ worst-wins aggregation       │  │
 │  │ block > ask > allow          │  │  aih-security adapters
 │  │ Promise.allSettled           │  │  ┌──────────────────────────────────┐
 │  │ (fail-open on error)         │  │  │  adapters/cursor/hooks.json      │
 │  └──────────────────────────────┘  │  │  adapters/opencode/plugin.ts     │
 └────────────────────────────────────┘  │  adapters/grok/README.md         │
                                         └──────────────────────────────────┘
```

---

## Component Roles

**`llm-privacy-proxy`** — HTTP proxy between the LLM client and the upstream API (port 4444).
Tokenizes secrets and PII in outbound requests so the LLM never sees real values, then
detokenizes responses before the client sees them. Streaming is handled by a sliding-buffer
detokenizer. Vault is SQLite with AES-256-GCM. The only layer capable of bidirectional
transparent tokenization — hooks cannot rewrite prompts after submission.

**`llm-privacy-middleware`** — Hook scripts that intercept at three lifecycle events:
`UserPromptSubmit`, `PreToolUse`, and `Stop`. Runs a `HookPipeline` that evaluates all
registered modules and returns a block/ask/allow decision. Owns the file vault
(`vault.enc.json`) and the audit log for hook-layer detections. The three hook scripts are
thin wrappers — all logic lives in the module pipeline.

**`llm_prompt_protection`** — MITRE ATLAS–mapped scanner library. Provides
`LlmProtectionHookModule` (for middleware) and `LlmProtectionProxyModule` (for proxy).
Five scanners cover eight ATLAS techniques. Pure module — no vault, no hooks of its own.

**`supply-guard-hook`** — Supply chain protection for package install commands. Parses pip,
npm, bun, cargo, gem, and other package managers; scores for typosquatting, known malicious
packages, low popularity, custom registry overrides, and exec-mode risk. Can run standalone
or as `SupplyChainHookModule` registered into the middleware pipeline.

---

## Module Interface

Both pipelines use duck-typed structural TypeScript — no cross-project imports at the type
level. A module matches if its shape is compatible.

### HookModule (middleware)

```typescript
type HookEvent = "UserPromptSubmit" | "PreToolUse" | "Stop";

interface HookModule {
  readonly id: string;
  readonly events: HookEvent[];
  scan(input: HookInput, event: HookEvent): Promise<ModuleScanResult>;
}

interface ModuleScanResult {
  decision: "allow" | "ask" | "block";
  findings: ScanFinding[];
  durationMs: number;
  degraded?: boolean;
}
```

### ProxyModule (proxy)

```typescript
type ProxyPhase = "request" | "response";

interface ProxyModule {
  readonly id: string;
  readonly phases: ProxyPhase[];
  scan(text: string, phase: ProxyPhase, sessionId?: string): Promise<ModuleScanResult>;
}
```

### Registering modules

```typescript
// Middleware
const pipeline = createDefaultHookPipeline();   // PrivacyHookModule pre-registered
pipeline.register(new LlmProtectionHookModule());
pipeline.register(new SupplyChainHookModule());

// Proxy
const pipeline = createDefaultProxyPipeline();  // PrivacyProxyModule pre-registered
pipeline.register(new LlmProtectionProxyModule());
```

---

## Data Flow: Hook Path

```
UserPromptSubmit fires
  → stdin: { prompt, session_id }
  → HookPipeline.runHook("UserPromptSubmit", input)
      ├─ PrivacyHookModule.scan()       → 23-pattern PII/secrets check
      ├─ LlmProtectionHookModule.scan() → InjectionScanner + AdversarialScanner
      └─ SupplyChainHookModule.scan()   → no-op on UserPromptSubmit
  → Promise.allSettled (fail-open: error → degraded:true)
  → worst-wins: block > ask > allow
  → exit code + JSON stdout

PreToolUse fires (Bash/Write/Edit)
  → stdin: { tool_name, tool_input, session_id }
  → HookPipeline.runHook("PreToolUse", input)
      ├─ PrivacyHookModule.scan()       → secrets/PII in command or file content
      ├─ LlmProtectionHookModule.scan() → ToolAbuseScanner + DataLeakageScanner + CanaryScanner
      └─ SupplyChainHookModule.scan()   → package install parsing + risk scoring
  → block → exit 2  (hard block; harness rejects tool call)
  → ask   → exit 0 + decision:ask (harness shows confirmation dialog)
  → allow → exit 0 + continue:true

Stop fires (final response)
  → HookPipeline.runHook("Stop", input)
      ├─ PrivacyHookModule.scan()       → orphaned tok_ in response text
      └─ LlmProtectionHookModule.scan() → DataLeakageScanner + CanaryScanner
  → always exit 0 — advisory only, findings logged
```

---

## Data Flow: Proxy Path

```
POST /v1/messages → localhost:4444
  → ProxyPipeline.runPhase("request", text, sessionId)
      ├─ PrivacyProxyModule.scan()       → tokenize secrets/PII
      └─ LlmProtectionProxyModule.scan() → InjectionScanner + AdversarialScanner
  → block → HTTP 400 { error: "blocked", findings: [...] }
  → allow → tokenizeMessages() → forward to api.anthropic.com
  → response ← api.anthropic.com
  → detokenizeBody() / StreamDetokenizer
  → ProxyPipeline.runPhase("response", ...) [advisory]
  → return to client (real values, not tokens)
```

---

## Harness Adapter Layer

The Claude Code hook contract (JSON stdin/stdout, exit codes) is shared by other harnesses.
This repo ships adapter templates for each:

| Harness | Mechanism | Location | Exit-code contract |
|---------|-----------|----------|--------------------|
| **Claude Code** | `settings.json` hooks | built-in | exit 2 = block, exit 0 = allow/ask |
| **Cursor** | `hooks.json` (cursor/rules.json) | `adapters/cursor/hooks.json` | `"permission": "deny"` OR exit 2 (verify) |
| **OpenCode** | TS plugin, `tool.execute.before` | `adapters/opencode/plugin.ts` | `throw Error(...)` = block |
| **Grok Build** | Claude Code–compatible hooks | `adapters/grok/README.md` | same as Claude Code |
| **Zed / Continue** | MCP gateway proxy (P3) | — | TBD |

---

## ATLAS Technique Coverage

| Technique | Description | Scanner | Events |
|-----------|-------------|---------|--------|
| AML.T0051 | Direct Prompt Injection | InjectionScanner | UserPromptSubmit |
| AML.T0054 | Indirect Injection | InjectionScanner | Stop |
| AML.T0043 | Adversarial Inputs | AdversarialScanner | UserPromptSubmit |
| AML.T0080 | Context Poisoning | CanaryScanner | PreToolUse (block), Stop (warn) |
| AML.T0057 | Data Leakage | DataLeakageScanner | Stop |
| AML.T0024 | Exfiltration via API | DataLeakageScanner | PreToolUse |
| AML.T0085 | Agent Tools Abuse | ToolAbuseScanner | PreToolUse (Bash) |
| AML.T0098 | Credential Harvesting | ToolAbuseScanner | PreToolUse (Bash/Write/Edit) |
| AML.T0010 | Supply Chain Compromise | SupplyChainHookModule | PreToolUse (Bash) |

---

## Storage Layout

```
~/.llm-privacy/
├── .env.sh          # Encryption keys (chmod 600; sourced by proxy.sh and shell RC)
├── .proxy.pid       # Proxy daemon PID (not /tmp — survives /tmp clears, lost on reboot)
├── proxy.log        # Proxy daemon stdout/stderr
├── vault.db         # Proxy vault — SQLite WAL, AES-256-GCM rows
├── vault.enc.json   # Middleware vault — file-based JSON, AES-256-GCM
├── audit.jsonl      # Middleware audit log (tokens only, originals never written)
└── prompts.jsonl    # Proxy prompt log (only when LLM_PRIVACY_LOG_PROMPTS is set)

~/.supplyguard/
└── logs/            # Supply-guard audit JSONL (one file per day)
```

Both vaults share `LLM_PRIVACY_HMAC_KEY` for token generation. A secret tokenizes to the
same `tok_*` value regardless of which layer intercepted it.

---

## Fail-Open Design

Every module call is wrapped in `Promise.allSettled`. A module error produces
`{ decision: "allow", degraded: true }` — the session is never blocked by a broken scanner.

---

## Deferred Work

| Item | Description |
|------|-------------|
| **ISC-65** | Response-phase scan wired in proxy `handleMessages()` across streaming/ollama paths |
| **Canary injection** | Proxy auto-injects `cnry_<token>` into system prompt on outbound |
| **Config-driven module loader** | YAML config to declare which modules to register |
| **MCP gateway adapter** | Universal portability for Zed, Continue, Aider via MCP proxy |
| **OTEL telemetry** | Emit `ScanFinding[]` as OTEL spans; dashboard for block counts |
