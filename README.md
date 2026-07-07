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
| [aih-privacy-proxy](https://github.com/JonathanReifer/aih-privacy-proxy) | Transparent bidirectional tokenization proxy — sits between Claude Code and `api.anthropic.com`, tokenizes secrets/PII in outbound requests and detokenizes responses |
| [aih-privacy-middleware](https://github.com/JonathanReifer/aih-privacy-middleware) | Hook-based privacy guard — intercepts Bash/Write/Edit tool calls, blocks or asks on secrets and PII |
| [aih-prompt-protection](https://github.com/JonathanReifer/aih-prompt-protection) | MITRE ATLAS injection/adversarial detector — covers AML.T0051 through AML.T0098 |
| [supply-guard-hook](https://github.com/JonathanReifer/supply-guard-hook) | Package install interceptor — typosquatting, known-malicious packages, new/unpopular packages, custom registry overrides |
| [supply-guard-proxy](https://github.com/JonathanReifer/supply-guard-proxy) | Network-level companion to supply-guard-hook — local HTTP proxy that enforces the same package-age/download-count/registry policy for pip/npm/cargo outside the harness hook lifecycle too |
| [aih-conversation-viewer](https://github.com/JonathanReifer/aih-conversation-viewer) | Session viewer — conversation bubbles, tool decisions, PII detection, and ATLAS security findings per session |
| [aih-observability](https://github.com/JonathanReifer/aih-observability) | Optional OTEL + Loki + Prometheus + Grafana stack — hook telemetry, session cost, tool decision timelines |

---

## Quick Start

```bash
# Clone this repo, then run the unified installer
git clone https://github.com/JonathanReifer/aih-security.git ~/Projects/aih-security
bash ~/Projects/aih-security/install.sh
```

The installer clones all four component repos, generates encryption keys, configures
`~/.claude/settings.json`, and runs a smoke test. It also registers a `SessionStart` hook
that prints a one-line health summary (`bin/aih-status --brief`) at the top of every
session. See [QUICKSTART.md](QUICKSTART.md) for the full step-by-step guide.

**Check status any time:**

```bash
bin/aih-status            # 7-day table: proxy health, block/ask/degraded, supply-chain blocks
bin/aih-status --brief    # one line (what the SessionStart hook prints)
```

**Disable or remove:**

```bash
bash install.sh --disable            # stop proxy, remove hooks + ANTHROPIC_BASE_URL (keeps repos/keys)
bash install.sh --uninstall          # also remove the shell RC source line
bash install.sh --uninstall --purge  # also delete cloned repos and ~/.llm-privacy (after confirmation)
```

---

## Three Installation Tiers

| Tier | Projects | What you get |
|------|----------|--------------|
| **1 — Proxy** | aih-privacy-proxy | Transparent tokenization on all LLM traffic |
| **2 — Standard** | + aih-privacy-middleware | Hook-level PII/secrets guard on tool calls |
| **3 — Full Stack** | + aih-prompt-protection + supply-guard-hook | ATLAS injection detection + supply chain protection |

```bash
bash install.sh --tier=1   # proxy only
bash install.sh --tier=2   # proxy + middleware
bash install.sh            # interactive; asks which tier (default: 3)
```

---

## Optional: Observability Stack

`aih-observability` provides the OTEL collector, Loki, Prometheus, and Grafana stack that
powers the "Unified" timeline view in the conversation viewer. It is not required for any
security tier but unlocks full hook-execution timelines, per-tool decision history, and
per-session API cost tracking.

Supports two deployment modes:

- **Local** — stack runs on the same machine as Claude Code (`docker compose up -d`)
- **Remote** — stack runs on a dedicated server; multiple client machines point at it via
  `OTEL_EXPORTER_OTLP_ENDPOINT` and `LOKI_URL` env vars

`install.sh` prompts for local/remote/skip at Step 6.5 and configures `~/.llm-privacy/.env.sh`
automatically. For manual setup, see [docs/observability.md](docs/observability.md).

Ports: **OTEL** 4317/4318 · **Loki** 3100 · **Prometheus** 9090 · **Grafana** 3001

---

## Optional: Supply-Guard Proxy

`supply-guard-proxy` is a standalone companion to `supply-guard-hook`. Where the hook only
sees package installs that go through a Claude-Code-instrumented `Bash` tool call,
the proxy enforces the same supply-chain policy (package age, download counts, registry
overrides) at the network layer — so it also covers installs from CI pipelines, a plain
terminal, or any tool outside the hook lifecycle.

It's a local HTTP proxy that `pip`, `npm`, `cargo`, and `brew` are redirected to via their
native config files (`pip.conf`, `.npmrc`, `cargo/config.toml`) — no CA cert, no HTTPS
interception. Because that redirect is a system-wide config change (not scoped to Claude
Code), `install.sh` clones it at Tier 3 but does not auto-run its setup:

```bash
cd ~/Projects/supply-guard-proxy
pip install -r requirements.txt && ./scripts/setup.sh
./scripts/proxy.sh start
```

See the [supply-guard-proxy README](https://github.com/JonathanReifer/supply-guard-proxy) for
policy configuration (`rules.yaml`) and manual verification steps.

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
- [docs/observability.md](docs/observability.md) — local and remote observability setup
- [docs/bypass.md](docs/bypass.md) — how to bypass or temporarily disable the proxy

---

## Repository Layout

```
aih-security/
├── install.sh            # Unified installer (all tiers, --disable / --uninstall)
├── bin/
│   └── aih-status        # Default-on health/decision status (SessionStart hook)
├── QUICKSTART.md         # End-to-end installation guide
├── ARCHITECTURE.md       # System design and module interfaces
├── docs/
│   ├── testing.md        # Smoke tests and manual verification
│   ├── harness-adapters.md   # Multi-harness setup reference
│   ├── conversation-viewer.md # Viewer integration guide
│   └── bypass.md             # Proxy bypass and temporary disable guide
├── test/
│   ├── Dockerfile.debian     # Fresh Debian 12 test image
│   ├── run-tests.sh          # Automated smoke test suite
│   └── fixtures/             # Test payloads (injection, benign, supply-chain)
└── adapters/
    ├── cursor/hooks.json     # Drop-in Cursor hooks template
    ├── opencode/plugin.ts    # OpenCode TS plugin
    └── grok/README.md        # Grok Build setup notes
```
