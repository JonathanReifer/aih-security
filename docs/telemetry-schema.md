# Telemetry Schema

Every producer in the stack (`aih-privacy-proxy`, `aih-privacy-middleware`, `supply-guard-hook`,
`supply-guard-proxy`) emits telemetry that conforms to this document. There is **no shared
package** — each producer implements its own small, local bootstrap. This matches the stack's
existing pattern of deliberate duck-typing across module boundaries (see the comment in
`supply-guard-hook/src/modules/SupplyChainModule.ts`: *"Defined locally on purpose: NO imports
from the middleware"*). A shared dependency here would recreate exactly the coupling that
pattern exists to avoid.

---

## Fields

| Field | Type | Notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump only on breaking changes; add fields freely without bumping |
| `ts` | ISO8601 string | event time |
| `session_id` | string | shared across proxy + middleware today via the deterministic HMAC key |
| `project` | string | derived from `cwd`, or `"unknown"` if unavailable — see below |
| `harness` | string | `"claude-code"` today; forward-compatible with the `adapters/{cursor,opencode,grok}` harnesses |
| `component` | string | `"aih-privacy-proxy" \| "aih-privacy-middleware" \| "supply-guard-hook" \| "supply-guard-proxy"` |
| `scanner_id` | string | reuses the existing `scannerId` value verbatim (e.g. `"injection.direct"`) |
| `event_type` | string | `"prompt_scan" \| "tool_scan" \| "response_scan" \| "package_install"` |
| `decision` | string | normalized to `allow \| ask \| block \| approve` at emission time — component-native vocabularies (e.g. supply-guard-proxy's `Decision.action`) get mapped here, not upstream |
| `severity` | string | `block \| warn \| info` |
| `atlas_technique` | string? | existing MITRE ATLAS field, passed through unchanged |
| `owasp_category` | string? | new OWASP LLM Top 10 field, sibling to `atlas_technique` — never a replacement |
| `degraded` | bool? | existing concept from `ModuleScanResult`/`RiskResult` |
| `duration_ms` | number? | where available |

**Never included:** raw prompt text, raw command text, raw tool input/output, or original
secret values. Only already-tokenized/redacted fields (`LogFinding`, `ScanFinding`,
`AuditEvent`) ever reach a telemetry emitter — this mirrors the existing "originals never
logged" invariant in `audit.jsonl`.

---

## Transport: OTLP over HTTP, not gRPC — and no SDK dependency

All producers speak the OTLP/HTTP **JSON** wire format directly (a single `POST .../v1/logs`
per event) rather than pulling in `@opentelemetry/sdk-logs` / `opentelemetry-sdk`. This was a
deliberate correction made during implementation, for two reasons:

1. **Zero-dependency convention.** `aih-privacy-proxy`, `aih-privacy-middleware`, and
   `supply-guard-hook` currently have no runtime dependencies at all. The full JS SDK (plus its
   resource/context/proto transitive deps) is a lot of surface area for "occasionally POST one
   JSON log record."
2. **The SDK's batch processor doesn't fit short-lived CLI hooks.** `allow()`/`ask()`/`block()`
   in both `aih-privacy-middleware/src/hooks/lib/hook-helpers.ts` and
   `supply-guard-hook/src/hooks/SupplyGuard.hook.ts` call `process.exit()` synchronously right
   after printing the hook's decision — confirmed by direct read. An SDK batch processor (or any
   unawaited fire-and-forget promise) gets killed before its network write completes; nothing
   would ever actually be delivered. A hand-rolled `fetch()` call sidesteps this entirely and
   needs no SDK machinery to control.

Port 4318 (HTTP), not 4317 (gRPC), for the same reason as before — Bun's gRPC support is
unreliable. A new env var, `OTEL_EXPORTER_OTLP_ENDPOINT_HTTP`, is the primary config point. If
unset, it's derived by swapping the trailing `:4317` for `:4318` in
`OTEL_EXPORTER_OTLP_ENDPOINT`. Set neither, and a producer's telemetry emitter is a no-op — same
opt-in convention as `LLM_PRIVACY_LOG_PROMPTS`.

`supply-guard-proxy` (Python) uses the stdlib `urllib.request` for the same POST, for the same
reasons — no new dependency, and consistency across all 4 producers.

### Delivery strategy differs by process lifetime

- **Long-running servers** (`aih-privacy-proxy`, `supply-guard-proxy`): true fire-and-forget.
  The emit call is started and not awaited in the request's hot path; the process stays alive
  regardless, so the network write completes in the background on its own schedule.
- **Short-lived CLI hooks** (`aih-privacy-middleware`, `supply-guard-hook`): **bounded wait
  before exit.** The hook already `await`s its scan/evaluate pipeline before reaching
  `allow()`/`ask()`/`block()`, so the telemetry emit is awaited in that same chain, raced against
  a short timeout (50ms) via a `flushTelemetry()` helper — `await Promise.race([emit(...),
  sleep(50ms)])`. Worst case this adds ~50ms to one hook invocation; an unreachable/slow
  collector never blocks longer than that, and the emit's own internal try/catch means a network
  error never surfaces as a hook failure.

## Signal type: logs, not spans

Emit `LogRecord`s, not spans/traces. Claude Code's own native telemetry already reaches Loki
and the conversation-viewer as log lines (`body: "claude_code.api_request"`, etc.) — the
collector's `pipelines.logs` (not `pipelines.traces`) is what the viewer actually parses today.
New producer telemetry follows the same shape: `body = "aih.finding"` or
`"aih.package_install"`, with the fields above as structured log attributes.

## `service.name` — set by the producer, not overwritten by the collector

`aih-observability/config/otel/config.yaml`'s `resource` processor currently does
`action: upsert` on `service.name`, which unconditionally overwrites whatever a producer sets
with a hardcoded `aih-proxy`. This must change to `action: insert` (set only if absent) before
any new producer emits its own `service.name` via `OTEL_SERVICE_NAME`
(`aih-privacy-proxy`, `aih-privacy-middleware`, `supply-guard-hook`, `supply-guard-proxy`).

Check the current behavior against devops1's collector (if reachable) before deploying this
fix anywhere — the `upsert` may already be silently affecting Claude Code's own telemetry today,
independent of anything in this project.

## Loki `job` label

New producer telemetry uses a distinct Loki job label, `aih-security`, set via a
`service.namespace: aih-security` resource attribute. Each producer's own emitter sets this
itself, in its own `resourceLogs[].resource.attributes` (see `src/telemetry/otel.ts`/`.py` in
each repo) — the collector's `resource` processor is **not** used to inject this globally.
Doing that would apply to every pipeline the collector touches, including Claude Code's own
native telemetry, which has no `service.namespace` of its own today; an `insert` there would
silently relabel it, and that effect can't be verified without touching devops1's live
collector, which is out of bounds (see standing constraint above). Scoping the attribute to
each new producer's own payload keeps existing `{job="claude-code"}` viewer/Grafana queries
provably undisturbed. The Loki exporter's label set is extended to include `project`,
`component`, `decision`, `severity`, `atlas_technique`, `owasp_category` — all
bounded-cardinality fields safe as labels, and populated only when a log record actually
carries them, so pre-existing telemetry without these attributes is unaffected. `scanner_id`
and any free-text
description stay in the log body/attributes, not labels, to avoid cardinality blowup.

## Project derivation

`project` is derived at the hook layer from `cwd` (added to `HookInput` in
`aih-privacy-middleware` and the equivalent type in `supply-guard-hook`), defaulting to
`basename(cwd)`, overridable via a `.aih-project` marker file or an `AIH_PROJECT` env var
(highest precedence). The proxy has no direct `cwd` visibility, so `project` reaches it via a
small `~/.llm-privacy/session-projects.jsonl` mapping file (`session_id` → `project`), written
by the first middleware hook invocation per session and read by the proxy's logger — this
reuses the existing pattern of a JSONL file as lightweight IPC, rather than introducing new
infrastructure. `supply-guard-proxy` has no `session_id` concept at all today; its telemetry
tags `project: "unknown"` until that gap is closed separately.

## Fail-open is absolute

Telemetry emission must never affect a security decision, and must never meaningfully add hook
latency. Emission is fire-and-forget: `emit()` enqueues onto the OTEL SDK's batch log processor
and returns immediately — never `await` a network flush inside a hook or proxy request path.
This is the same discipline `PromptLogger`, `logAuditEvent`, and `logDecision` already apply to
their own file I/O (wrapped in try/catch, failures swallowed, "must never break hook
execution").

`supply-guard-hook`'s metadata check already runs as a separate `PreToolUse/Bash` hook entry
because it can take up to 3000ms against `PrivacyToolGuard`'s 500ms budget. Telemetry emission
must be measured (not assumed) to add negligible latency on top of both. If the in-process SDK
ever measurably adds latency, fall back to writing an outbox JSONL file and flushing it via a
decoupled process instead of an in-process OTEL SDK call.
