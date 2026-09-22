# github-issues

The GitHub adapter for `issue-tracker-core`. The core plugin states the discipline
in vendor-neutral terms — require a real, scoped, assigned issue before any code is
written; keep the issue key recoverable from the branch; use a status vocabulary
whose states are checkable claims; keep every item under a live parent; treat the
issue as the durable record. This plugin supplies the concrete `gh` calls that carry
those procedures out against GitHub Issues, labels, milestones, sub-issues and
Projects v2.

Nothing here restates the core's reasoning. Read the core for what a call is for;
read this for the call.

## When to use it

- The repository's tracker is GitHub Issues, and you need the actual command rather
  than the rule.
- You are satisfying the pre-work gate: finding or creating a scoped, assigned issue
  before the first edit.
- You are triaging a GitHub backlog and need a label taxonomy that can carry a
  lifecycle vocabulary GitHub does not natively have.
- You are attaching a child issue to a parent, or sweeping for orphans.
- You are reading or updating a Projects v2 board from the command line.

## When not to use it

- **Pull request lifecycle.** Opening, reviewing, merging, and the checks that gate a
  merge belong to `github-workflow`. This plugin stops at the issue and at the
  reference that links a pull request back to it.
- **Judgement about whether the work is well scoped or a state is honest.** That is
  `issue-tracker-core`, and it is deliberately not duplicated here.
- **A tracker that is not GitHub.** Load the adapter for that tracker instead. The
  core is shared; the adapter is not.
- **Commit message format.** `dev-standards` owns Conventional Commits.

## Prerequisites

An authenticated GitHub CLI. Check before running anything:

```
gh auth status
```

It must report an account and a token for the host the repository lives on. Every
procedure in this plugin shells out to `gh`; there is no fallback that infers issue
state from the working tree, and guessing is worse than stopping.

**Projects v2 needs an extra scope.** A default `gh auth login` requests `repo`,
`read:org`, `gist` and `workflow` — not `project`. Without it, every Projects v2
query fails with a scope error. Add it:

```
gh auth refresh -s project
```

Use `-s read:project` instead when the work is read-only, such as a reporting sweep.

Milestone, label and sub-issue procedures need only the standard `repo` scope.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install github-issues@catylai
```

Install `issue-tracker-core` alongside it — this plugin is an adapter and assumes
the core's rules are loaded.

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for
your claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `issue-lifecycle-github` | Skill | Satisfy the pre-work gate with `gh issue`, read an issue's full state, derive the branch and pull request title, post the start/handoff/finish comments, close and reopen with an honest reason | both |
| `triage-and-labels` | Skill | Carry the core's status vocabulary on a tracker that has only `open` and `closed`; namespaced label taxonomy, idempotent label creation, triage sweeps, conflicting-status detection and repair | both |
| `milestones-and-sub-issues` | Skill | Parent-child hygiene on GitHub: milestones as the iteration container, the sub-issues REST endpoints and the id they key off, task lists as the weaker alternative, live orphan sweeps and parent audits | both |
| `projects-v2` | Skill | Read and write a project board — GraphQL only: node id resolution, field and option ids, the `after`/`pageInfo` paging idiom, `addProjectV2ItemById`, `updateProjectV2ItemFieldValue`, scopes and the points budget | both |

Everything here is a Skill, so all four load on both surfaces. You can call one by
name in Claude Code, or just describe what you want on either surface and let it
trigger itself.

**Every procedure in this plugin drives the `gh` CLI.** The skills are readable on
both surfaces, but only executable where a shell and an authenticated `gh` exist —
that is Claude Code. In Cowork there is no checkout and no shell, so treat these
skills as reference there: they will tell you exactly which command to run, and you
will run it yourself.

## Layout

```
github-issues/
├── .claude-plugin/plugin.json                  # manifest (name, version, description, dependencies)
├── README.md
├── SKILL.md                                    # plugin root: the adapter contract and the ticket-pattern seam
└── skills/
    ├── issue-lifecycle-github/SKILL.md
    ├── triage-and-labels/SKILL.md
    ├── milestones-and-sub-issues/SKILL.md
    └── projects-v2/SKILL.md
```

## The `issue-tracker-core` seam

`issue-tracker-core` names no vendor on purpose. It has no endpoints, no issue-type
identifiers, no transition ids, no project key — it says that an item must exist and
be assigned before work starts, that a state is a claim someone will act on without
verifying, that a candidate-parent list is a query and never a cached table, and that
the issue rather than the chat is the durable record. Those statements survive a
tracker migration, which is exactly why they are separated out. This plugin is the
other half: it supplies the endpoint names, the payload shapes and GitHub's own
vocabulary, and it maps the core's seven-state lifecycle onto a product that has two
states plus a close reason. Where the two appear to conflict, the core wins and this
adapter has a bug — the adapter's job is to make the core's rules executable, never
to relax them because GitHub makes one awkward. The mapping is stated honestly rather
than smoothed over: GitHub natively represents done and declined and nothing else, so
backlog, ready, in progress, in review and parked are carried by advisory labels or a
Projects v2 field, and both skills that do so say plainly what is and is not enforced.

## Configuration: the ticket-pattern note

`issue-tracker-core` shares one variable with the sibling `dev-guardrails` plugin so
the two agree on what an issue key looks like:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_TICKET_PATTERN` | `[A-Z][A-Z0-9]+-[0-9]+` | Regex for the issue-key shape, used to recover a key from a branch name, message or title. |

GitHub issues have no alphabetic prefix — they are bare numbers, written `#123`. The
default pattern therefore matches nothing in a GitHub repository, and the pre-work
gate silently finds no key on a correctly named branch. Pick one resolution per
repository and write it down:

- **Preferred — a synthetic prefix.** Agree that `GH-123` means issue `#123` and set
  `CLAUDE_TICKET_PATTERN=GH-[0-9]+`. Branches become
  `feature/GH-123-short-summary`, commit scopes become `feat(GH-123): ...`, and the
  number is recovered by stripping `GH-`. A key stays distinguishable from every
  other number in a branch name.
- **Alternative — bare numeric.** Set `CLAUDE_TICKET_PATTERN=[0-9]+`. Simpler, and it
  matches every number anywhere, including the `2` in `refactor/v2-parser`. Only
  workable in a repository whose branch convention puts the issue number first and
  nothing else numeric in the name.

Either way, closing keywords in a pull request body must use GitHub's own reference
form. `Fixes #123` closes the issue; `Fixes GH-123` does not, because GitHub does not
resolve a synthetic prefix. Keep `GH-123` for branch names, commit scopes and pull
request titles, and `#123` for bodies and comments where GitHub is doing the linking.

## Dependencies

- `issue-tracker-core` — supplies the pre-work gate, the branch and title conventions,
  the status vocabulary, the parent-child rules and the issue-as-record rule that
  every skill here carries out.

## License

MIT
