# Orchestration figures and platform limits

> **Verify against current docs.** Defaults and environment variables change between Claude Code
> releases. Check code.claude.com/docs/en/sub-agents before relying on a number here.

## Token multiplier

Anthropic's engineering write-up on its multi-agent research system reported that an agent uses
roughly 4x the tokens of a chat interaction, and a multi-agent system roughly 15x. Treat these as
order-of-magnitude figures from one system, not a constant.

## Claude Code subagent limits

| Setting | Default at time of writing | Environment variable |
| --- | --- | --- |
| Nesting depth below the main conversation | 3 layers | `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` |
| Concurrent subagents per session | 20 | `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` |

At the depth limit, Claude Code withholds the spawn tool from every subagent except a fork. Over the
concurrency cap, a spawn fails with a "concurrent subagent limit reached" error that tells Claude not
to retry. Some session modes are exempt from the concurrency cap; check the docs.

Plugin-shipped subagents ignore the `hooks`, `mcpServers`, and `permissionMode` frontmatter fields.

## Launch mechanism

Issuing several spawn calls in one assistant message is how parallel spawning works in practice. It
is not a documented contract, so avoid building tooling that depends on the message shape.
