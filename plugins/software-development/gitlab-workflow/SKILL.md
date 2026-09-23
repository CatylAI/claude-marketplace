---
name: gitlab-workflow
description: "The GitLab half of a code review: take the verdict code-review-core wrote to .code-review/VALIDATED.json and post it to a merge request as inline diff discussions plus an MR-level summary note, drive the MR lifecycle with the glab CLI (create, view, check the pipeline, address feedback, merge), and author .gitlab-ci.yml pipelines that are pinned, least-privileged and authenticated with OIDC rather than stored keys. Use when findings need to reach an MR, when a branch needs an MR opened or merged, or when a pipeline file is being written or debugged. NOT a reviewer: it forms no opinion about the diff — judgement belongs to code-review-core. NOT GitHub: that transport is github-workflow."
license: MIT
user-invocable: false
---

# gitlab-workflow

The transport and workflow layer over `code-review-core`. That plugin runs the review and refuses to
post it anywhere; this one does the posting, and forms no opinion of its own.

The split is not decoration. A reviewer that also owns the API call tends to grow provider-shaped
judgement — findings phrased as note bodies, verdicts chosen to fit what the API accepts. Keeping the
judgement in a plugin that has no credentials makes that impossible, and it is what let this plugin
exist at all: `github-workflow` and this one are two transports over one unchanged review.

## What it owns

| Concern | Where |
| --- | --- |
| Merge request lifecycle: create, inspect, watch the pipeline, remediate feedback, merge | `skills/mr-lifecycle` |
| Turning `.code-review/VALIDATED.json` into a posted GitLab review | `skills/review-transport` |
| Authoring and debugging `.gitlab-ci.yml` | `skills/gitlab-ci-authoring` |
| The posting itself, as a script a human or a CI job can run | `scripts/post-review.sh` |

## What it does not own

- **Judgement.** Whether a finding is a `BLOCKER`, whether a citation survives a re-read, what the
  verdict is — all of that is decided before this plugin is invoked, by `code-review-core`'s
  validator. This plugin reads the verdict; it never computes one, never edits a finding's severity,
  and never drops a finding it finds inconvenient to place.
- **Issue tracking.** GitLab issues, labels, milestones and boards are a different surface. An MR
  description may reference an issue; managing the issue behind it is not this plugin's job.
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
| `in_diff` | `true` may become an inline discussion on the MR diff; `false` is pre-existing and cannot be anchored to a line inside this MR's diff, so it goes in the summary note |
| `location` | the citation string the validator re-read. Parsed into `path` + `line`; when it will not parse, the finding degrades to the summary note rather than being dropped |
| `severity` | compared against `CODE_REVIEW_BLOCKING_FLOOR` (default `MINOR`) only to pick the review event |

**Absent or unparseable `VALIDATED.json` means the review did not finish.** Posting an approving or
empty review in that state is the worst outcome this plugin can produce: it converts "we do not know"
into a green check that a human will trust. Every path here refuses instead.

## Where GitLab differs from GitHub, and why this plugin is not a find-and-replace

The two adapters have the same shape on purpose — same seam, same refusals, same marker-based
idempotency, same routing table. Three things genuinely differ, and each one changes the code:

1. **An inline note needs a `position` object, not a path and a line.** GitLab requires the merge
   request's three diff SHAs (`base_sha`, `start_sha`, `head_sha`) alongside `new_path`, `old_path`
   and `new_line`. They come from the MR's `diff_refs` and are not derivable from the checkout, so
   posting always costs one GET first.
2. **There is no atomic review endpoint.** GitHub lands a body and every inline comment in one call.
   GitLab's nearest equivalent is *draft notes*: POST each one (invisible), verify all of them, then
   `bulk_publish` once. The script deletes the drafts it created if any fails, so a non-zero exit
   still means the MR was left as it was.
3. **There is no `REQUEST_CHANGES` review event.** GitLab's API has an approval and the absence of
   one. `APPROVE` calls `POST .../approve`; `REQUEST_CHANGES` and `INCOMPLETE` post the review and
   deliberately leave the MR unapproved, saying so in the summary body.

## Preconditions

`glab` must be installed and authenticated, and `jq` must be present. Check before anything else:

```bash
glab auth status
jq --version
```

`glab` resolves the project from the checkout's `origin` remote. Outside a checkout, or when the
remote is ambiguous, pass `--project <group>/<project>` to `post-review.sh` and `--repo
<group>/<project>` to the `glab mr` and `glab ci` commands.

## Skills

| Skill | Use when |
| --- | --- |
| `mr-lifecycle` | opening an MR, reading its state, watching the pipeline, addressing feedback, merging |
| `review-transport` | a finished `code-review-core` run needs to reach a merge request |
| `gitlab-ci-authoring` | writing, hardening or debugging `.gitlab-ci.yml` |

## Surface

Every skill here drives a command-line tool, and `scripts/post-review.sh` is a shell script. That
makes the working parts of this plugin **Claude Code only** — Cowork (Claude Code on the web) has no
checkout and no shell, so the skills still load and read as guidance there, but nothing they describe
can actually run. See `README.md` for the per-component breakdown.
