---
name: mcp-integration
description: "Wiring and building MCP servers for Claude Code and the Agent SDK: choosing the local, project, or user config scope and what belongs in .mcp.json, referencing secrets with variable expansion instead of embedding them, exposing catalogs as MCP resources rather than discovery tool calls, evaluating community servers before writing one, hosting tools in-process, enriching sparse tool descriptions so the model stops falling back to built-ins, and writing the exact mcp__server__tool names that permission rules and hook matchers require. Use when adding, debugging, or reviewing an MCP server, or deciding where its configuration lives. Not for general tool description quality or permission precedence."
license: MIT
---

# MCP integration

MCP is a distribution mechanism, not an excuse to skip tool design. Every rule of good tool
design applies to an MCP tool. This skill covers the wiring, the scoping, and the mistakes unique
to the protocol.

Order of preference throughout: evaluate an existing server before writing one, expose data as a
resource before writing a tool to fetch it, and enrich a description before adding a tool.

## 1. Put each server in the scope that matches its audience

There are three scopes, and a settings file is not one of them — there is no MCP servers key in
`settings.json`.

| Scope | File | Audience |
| --- | --- | --- |
| `local` (default) | The user config, under that project's path | You, this project only |
| `project` | **`.mcp.json`** at the repo root | The whole team, version-controlled |
| `user` | The user config | You, every project |

Team-wide servers belong in `.mcp.json` and get committed. Personal and experimental servers stay
in the user config and never land in the shared file. The CLI's add command with a scope flag
writes the right one for you, and a JSON variant handles entries the flags cannot express.

When the same server name is defined twice, precedence runs local, then project, then user, then
plugin-provided, then connectors, with managed servers ranking above all. The winning source's
**whole entry** is used and fields are never merged across sources — so a partial override is not
a thing. Duplicate the full entry or do not duplicate it.

Settings keys that *do* govern MCP cover enabling all project servers, allowlisting and
denylisting specific servers, restricting to managed servers only, and declaring managed servers.

## 2. Reference secrets; never embed them

Variable expansion (`${VAR}` and `${VAR:-default}`) is supported in `.mcp.json` and in local and
user entries, across the command, args, env, url, and headers fields. Use it, because the config
then commits safely, each developer supplies their own credential, and token rotation needs no
config change.

An unset variable with no default produces a warning in the CLI's list command and keeps the
literal `${VAR}` text — the server still loads and then fails confusingly, so check the list after
onboarding rather than trusting silence.

A hardcoded token in `.mcp.json` is a credential in git history. There is no version of this that
is fine.

## 3. Evaluate community servers first

Maintained servers already exist for most of the systems you are about to wrap. Build custom only
for team-specific workflows no general server models, business logic that must be embedded in the
tool rather than reasoned about by the agent, or proprietary internal systems.

"We want control over the tool descriptions" is not a reason to fork a server. Enrich descriptions
at your own gateway, or wrap the few tools you actually use.

## 4. Expose catalogs as resources, not as discovery tool calls

Claude Code supports MCP **resources**, referenced as `@server:protocol://path`, fetched and
attached automatically, with list and read tools provided for you. Use resources for anything
catalog-shaped — issue lists, document hierarchies, database schemas, config inventories — so the
agent does not spend a tool call and a round trip discovering what exists before it can act.

Also supported: **prompts as slash commands** (`/servername:promptname`, with arguments split on
whitespace) and **elicitation** (form and URL dialogs, with a hook event that can auto-respond).
Sampling is not documented as supported, so do not design a server that depends on calling back
into the client's model.

Two useful per-tool metadata flags exist: one forces a user prompt on every call, and one exempts
a tool from tool-search deferral so it always loads.

## 5. Enrich sparse descriptions, or the model will use a built-in instead

A one-line MCP tool description loses to a built-in search tool. If your server has semantic code
search and the model keeps grepping, the description is the bug. State capabilities, output shape,
and the boundary explicitly — including "use this instead of Grep when…".

This is the general description rule applied at the protocol boundary, and it is the
highest-value edit available on most MCP servers. Three to four sentences minimum, per tool.

## 6. Choose in-process over subprocess when you own the tools

The Agent SDK can host an MCP server in-process, with a create-server helper and a tool helper or
decorator depending on language. Prefer in-process when the tools are part of your application:
no subprocess to manage, no serialization hop, no separate lifecycle, shared process state.

Prefer a subprocess or remote server when the tools must be reusable across clients, need
independent deployment or scaling, are written in another language, or must be isolated from your
process for security.

Transport options on the CLI add command are stdio (the default form, with the command after a
`--` separator), HTTP, and SSE, with a streamable-HTTP alias for HTTP. Other useful per-server
fields cover always-load, timeout, headers, a headers helper, and OAuth.

