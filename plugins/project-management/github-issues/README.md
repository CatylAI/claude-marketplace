# github-issues

The GitHub adapter for `issue-tracker-core`. The core owns the rules: the pre-work gate, branch and
title conventions, the seven states, dedupe, parenting and the comment trail. This plugin supplies
the GitHub calls that carry them out, through the `gh` CLI or the GitHub MCP tools: issues, status
labels and issue types, milestones, sub-issues, blocked-by links and Projects v2 boards.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install github-issues@catylai
```

`issue-tracker-core` is declared as a dependency, so it comes with it.

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin.

## Skills

| Skill | Use it when |
| --- | --- |
| `issue-lifecycle-github` | Working one GitHub issue: fetching it for the pre-work gate, creating one (dedupe first, parent in the same call), assigning, moving its status, posting the start, handoff and finish comments, closing with the right reason, reopening. |
| `backlog-hygiene-github` | Keeping the backlog truthful: `status:` labels or native issue types, milestones and sub-issue parents, blocked-by links, triage sweeps, conflicting-label sweeps, and a one-call orphan and dead-parent sweep. |
| `projects-v2` | A Projects v2 board carries the status: mapping its Status options to the core states, reading every item, adding issues and setting the Status field. |

All three are skills, so they load in Claude Code and in Cowork. Describe what you want and they
trigger, or call one by name in Claude Code. The plugin ships no agents, hooks or MCP servers.

## Surfaces and access

Each skill uses the first of these that works:

1. **`gh` CLI**, authenticated (`gh auth status`). Usual in Claude Code with a checkout. Newer `gh`
   releases add `--parent`, `--type` and `--blocked-by` to `gh issue create` and `gh issue edit`;
   on an older `gh` the skills fall back to the REST endpoints through `gh api`.
2. **GitHub MCP tools**, from the GitHub MCP server or the claude.ai GitHub connector (`issue_read`,
   `issue_write`, `sub_issue_write`, `add_issue_comment`, `search_issues`, `list_issues`,
   `list_issue_types`). This is the path in Cowork and claude.ai. Label and Projects tools are in
   the server's non-default `labels` and `projects` toolsets; milestones and blocked-by links have
   no MCP tool, so those steps print a `gh` command instead.
3. **Pasted data.** With neither, the skills work from issue text or an export you paste, and print
   each change as a command for you to run. Nothing is recorded until you confirm.

Read-only `gh issue view`, `gh issue list`, `gh label list` and `gh project` list and view commands
are pre-approved inside the skills; every write asks first.

**Projects v2 needs an extra scope.** `gh auth login` does not request `project`. Add it with
`gh auth refresh -s project`, or `-s read:project` for read-only sweeps.

## Tell it about your repository

Add the core's `## Issue tracker` section to the project's `CLAUDE.md`. The GitHub version,
with the recommended status mapping, is in
`skills/issue-lifecycle-github/references/issue-tracker-section.md`. Two choices matter:

- **Ticket pattern.** GitHub issues are bare numbers (`#123`), which the core's default pattern
  never matches. Set the `Ticket pattern` row to `GH-[0-9]+` (branch `fix/GH-123-summary`, title
  `fix(GH-123): …`) or to `[0-9]+`. Either way a pull request body closes the issue only with
  `Fixes #123`; `Fixes GH-123` closes nothing.
- **Status carrier.** `status:` labels, or a Projects v2 Status field. Name one as authoritative.

## Layout

```
github-issues/
├── .claude-plugin/plugin.json
├── README.md
└── skills/
    ├── issue-lifecycle-github/
    │   ├── SKILL.md
    │   └── references/
    │       ├── issue-tracker-section.md   # GitHub values for the CLAUDE.md section; ticket pattern
    │       └── gh-versions.md             # gh releases and GitHub limits (verify against current docs)
    ├── backlog-hygiene-github/
    │   ├── SKILL.md
    │   └── references/
    │       ├── labels.md                  # label setup, rename, delete
    │       └── sub-issues-rest.md         # REST fallback: ids, sub-issues, dependencies, milestones
    └── projects-v2/
        ├── SKILL.md
        └── references/
            └── graphql.md                 # raw GraphQL for boards
```

## Dependencies

- `issue-tracker-core`, whose three skills this plugin carries out on GitHub:
  - `pre-work-gate`: the check before the first edit;
  - `branch-and-title-conventions`: branch names and PR titles from the issue key;
  - `tracker-discipline`: the seven states, dedupe, parenting and the comment trail.

## Not this plugin's job

- **Pull requests.** Opening, reviewing and merging belong to `github-workflow:pr-lifecycle`. This
  plugin adds only the `Fixes #123` rule for the PR body.
- **The rules themselves.** When this adapter and `issue-tracker-core` disagree, the core is right
  and this adapter has a bug.
- **Commit message format.** `dev-standards:commit-standards`.

## License

MIT
