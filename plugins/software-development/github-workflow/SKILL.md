---
name: github-workflow
description: "The GitHub half of a code review: take the verdict code-review-core wrote to .code-review/VALIDATED.json and post it to a pull request as inline threads plus a review event, drive the PR lifecycle with the gh CLI (create, check status, wait on checks, address feedback, merge), and author GitHub Actions workflows that are pinned, least-privileged and safe against untrusted pull request code. Use when findings need to reach a PR, when a branch needs a PR opened or merged, or when a workflow file is being written or debugged. NOT a reviewer: it forms no opinion about the diff — judgement belongs to code-review-core. NOT an issue tracker: issues, labels and project boards belong to github-issues."
license: MIT
user-invocable: false
---

# github-workflow

The transport and workflow layer over `code-review-core`. That plugin runs the review and refuses to
post it anywhere; this one does the posting, and forms no opinion of its own.

The split is not decoration. A reviewer that also owns the API call tends to grow provider-shaped
judgement — findings phrased as review-comment bodies, verdicts chosen to fit what the API accepts.
Keeping the judgement in a plugin that has no credentials makes that impossible, and makes the same
review usable on a forge this plugin knows nothing about.

## What it owns

| Concern | Where |
| --- | --- |
| Pull request lifecycle: create, inspect, wait on checks, remediate feedback, merge | `skills/pr-lifecycle` |
| Turning `.code-review/VALIDATED.json` into a posted GitHub review | `skills/review-transport` |
| Authoring and debugging GitHub Actions workflows | `skills/actions-authoring` |
| The posting itself, as a script a human or a CI job can run | `scripts/post-review.sh` |

## What it does not own

- **Judgement.** Whether a finding is a `BLOCKER`, whether a citation survives a re-read, what the
  verdict is — all of that is decided before this plugin is invoked, by `code-review-core`'s
  validator. This plugin reads the verdict; it never computes one, never edits a finding's severity,
  and never drops a finding it finds inconvenient to place.
- **Issue tracking.** Issues, labels, milestones and project boards belong to `github-issues`. A PR
  body may reference an issue key; managing the issue behind it is a different plugin's job.
- **Running the review.** `prepare-context.sh` and the judgement agents live in `code-review-core`.
  This plugin's precondition is that they already finished.

## The seam

`code-review-core` writes `.code-review/VALIDATED.json`. Its presence and parseability is the
completion signal — the validator writes it last, with the `Write` tool, precisely so that a partial
run leaves no file rather than a truncated one.

The document conforms to the agent contract: top-level `agent`, `category`, `findings`, and
optionally `verdict` (`APPROVE` | `REQUEST_CHANGES` | `INCOMPLETE`), `metrics` and
`blocking_reason_ids`. Each finding carries exactly ten required keys:

```
id, severity, category, location, title, evidence, recommendation, ux_impact, in_diff, confidence
```

Three fields drive transport decisions, and none of them are re-interpreted here:

| Field | Transport consequence |
| --- | --- |
| `in_diff` | `true` may become an inline thread; `false` is pre-existing and GitHub will reject an inline comment outside the diff, so it goes in the review body |
| `location` | the citation string the validator re-read. Parsed into `path` + `line`; when it will not parse, the finding degrades to the body rather than being dropped |
| `severity` | compared against `CODE_REVIEW_BLOCKING_FLOOR` (default `MINOR`) only to pick the review event |

**Absent or unparseable `VALIDATED.json` means the review did not finish.** Posting an approving or
empty review in that state is the worst outcome this plugin can produce: it converts "we do not know"
into a green check that a human will trust. Every path here refuses instead.

## Preconditions

`gh` must be installed and authenticated, and `jq` must be present. Check before anything else:

```bash
gh auth status
jq --version
```

`gh` resolves the repository from the checkout's `origin` remote. Outside a checkout, or when the
remote is ambiguous, pass `--repo <owner>/<repo>` to every `gh` call.

## Skills

| Skill | Use when |
| --- | --- |
| `pr-lifecycle` | opening a PR, reading its state, waiting on checks, addressing review feedback, merging |
| `review-transport` | a finished `code-review-core` run needs to reach a pull request |
| `actions-authoring` | writing, hardening or debugging a workflow under `.github/workflows/` |

## Surface

Every skill here drives a command-line tool, and `scripts/post-review.sh` is a shell script. That
makes the working parts of this plugin **Claude Code only** — Cowork (Claude Code on the web) has no
checkout and no shell, so the skills still load and read as guidance there, but nothing they describe
can actually run. See `README.md` for the per-component breakdown.
