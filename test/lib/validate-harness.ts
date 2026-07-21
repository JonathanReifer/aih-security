#!/usr/bin/env bun
// validate-harness.ts — conformance check for harness.jsonl records against
// schema/harness-v1.schema.json. Zero dependencies: a purpose-built validator
// driven by the schema artifact itself (envelope requireds, kind enum,
// per-kind required properties from the allOf if/then blocks, findings shape).
//
//   bun validate-harness.ts <harness.jsonl> [--sample N]
//
// Exit 0 = every checked line conforms; exit 1 = violation (printed).

import { readFileSync } from "node:fs";
import { join } from "node:path";

const schemaPath = join(import.meta.dir, "..", "..", "schema", "harness-v1.schema.json");
const schema = JSON.parse(readFileSync(schemaPath, "utf8"));

const envelopeRequired: string[] = schema.required;
const kindEnum: string[] = schema.properties.kind.enum;

// kind -> required property names, extracted from allOf[].if/then.
const kindRequired = new Map<string, string[]>();
for (const clause of schema.allOf ?? []) {
  const kind = clause?.if?.properties?.kind?.const;
  if (typeof kind === "string" && Array.isArray(clause?.then?.required)) {
    kindRequired.set(kind, clause.then.required);
  }
}

function validateFindings(findings: unknown, lineNo: number): string | null {
  if (!Array.isArray(findings)) return `line ${lineNo}: findings is not an array`;
  for (const f of findings) {
    if (typeof f !== "object" || f === null) return `line ${lineNo}: finding not an object`;
    const ff = f as Record<string, unknown>;
    for (const req of ["type", "severity", "token"]) {
      if (!(req in ff)) return `line ${lineNo}: finding missing ${req}`;
    }
    if (!["block", "warn", "info"].includes(String(ff.severity)))
      return `line ${lineNo}: finding severity invalid: ${ff.severity}`;
    if (!String(ff.token).startsWith("tok_"))
      return `line ${lineNo}: finding token lacks tok_ prefix`;
    if ("original" in ff) return `line ${lineNo}: finding carries original text — FORBIDDEN`;
  }
  return null;
}

function validateLine(line: string, lineNo: number): string | null {
  let rec: Record<string, unknown>;
  try {
    rec = JSON.parse(line) as Record<string, unknown>;
  } catch {
    return `line ${lineNo}: not valid JSON`;
  }
  for (const req of envelopeRequired) {
    if (!(req in rec)) return `line ${lineNo}: missing envelope field ${req}`;
  }
  if (rec.v !== 1) return `line ${lineNo}: v is ${rec.v}, expected 1`;
  const kind = String(rec.kind);
  if (!kindEnum.includes(kind)) return `line ${lineNo}: unknown kind ${kind}`;
  for (const req of kindRequired.get(kind) ?? []) {
    if (!(req in rec)) return `line ${lineNo}: kind=${kind} missing required ${req}`;
  }
  if ("findings" in rec) {
    const err = validateFindings(rec.findings, lineNo);
    if (err) return err;
  }
  return null;
}

const args = process.argv.slice(2);
const path = args[0];
if (!path) {
  process.stderr.write("usage: validate-harness.ts <harness.jsonl> [--sample N]\n");
  process.exit(2);
}
const sampleIdx = args.indexOf("--sample");
const sample = sampleIdx !== -1 ? Number(args[sampleIdx + 1]) : Infinity;

const lines = readFileSync(path, "utf8").split("\n").filter((l) => l.trim());
let checked = 0;
const kindCounts: Record<string, number> = {};
for (let i = 0; i < lines.length && checked < sample; i++) {
  const err = validateLine(lines[i], i + 1);
  if (err) {
    process.stderr.write(`CONFORMANCE FAIL: ${err}\n`);
    process.exit(1);
  }
  const k = String((JSON.parse(lines[i]) as { kind: string }).kind);
  kindCounts[k] = (kindCounts[k] ?? 0) + 1;
  checked++;
}
process.stdout.write(`conformant: ${checked} records ${JSON.stringify(kindCounts)}\n`);
