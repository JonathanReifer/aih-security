# aih-security

Security layer for AI coding harnesses (Claude Code, Cursor, OpenCode, Grok Build, and
more). Intercepts prompts, tool calls, and package installs before the AI executes them
and applies MITRE ATLAS–aligned detection, privacy protection, and supply chain defence.

`aih` = AI Harness. This repo is the umbrella: it documents how the four component
projects fit together, ships the unified installer, the test harness, and harness adapter
templates.

---

## Component Projects

| Project | What it does |
|---------|-------------|
| [llm-privacy-proxy](../llm-privacy-proxy/) | Transparent bidirectional tokenization proxy — sits between Claude Code and `api.anthropic.com`, tokenizes secrets/PII in outbound requests and detokenizes responses |
| [llm-privacy-middleware](../llm-privacy-middleware/) | Hook-based privacy guard — intercepts Bash/Write/Edit tool calls, blocks or asks on secrets and PII |
| [llm_prompt_protection](../llm_prompt_protection/) | MITRE ATLAS injection/adversarial detector — covers AML.T0051 through AML.T0098 |
| [supply-guard-hook](../supply-guard-hook/) | Package install interceptor — typosquatting, known-malicious packages, new/unpopular packages, custom registry overrides |

---

## Quick Start

```bash
# Clone this repo, then run the unified installer
git clone ssh://git@gitlab.rsolabs.com:223/ai/aih-security.git ~/Projects/aih-security
bash ~/Projects/aih-security/install.sh
```

The installer clones all four component repos, generates encryption keys, configures
`~/.claude/settings.json`, and runs a smoke test. See [QUICKSTART.md](QUICKSTART.md) for
the full step-by-step guide.

---

## Three Installation Tiers

| Tier | Projects | What you get |
|------|----------|--------------|
| **1 — Proxy** | llm-privacy-proxy | Transparent tokenization on all LLM traffic |
| **2 — Standard** | + llm-privacy-middleware | Hook-level PII/secrets guard on tool calls |
| **3 — Full Stack** | + llm_prompt_protection + supply-guard-hook | ATLAS injection detection + supply chain protection |

```bash
bash install.sh --tier=1   # proxy only
bash install.sh --tier=2   # proxy + middleware
bash install.sh            # interactive; asks which tier (default: 3)
```

---

## Supported Harnesses

| Harness | Support | Adapter |
|---------|---------|---------|
| **Claude Code** | Native hooks | Built into component repos |
| **Cursor** | Native hooks | [adapters/cursor/hooks.json](adapters/cursor/hooks.json) |
| **OpenCode** | TS plugin | [adapters/opencode/plugin.ts](adapters/opencode/plugin.ts) |
| **Grok Build** | Claude Code–compatible | [adapters/grok/README.md](adapters/grok/README.md) |
| Zed / Continue / Aider | MCP gateway (planned P3) | — |

---

## Documentation

- [QUICKSTART.md](QUICKSTART.md) — installation guide (Linux + macOS, all tiers)
- [ARCHITECTURE.md](ARCHITECTURE.md) — system design, data flows, module interfaces
- [docs/testing.md](docs/testing.md) — how to validate the stack on a fresh box
- [docs/harness-adapters.md](docs/harness-adapters.md) — Cursor, OpenCode, Grok Build setup
- [docs/conversation-viewer.md](docs/conversation-viewer.md) — connecting aih-conversation-viewer

---

## Repository Layout

```
aih-security/
├── install.sh            # Unified installer (all tiers, Linux + macOS)
├── QUICKSTART.md         # End-to-end installation guide
├── ARCHITECTURE.md       # System design and module interfaces
├── docs/
│   ├── testing.md        # Smoke tests and manual verification
│   ├── harness-adapters.md   # Multi-harness setup reference
│   └── conversation-viewer.md # Viewer integration guide
├── test/
│   ├── Dockerfile.debian     # Fresh Debian 12 test image
│   ├── run-tests.sh          # Automated smoke test suite
│   └── fixtures/             # Test payloads (injection, benign, supply-chain)
└── adapters/
    ├── cursor/hooks.json     # Drop-in Cursor hooks template
    ├── opencode/plugin.ts    # OpenCode TS plugin
    └── grok/README.md        # Grok Build setup notes
```
