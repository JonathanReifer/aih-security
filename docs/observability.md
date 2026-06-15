# Observability

The `aih-observability` stack provides the OTEL collector, Loki, Prometheus, and Grafana
infrastructure that the conversation viewer uses for its "Unified" timeline view. It is
optional — the security tiers work without it — but once running it adds:

- Full hook execution timelines per session
- Per-tool decision history (auto / approved / blocked / rejected)
- Per-session API cost tracking
- Security finding history (when OTEL emission is added to the proxy — planned)

---

## Local Mode

Run everything on the same machine as Claude Code.

```bash
# Clone (or let install.sh do this):
git clone https://github.com/JonathanReifer/aih-observability.git ~/Projects/aih-observability

cd ~/Projects/aih-observability
docker compose up -d
```

Add to `~/.llm-privacy/.env.sh`:
```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export LOKI_URL=http://localhost:3100
```

Then reload and start the viewer:
```bash
source ~/.llm-privacy/.env.sh
bun ~/Projects/aih-conversation-viewer/src/server.ts
# → http://localhost:4446 — select "Unified" source
```

---

## Remote Mode

Run the stack on a dedicated server; multiple client machines point at it.

**On the server:**
```bash
cd ~/Projects/aih-observability
docker compose up -d
```

Firewall or VPN-restrict ports 4317, 4318, and 3100 — these services have no built-in
authentication. Port 3001 (Grafana) has password auth.

**On each client machine** — add to `~/.llm-privacy/.env.sh`:
```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<server-ip>:4317
export LOKI_URL=http://<server-ip>:3100
```

Start the viewer on any client:
```bash
LOKI_URL=http://<server-ip>:3100 bun ~/Projects/aih-conversation-viewer/src/server.ts
```

---

## Reconfiguring via install.sh

The installer prompts for observability mode at Step 6.5. To change your configuration
after initial install, re-run the installer (it will not overwrite existing keys):

```bash
bash ~/Projects/aih-security/install.sh --skip-clone
```

Or edit `~/.llm-privacy/.env.sh` directly:
```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<endpoint>:4317
export LOKI_URL=http://<loki>:3100
```

---

## Port Reference

| Service | Port | Protocol | Auth |
|---------|------|----------|------|
| OTEL Collector (gRPC) | 4317 | gRPC | None |
| OTEL Collector (HTTP) | 4318 | HTTP | None |
| OTEL Health Check | 13133 | HTTP | None |
| Loki | 3100 | HTTP | None |
| Prometheus | 9090 | HTTP | None |
| Grafana | 3001 | HTTP | Password |

---

## Grafana

Grafana is at `http://<host>:3001`. Default credentials: `admin` / `aih` (or the value of
`GRAFANA_ADMIN_PASSWORD` in `aih-observability/.env`).

The pre-built `llm-requests` dashboard shows request volume by model, session count, and
PII match rates from the proxy.

---

## What Data Flows Now vs Later

| Source | Data | Status |
|--------|------|--------|
| PAI OTEL hook | Hook execution timelines, tool decisions, session cost | Available now |
| aih-privacy-proxy | Security scan findings as OTEL spans | Planned (Phase 4) |
| aih-privacy-middleware | Block/ask decisions as OTEL spans | Planned (Phase 4) |

The collection infrastructure is ready. OTEL emission from the proxy and middleware is
listed as deferred work in `ARCHITECTURE.md`.
