# issue-tracker-core

Tracker-neutral issue discipline: an advisory check before code is written, branch and PR/MR
titles derived from the issue key, a seven-state status vocabulary, dedupe and parenting rules,
and a comment trail that makes the tracker the durable record of the work.

No tracker product, project key, issue-type id or transition id appears in this plugin. The
adapters supply those and map onto the vocabulary defined here.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install issue-tracker-core@catylai
```

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin.

Install an adapter alongside it for the actual tracker calls: `github-issues` or `jira-tracker`.

## Skills

| Skill | Use it when |
| --- | --- |
| `pre-work-gate` | Starting a change. Finds the issue key, fetches the item (or works from a pasted one), checks it exists, is assigned, is workable and parented, and covers the request. Prints a one-line summary with a `PASS`, `FAIL`, `SKIPPED` or `OVERRIDDEN` result. |
| `branch-and-title-conventions` | Naming a branch or titling a PR or MR: `<prefix>/<KEY>-<summary>` and `<type>(<KEY>): <description>`. The forge plugins take their title and branch shape from here. |
| `tracker-discipline` | Moving an item's state, creating or re-parenting an item, or commenting on progress. Owns the seven states, the dedupe rule (`NEW`, `DUPLICATE → <KEY>`, `UNCHECKED`), the parenting rules and the start, handoff and finish comment templates. |

## Tell it about your tracker

Add a `## Issue tracker` section to your project's `CLAUDE.md`: which tracker (or `none`), the
project, the ticket pattern, the intake state, the parent mechanism, who approves top-level
items, and how each of the seven states maps onto your tracker. The template is in
`skills/tracker-discipline/references/tracker-config.md`.

The skills read that section when it exists, ask for the rows they need when it does not, and
offer to write it for you afterwards. Set `Tracker` to `none` in a repo with no tracker and the
pre-work gate stays out of the way.

**Ticket pattern.** Claude takes the issue-key shape from the section's `Ticket pattern` row,
else from `CLAUDE_TICKET_PATTERN` (read with `printenv` in Claude Code; set it in the `env` block
of `.claude/settings.json`), else the default `[A-Z][A-Z0-9]+-[0-9]+`. The `dev-guardrails`
hooks read only the environment variable, so keep the two equal when you use both.

## The four ideas behind it

1. **Work without an issue is untracked work.** It cannot be prioritised, reviewed against
   intent, or explained later. The gate asks before the first edit, when the fix is one question.
2. **The branch carries the key.** When the key is recoverable from the branch name, the commit
   scope, PR title, changelog line and tracker link are derived instead of remembered.
3. **A state is a claim about reality.** `in-review` means a reviewable change exists; `done`
   means it merged. A state that outruns the truth is worse than none, because it is trusted.
4. **The tracker is the durable record; the chat is not.** Anything a future reader needs goes
   in a comment on the item.

## What an adapter supplies

An adapter plugin holds everything this one leaves out, and points here for the rules:

- how to fetch, create, comment on, move and close an item (endpoints, CLI calls or MCP tools);
- the concrete mapping from the tracker's states to the seven core states, including how a
  missing state (often `in-review` or `parked`) is carried;
- the parent mechanism and the live-parent query;
- how finished and abandoned are told apart (a close reason, a resolution);
- the key form its tracker needs, including any closing reference in a PR body.

## Surfaces

All three skills load in Claude Code and in Cowork. The plugin ships no agents, hooks or MCP
servers.

- **Claude Code** reads the branch with `git`, the pattern from `CLAUDE.md` or
  `CLAUDE_TICKET_PATTERN`, and the item through an adapter or a connected tracker tool.
- **Without a checkout or tracker access** (for example in Cowork or claude.ai), the skills ask for the
  `## Issue tracker` rows and a pasted issue, run the same checks on that text, and print any
  state move, parent link or comment for you to apply.

The gate is advice. A skill cannot block a tool call, so the user can always choose to proceed
without an item; the summary line records that choice.

## Related plugins

- `github-issues` and `jira-tracker`: the adapters.
- `dev-standards:commit-standards` owns commit types, the scope charset and release impact;
  `branch-and-title-conventions` builds the key scope on top of it.
- `github-workflow:pr-lifecycle` and `gitlab-workflow:mr-lifecycle` open and merge the PR or MR,
  taking the title and branch shape from `branch-and-title-conventions`.
- `engineering-workflows:handoff` writes a session handoff document; the handoff comment in
  `tracker-discipline` links to it.
- `dev-guardrails` reads `CLAUDE_TICKET_PATTERN` for branch and commit-scope guidance.

## Dependencies

- `dev-standards`, for `commit-standards` (the `<type>` vocabulary and scope charset used in
  titles).

## Layout

```
issue-tracker-core/
├── .claude-plugin/plugin.json
├── README.md
└── skills/
    ├── pre-work-gate/SKILL.md
    ├── branch-and-title-conventions/SKILL.md
    └── tracker-discipline/
        ├── SKILL.md
        └── references/tracker-config.md   # the CLAUDE.md section template
```

## License

MIT
