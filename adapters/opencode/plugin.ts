// aih-security OpenCode plugin
// Place at: .opencode/plugins/aih-security.ts (or anywhere OpenCode loads plugins from)
//
// Integrates llm_prompt_protection and supply-guard-hook into OpenCode's
// tool.execute.before lifecycle. Modules are imported directly — no shell exec overhead.
//
// Requires: both project repos adjacent to this repo, or adjust import paths below.

import { LlmProtectionHookModule } from "../../llm_prompt_protection/src/adapters/hook-module.js";
import { SupplyChainHookModule } from "../../supply-guard-hook/src/modules/index.js";

const atlasModule = new LlmProtectionHookModule();
const supplyModule = new SupplyChainHookModule();

export default {
  // Fires before any tool executes — can throw to block
  "tool.execute.before": async (input: { tool: string; args: Record<string, unknown> }) => {
    const hookInput = {
      tool_name: input.tool,
      tool_input: input.args,
    };

    const [atlasResult, scResult] = await Promise.allSettled([
      atlasModule.scan(hookInput as never, "PreToolUse"),
      supplyModule.scan(hookInput as never, "PreToolUse"),
    ]);

    for (const result of [atlasResult, scResult]) {
      if (result.status === "fulfilled" && result.value.decision === "block") {
        const finding = result.value.findings[0];
        throw new Error(
          `aih-security blocked: ${finding?.description ?? "security policy"}`
          + (finding?.atlasTechnique ? ` [${finding.atlasTechnique}]` : "")
        );
      }
    }
  },

  // Fires before a prompt is submitted to the LLM — can throw to block
  "prompt.submit.before": async (input: { prompt: string }) => {
    const result = await atlasModule.scan({ prompt: input.prompt } as never, "UserPromptSubmit");
    if (result.decision === "block") {
      const finding = result.findings[0];
      throw new Error(
        `aih-security blocked prompt: ${finding?.description ?? "injection detected"}`
        + (finding?.atlasTechnique ? ` [${finding.atlasTechnique}]` : "")
      );
    }
  },
};
