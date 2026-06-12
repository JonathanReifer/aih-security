# Grok Build — aih-security Adapter

Grok Build supports Claude Code–compatible hooks. The existing hook scripts work without
modification. Follow the same steps as Claude Code setup in [QUICKSTART.md](../../QUICKSTART.md)
but place the hooks in Grok Build's configuration file instead of `~/.claude/settings.json`.

## Hook configuration

Grok Build reads hooks from a `grok.json` (or `.grok/settings.json` — verify the current
Grok Build docs for your version). The hook contract is identical to Claude Code:

- Hook scripts receive JSON on stdin
- They write a JSON response to stdout  
- Exit code 2 = hard block; exit code 0 = allow/ask based on stdout content

## Example configuration

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bun $HOME/Projects/llm-privacy-middleware/src/hooks/PrivacyToolGuard.hook.ts"
          },
          {
            "type": "command",
            "command": "bun $HOME/Projects/supply-guard-hook/src/hooks/SupplyGuard.hook.ts"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [{
          "type": "command",
          "command": "bun $HOME/Projects/llm-privacy-middleware/src/hooks/PrivacyPromptGuard.hook.ts"
        }]
      }
    ]
  }
}
```

## Notes

- Verify Grok Build's exact config file name and location in its current documentation.
- Grok Build claims Claude Code–compatible hook JSON schema. If you encounter schema
  differences (e.g. different stdin format), open an issue in this repo.
- The proxy (Tier 1) is configured separately via `ANTHROPIC_BASE_URL` environment variable.
