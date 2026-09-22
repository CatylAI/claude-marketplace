---
name: github-issues
description: "The GitHub adapter for issue-tracker-core — the concrete gh commands that carry out the pre-work gate, the comment trail, status representation, parent-child links and board updates against GitHub Issues, labels, milestones, sub-issues and Projects v2. Use when the repository's tracker is GitHub and you need the actual call rather than the rule: finding or creating a scoped issue, labelling a triage decision, attaching a child to a parent, or moving a card on a project board."
license: MIT
user-invocable: false
---

# GitHub Issues

`issue-tracker-core` states the discipline and deliberately names no vendor: no
endpoint, no issue-type identifier, no project key. This plugin is the layer that
supplies those for GitHub, and nothing else. Read the core for what a call is
*for*; read this for the call.

## What this adapter supplies that the core withholds

| The core says | This adapter supplies |
| --- | --- |
| "Fetch the item from the tracker." | `gh issue view <n> --json ...` and the field names that come back. |
| "Move it to the in-progress state." | GitHub has no in-progress state. A `status:` label, or a Projects v2 single-select field. |
| "Set a parent before continuing." | The sub-issues REST endpoints, and the id they key off. |
| "Run the candidate-parent query." | `gh issue list --search`, `gh api .../milestones`, and a Projects v2 GraphQL items query. |
| "Comment at start, handoff and finish." | `gh issue comment <n> --body-file -`. |
| "Terminal states distinguish finished from abandoned." | `gh issue close --reason`, which is the only place GitHub records that distinction. |

## Precondition: an authenticated `gh`

Every procedure here shells out to the GitHub CLI. Before running any of them:

```
gh auth status
```

It must report an account with a token for the host the repository lives on. If
it does not, stop and say so — do not fall back to guessing issue state from the
working tree. Projects v2 additionally needs a scope that a default login does
not grant; see the `projects-v2` skill.

Repository context comes from the checkout's `origin` remote. When you are not in
the repository, pass it explicitly — every `gh` subcommand here accepts
`--repo <owner>/<repo>`, and every `gh api` path takes `repos/{owner}/{repo}`
placeholders that `gh` fills from the current checkout when you leave them
literal.

## The ticket-pattern seam

This is a real mismatch and papering over it produces branches whose issue is not
recoverable, which is the one thing `branch-and-title-conventions` exists to
prevent.

The core shares `CLAUDE_TICKET_PATTERN` (default `[A-Z][A-Z0-9]+-[0-9]+`) with the
sibling `dev-guardrails` plugin. GitHub issues have no alphabetic prefix — they
are bare numbers, referenced as `#123`. The default pattern therefore matches
nothing in a GitHub repository, and the gate silently finds no key.

Two supported resolutions. Pick one per repository and write it down.

**Preferred — adopt a synthetic prefix.** The team agrees that `GH-123` means
issue `#123`. Set:

```
CLAUDE_TICKET_PATTERN=GH-[0-9]+
```

Branches become `feature/GH-123-add-auth-middleware`; commit scopes become
`feat(GH-123): ...`. The number is recovered with
`grep -oE 'GH-[0-9]+' <<< "$branch"` and then stripping `GH-`. The cost is one
translation step; the benefit is that a key is distinguishable from any other
number in a branch name, and that the same pattern shape works in a repo that
later migrates to a prefixed tracker.

**Alternative — bare numeric.** Set:

```
CLAUDE_TICKET_PATTERN=[0-9]+
```

Honest warning: this matches every number anywhere, including the `2` in
`refactor/v2-parser` and a date in a branch name. Only choose it in a repository
whose branch convention already puts the issue number first and nothing else
numeric in the name, and expect the gate to need the number confirmed rather than
inferred.

**Whichever you choose,** the closing keyword in a pull request body must use
GitHub's own reference form. `Fixes #123` closes the issue. `Fixes GH-123` does
not — GitHub does not resolve a synthetic prefix. Keep `GH-123` for branch names,
commit scopes and pull request titles; use `#123` in bodies and comments where
GitHub is doing the linking.

## Skills

| Skill | Use it when |
| --- | --- |
| `issue-lifecycle-github` | Satisfying the pre-work gate, reading an issue's full state, naming the branch, posting the start/handoff/finish comments, closing and reopening. |
| `triage-and-labels` | Representing the core's status vocabulary on a tracker that only has `open` and `closed`; building the label taxonomy; running a triage sweep. |
| `milestones-and-sub-issues` | Attaching a child to a parent, grouping work into a release or iteration, sweeping for orphans. |
| `projects-v2` | Reading or writing a project board — fields, single-select status, item field values. GraphQL only. |

## Not this plugin's job

- **Pull request lifecycle.** Opening, reviewing, merging and the checks that gate
  a merge belong to `github-workflow`. This plugin stops at the issue and at the
  reference that links a pull request back to it.
- **Judgement about the work.** Whether an item is well scoped, whether a state is
  honest, whether an orphan should be re-parented or declined — that is
  `issue-tracker-core`, and it is deliberately not restated here. When the two
  appear to conflict, the core wins and this adapter has a bug.
- **Commit message format.** `dev-standards` owns Conventional Commits; the core
  adds only that the scope is the issue key.
- **Repository policy.** Branch protection, required checks and CODEOWNERS are
  repository configuration, not issue tracking.
