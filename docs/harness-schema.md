# Harness Activity Schema (harness.jsonl v1)

`~/.llm-privacy/harness.jsonl` is the **tokenized structural mirror** of native
harness transcripts — the hierarchy data (message DAG, sub-agent spawn edges,
tool call/result linkage) that neither the OTEL stream nor the proxy log
carries, with every string leaf redacted through the same pattern engine that
guards the hot path. It is produced by the `HarnessMirror` engine in
`aih-privacy-middleware` (`src/mirror/`), triggered by hooks or the
`src/cli/mirror.ts` CLI, and consumed by `aih-conversation-viewer` as its
correlation spine.

The normative machine-checkable artifact is
[`schema/harness-v1.schema.json`](../schema/harness-v1.schema.json); this
document is commentary. Versioning follows the telemetry-schema rule: **add
fields freely; bump `v` only on breaking change.**

There is **no shared package** — the mirror emits plain JSONL; consumers
duck-type. Future harness adapters (`cursor`, `opencode`) emit the same
records; the schema, not the code, is the contract.

---

## Common envelope

| Field | Type | Notes |
|---|---|---|
| `v` | number | `1` |
| `kind` | string | record type, see below |
| `ts` | ISO8601 string | from the native entry's `timestamp`; pointer records without timestamps inherit the last-seen entry ts |
| `harness` | string | `"claude-code"` today |
| `sessionId` | string | the **parent** session uuid. For sub-agent records this is directory-derived (the session whose `subagents/` dir contains the transcript), not the agent's own native sessionId |
| `agentId` | string? | absent/null ⇒ main session thread; else `agent-<hash>` |
| `project` | string? | basename of the first entry's `cwd` |

## Record kinds

| kind | Payload | Source |
|---|---|---|
| `session_meta` | `cwd`-derived project, `skippedKinds` (native entry types seen but not mirrored — format-drift visibility) | once per sweep that saw new main-transcript lines |
| `node` | `uuid`, `parentUuid` (the message DAG), `role`, `model?`, `redactedText?`, `redactedThinking?`, `truncated?`, `redactionDegraded?`, `usage {in,out,cacheRead}?`, `promptId?`, `promptSource?`, `origin?`, `requestId?`, `stopReason?`, `isSidechain?`, `findings[]?` | native `user`/`assistant` entries |
| `tool_call` | `toolUseId`, `name`, `callerUuid` (containing node), `redactedInput?` (deep-redacted JSON, ≤4 KB), `findings[]?` | `tool_use` content blocks |
| `tool_result` | `toolUseId`, `callerUuid`, `success`, `sizeBytes` (pre-truncation), `redactedPreview?` (≤2 KB), `findings[]?` | `tool_result` content blocks |
| `agent_spawn` | `agentId`, `agentType`, `spawnDepth?` (missing in older meta files), **`parentToolUseId`** — the parent's Task/Agent `tool_use` id, i.e. **the spine edge** of the agent tree — `slug?`, `redactedDescription?` | `subagents/agent-*.meta.json`, emitted on first sweep of that agent |
| `agent_complete` | `agentId`, `endTs`, `nodeCount`, `totalUsage?` | re-emitted per sweep with latest totals; identity key (sessionId, agentId, kind) — consumers keep the last |
| `hook_exec` | `uuid`, `hookEvent?`, `hookCount`, `errorCount`, `durationMs?` | native `system` entries with `hookCount > 0` |
| `compaction` | `uuid` | `user` entries flagged `isCompactSummary` and `system` entries carrying `compactMetadata` |
| `permission_change` | `permissionMode` | native `permission-mode` pointer records, deduped to changes only |

## Findings

`findings[]` entries are `{type, severity, token}` — the pattern type, its
severity, and the **deterministic HMAC token** that replaced the matched span.
Tokens are produced by the same `makeToken` as the hot path, so the same
secret yields the same token across `harness.jsonl`, `audit.jsonl`, and
`prompts.jsonl` — cross-stream joins need no lookup table.

**Never included:** raw prompt text, raw thinking text, raw tool input/output,
original secret values, or any un-redacted string from a transcript. Redaction
is **fail-closed on text, fail-open on structure**: if the pattern engine is
unavailable (`LLM_PRIVACY_HMAC_KEY` unset) or throws, the record is emitted
with `redactedText: null` / `redactedInput: null` and
`redactionDegraded: true` — structure is never lost, text is never leaked.
This inverts the hot path's fail-open, deliberately: the mirror is post-hoc,
so availability never justifies a leak.

## Identity & idempotency

Records are identified by (`sessionId`, `uuid`) for nodes and
(`sessionId`, `toolUseId`, `kind`) for tool records. The mirror may re-emit
records after a crash or state reset (state is written only after a successful
append); consumers MUST dedup on these keys. Re-sweeping the same bytes is
byte-identical (deterministic tokens, transcript-derived timestamps).

## Capture mechanics

- Unit of work is a **session-directory sweep**: the main transcript plus its
  `subagents/` directory. Sub-agent transcripts contain no hook records
  (verified empirically), so the sweep never depends on hooks firing in
  sub-agent context.
- Per-transcript byte-offset state under `~/.llm-privacy/state/mirror/`;
  inode-change or shrink resets (rotation-safe, dedup makes re-mirror free).
- `harness.jsonl` rotates at 512 MB to `harness.jsonl.1`.
- Env overrides: `LLM_PRIVACY_HARNESS_PATH`, `LLM_PRIVACY_MIRROR_STATE_DIR`,
  `CLAUDE_PROJECTS_DIR`.

## Measured baseline (2026-07-20, this machine)

30-day corpus: 6,431 transcripts → 110,194 records, **68 MB**, 6.0 s full
sweep; 6,322 sessions, 109 sub-agents (100% carrying `parentToolUseId`
edges), 1,270 finding annotations, **0** raw secret-shaped strings in output.
