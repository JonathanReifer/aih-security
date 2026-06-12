# Harness Adapters Reference

How to connect aih-security to AI coding harnesses other than Claude Code.

---

## Adapter Availability

| Harness | Status | Location | Notes |
|---------|--------|----------|-------|
| **Claude Code** | Native | Built into component repos | Reference implementation |
| **Cursor** | Ready | `adapters/cursor/hooks.json` | Near-1:1 hook parity with Claude Code |
| **OpenCode** | Ready | `adapters/opencode/plugin.ts` | TS plugin, direct module import |
| **Grok Build** | Ready | `adapters/grok/README.md` | Claude Code–compatible, config only |
| Zed | Planned (P3) | — | MCP gateway/proxy approach required |
| Continue.dev | Planned (P3) | — | MCP gateway/proxy approach required |
| Aider | Not supported | — | No hook interception surface |

---

## Cursor

Cursor uses a `hooks.json` file with a format that maps almost 1:1 to Claude Code's
`settings.json` hooks.

**Key differences from Claude Code:**
- `beforeShellExecution` instead of `PreToolUse/Bash`
- `beforeMCPExecution` for MCP tool calls (supports `failClosed: true`)
- Block protocol: Cursor may use `"permission": "deny"` JSON rather than exit code 2 —
  verify with your Cursor version and update the hook exit path accordingly.

### Setup

1. Locate or create your Cursor hooks config (typically `.cursor/hooks.json` in your project
   root, or the global Cursor settings).
2. Copy the template:

```bash
cp ~/Projects/aih-security/adapters/cursor/hooks.json .cursor/hooks.json
```

3. Edit paths if your projects are not in `~/Projects/`.

4. Load the env file in the hook command (Cursor inherits system env but may not source RC):

```json
{
  "hooks": {
    "beforeShellExecution": [
      {
        "command": "bash -c 'source $HOME/.llm-privacy/.env.sh; bun $HOME/Projects/supply-guard-hook/src/hooks/SupplyGuard.hook.ts'",
        "failClosed": true
      }
    ]
  }
}
```

### Verify

Open Cursor, ask it to run `pip install coloama`. It should be blocked by
`beforeShellExecution` before execution.

---

## OpenCode

OpenCode uses a TypeScript/Bun plugin system. Plugins can throw to block tool execution —
no exit codes involved.

### Setup

1. Copy the plugin template:

```bash
mkdir -p .opencode/plugins
cp ~/Projects/aih-security/adapters/opencode/plugin.ts .opencode/plugins/aih-security.ts
```

2. Adjust import paths if needed (the plugin imports from adjacent repos):

```typescript
// Default paths (repos in ~/Projects):
import { LlmProtectionHookModule } from "../../llm_prompt_protection/src/adapters/hook-module.js";
import { SupplyChainHookModule } from "../../supply-guard-hook/src/modules/index.js";
```

3. Register the plugin in your OpenCode config (`.opencode/config.json` or equivalent):

```json
{
  "plugins": ["./plugins/aih-security.ts"]
}
```

### How it works

The plugin hooks `tool.execute.before` and `prompt.submit.before`. Module instances are
created once at startup and reused — no shell exec per call. When a module returns
`decision: "block"`, the plugin throws an `Error` with the finding description, which
OpenCode surfaces to the user.

### Verify

Ask OpenCode to run `pip install coloama`. The `tool.execute.before` hook should throw and
OpenCode should show the error: `aih-security blocked: Known malicious package [AML.T0010]`.

---

## Grok Build

See [adapters/grok/README.md](../adapters/grok/README.md). Grok Build uses the same hook
JSON contract as Claude Code — no new code required, just config file placement.

---

## Zed / Continue.dev (Planned P3)

These harnesses have no native hook surface that can intercept and block prompts or tool
calls. The planned approach is an **MCP gateway proxy**: a local MCP server that wraps the
security scanners, exposable to any harness that supports MCP.

The gateway pattern:
1. Proxy harness's MCP connections through a local MCP server
2. The MCP server runs the scanner pipeline on every tool call
3. Returns an `error` result (which MCP-capable harnesses surface to the user) on block decisions

This is P3 scope — not yet implemented. The component projects are designed with it in mind.

---

## Proxy (Tier 1) in Non-Claude-Code Harnesses

The tokenization proxy (port 4444) works with any harness that supports a configurable
upstream API URL. Set the environment variable before starting the harness:

```bash
export ANTHROPIC_BASE_URL="http://localhost:4444"
# Then start your harness (Cursor, OpenCode, Grok Build, etc.)
```

Or add it to your harness's env config if it supports one.

Make sure the proxy is running first:
```bash
~/Projects/llm-privacy-proxy/proxy.sh start
```