## 7. Use the exact tool-name form in every rule and matcher

Claude sees MCP tools as `mcp__<server>__<tool>` for a regular server, and
`mcp__plugin_<plugin-name>_<server-name>__<tool-name>` for a plugin-bundled server, with any
character outside `A-Za-z0-9_-` replaced by an underscore.

That full name is what you write in permission rules, a skill's allowed-tools list, a subagent's
tools list, and hook matchers. **A matcher on the bare server key never fires for a plugin
server** — this is the most common "my hook isn't running" cause.

Wildcard placement depends on the rule type, and getting it backwards silently produces a rule
that never matches:

- **Allow** rules accept a glob only *after* a literal, glob-free `mcp__<server>__` prefix. The
  server segment must be spelled out.
- **Deny** and **ask** rules, and the disallowed-tools list, accept broader forms: every MCP tool,
  a whole server, or a server-plus-glob.
- **Hook matchers** go furthest and accept a regex in the server segment too.

So a blanket MCP deny is a useful default for an agent handling untrusted input, while a broad
allow must enumerate servers.

The server itself registers under a `plugin:<plugin-name>:<server-name>` form — that is what an
MCP-tool hook's server field wants, not the `mcp__…` tool name.

## 8. Build the server to the same standards as any tool

Everything from general tool design applies, with three MCP-specific notes:

- The failure flag is `isError: true` (camelCase) on the tool result, where the Claude API's own
  `tool_result` block uses `is_error` (snake_case). Normalize at your boundary if you bridge both.
- Results may carry structured content and resource links alongside the text content; use them
  rather than stuffing JSON into a text block when the client supports it.
- Tool annotations disclose destructive or open-world behavior. Set them honestly — they are what
  a cautious client uses to decide whether to prompt.

## Audit checklist

- [ ] No credential is literal in `.mcp.json` or a committed settings file. Check git history too;
      removing it now does not un-leak it.
- [ ] Team servers are in `.mcp.json` and personal servers are out of it.
- [ ] Nothing expects an MCP servers key in `settings.json`.
- [ ] No server is defined in two scopes with the second expecting field-level inheritance.
- [ ] The CLI's server list shows no unresolved variable warnings.
- [ ] For each custom server, you can name the reason it is not a community server. "Better
      descriptions" does not count.
- [ ] No catalog is fetched by repeated tool calls where a resource would do.
- [ ] No MCP tool description is under three sentences, and each carries a "use this instead of
      the built-in when…" boundary.
- [ ] Transcripts do not show the model using a built-in where an MCP tool was the better choice.
- [ ] Permission rules, allowed-tools, subagent tools, and hook matchers all use the full tool
      name form.
- [ ] No glob appears in the server segment of an **allow** rule.
- [ ] Hooks on MCP tools actually fire — verify one deliberately rather than assuming.
- [ ] No subprocess is being managed where in-process would do.
- [ ] The server sets the error flag on failures, and failures are distinguishable from empty
      results.
- [ ] Destructive tools are annotated as such.

## Patterns that hold up

**Team server in `.mcp.json`, secrets by reference.**

```json
{
  "mcpServers": {
    "issues": {
      "command": "npx",
      "args": ["-y", "@example/mcp-server-issues"],
      "env": { "ISSUES_TOKEN": "${ISSUES_TOKEN}" }
    },
    "code-search": {
      "type": "http",
      "url": "${SEARCH_MCP_URL:-https://search.example.com/mcp}",
      "headers": { "Authorization": "Bearer ${SEARCH_MCP_TOKEN}" },
      "timeout": 30000
    }
  }
}
```

Committed to the repo, so a new hire gets both servers on clone, and no credential is in git. The
default value gives a working URL for most developers while letting anyone point at a staging
instance without editing a tracked file.

**An enriched description that beats the built-in fallback.**

```text
search_code:
  "Semantic and symbol-aware search across the indexed monorepo (all 14 services, updated
   every 5 minutes). Accepts a natural-language query or a symbol name, and returns ranked
   matches with file path, line range, the enclosing symbol, and 3 lines of context.
   Use this instead of Grep whenever the question is conceptual ('where do we validate
   webhook signatures'), crosses service boundaries, or needs call-site context — Grep cannot
   resolve symbols or rank by relevance. Use Grep instead for an exact literal string in a
   file you already have open, or for anything in an unindexed path (build output, vendored
   dependencies). Does NOT search version-control history or closed pull requests."
```

The model now has a decision rule rather than two similar-sounding options. Note it also says when
*not* to use the MCP tool, which is what stops over-triggering in the other direction.

**Catalog as a resource, action as a tool.**

```text
Resources (browsable, attached on reference):
  @issues:board://team-platform     -> current sprint board, all issues with status
  @schema:db://analytics            -> table and column inventory

Tools (do work):
  issues_update_status(issue_key, status, comment)
  issues_create(project, summary, description, type)
```

The agent reads the board as context instead of calling a list tool and then twenty get calls.
Discovery costs zero tool calls, and the tools exist only for actions that change state.

**In-process server for application-owned tools.**

```ts
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

const billing = createSdkMcpServer({
  name: "billing",
  version: "1.0.0",
  tools: [
    tool(
      "get_subscription_context",
      "Compile everything needed to act on one subscription: current plan, seat count, " +
      "billing cycle, last 3 invoices with payment status, and any active credits or " +
      "dunning state. Use at the start of any billing task instead of chaining plan, " +
      "invoice, and credit lookups. Does NOT return payment instrument details.",
      { accountId: z.string().describe("Internal account id, format ACCT-NNNNNN") },
      async ({ accountId }) => ({
        content: [{ type: "text", text: JSON.stringify(await loadContext(accountId)) }],
      }),
    ),
  ],
});
```

The tool runs in the same process as the billing code it wraps — no subprocess, no serialization
hop, no second deployment — and the description is written to the tool-design standard rather than
to the shape of the underlying endpoints.

**Permission rules and hook matchers using the real tool names.**

```json
{
  "permissions": {
    "allow": [
      "mcp__issues__get_*",
      "mcp__issues__list_*",
      "mcp__plugin_directory_people__people_get_reporting_chain"
    ],
    "deny": ["mcp__issues__delete_*", "mcp__*__*_write"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "mcp__plugin_billing_billing__charge_card",
      "hooks": [{ "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/spend-gate.sh" }]
    }]
  }
}
```

Every name is in the form Claude actually emits, including the plugin-bundled shape, so the allow
rules match and the gate fires. Wildcards appear only in the tool segment.

## Failure modes

**Hardcoded credentials, or personal servers in the shared file.** A literal token in a committed
`.mcp.json` is in git history forever, and rotating it now means rewriting history or accepting
the leak. A personal server entry pointing at a binary under one developer's home directory breaks
every teammate's session with a connection failure, and the noise trains people to ignore MCP
warnings.

**Expecting an MCP servers key in `settings.json`, or a partial override.** The first does nothing
at all and the server never appears, which reads as "MCP is broken." The second loses every field
you did not restate, because the winning source's whole entry is used.

**Discovery by tool call instead of a resource.** Listing 40 projects, then 40 issue lists, then
30 individual issues is 71 round trips and a window full of issue bodies before any work happens —
for a catalog static enough to be a resource.

**A one-line description, then blaming the model for grepping.** `search_code: "Searches code"`
gives the model no basis to prefer an unexplained tool over one it knows well, so it grepped,
correctly, given what it was told. Adding a system-prompt instruction competes with the
description instead of replacing it, and removing the built-in breaks the cases it is genuinely
better at.

**Matchers and rules on the bare server name.**

```json
{ "hooks": { "PreToolUse": [{ "matcher": "billing", "hooks": [] }] } }   // never fires
{ "permissions": { "allow": ["mcp__*__get_*"] } }                        // glob in an allow rule's server segment
{ "permissions": { "allow": ["billing__charge_card"] } }                 // missing mcp__ prefix
```

Matchers compare against the emitted tool name. The hook never runs, and because a hook that does
not fire looks exactly like a hook that allowed the call, the gap is silent. Copy the exact name
from a transcript rather than reconstructing it.

**Forking a community server for description quality.** Three months later the fork is forty
commits behind upstream with two auth bugs and no owner. You took on maintenance of someone else's
protocol surface to fix a text problem.

## Porting to other stacks

- **Any MCP client** — the server itself ports unchanged; what varies is which MCP features the
  client supports. Resources, prompts, and elicitation are not universal, so a server that
  *requires* resources will degrade on a tools-only client. Design tools that work standalone and
  resources as the fast path.
- **Non-MCP tool layers** — MCP servers can be bridged, but the tool naming convention and the
  camelCase error flag are Claude-side conventions. Normalize at the bridge and keep your own
  error-category convention on your side of it.
- **Anywhere** — "expose catalogs as data, not as discovery calls" and "descriptions decide
  routing" are not protocol features. They apply to any tool layer.

## Scope note

MCP sampling is not documented as supported by Claude Code — treat a server that depends on it as
unsupported until you verify. The in-process SDK helper names and signatures move between
versions; check them against your installed SDK rather than copying the shape above verbatim. The
same goes for the settings keys, transport aliases, and per-tool metadata flags named here.
