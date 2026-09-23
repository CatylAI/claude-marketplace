# gitlab-workflow

GitLab transport for code review. Merge request lifecycle over the `glab` CLI, posting review
findings to an MR, and `.gitlab-ci.yml` authoring.

It is the GitLab sibling of `github-workflow` and sits on the same forge-neutral core.
`code-review-core` runs the whole review on a plain `git diff` and posts nothing anywhere; this
plugin is the half that talks to GitLab.

## When to use it

- Opening, watching or merging a merge request from the terminal.
- Getting a finished `code-review-core` run onto an MR as inline discussions.
- Writing or hardening a `.gitlab-ci.yml`, or working out why a pipeline did not run.

## When not to use it

- **You want the review itself.** That is `code-review-core` — detectors, judgement agents, one
  owner of the verdict. This plugin only carries its output.
- **You are on GitHub.** `github-workflow` is the same shape for `gh`.
- **You want issue tracking.** `jira-tracker` or `github-issues`, over `issue-tracker-core`.

## Prerequisites

```bash
glab auth status
jq --version
```

`glab` authenticated against your instance, and `jq`. The transport refuses rather than degrades if
either is missing — a review that silently posted nothing would be worse than one that failed.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install gitlab-workflow@catylai
```

`code-review-core` comes with it as a dependency.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `mr-lifecycle` | Skill | Open an MR, read its state, watch the pipeline, address feedback, merge | both |
| `review-transport` | Skill | Get a finished `code-review-core` run onto a merge request | both |
| `gitlab-ci-authoring` | Skill | Write, harden and debug `.gitlab-ci.yml` | both |
| `scripts/post-review.sh` | Script | The transport itself | Claude Code only |

## Surfaces

Skills load in both Claude Code and Cowork (Claude Code on the web).

**Everything here shells out to `glab`, and Cowork has no shell.** The procedures are readable on
both surfaces; executing any of them needs Claude Code. `post-review.sh` is a shell script and does
not exist on the web at all.

## The seam

`code-review-core` writes `.code-review/VALIDATED.json` and stops. That document is the contract:
a ten-key finding shape with three orthogonal axes — `severity` for impact, `in_diff` for whether
this change introduced it, `confidence` for how well it was traced.

`post-review.sh` reads that document and turns it into a merge request review:

- `in_diff: true` with a parseable `location` becomes an **inline discussion** on the diff.
- Everything else goes in the **summary note**, including pre-existing findings, which keep their
  severity and are marked as pre-existing rather than downgraded.
- A finding whose location will not parse **degrades to the summary note**. It is never dropped.

Three refusals are load-bearing and tested as refusals: a missing or unparseable `VALIDATED.json`
is not an empty review, an `INCOMPLETE` verdict never becomes an approval, and finding text is
passed as argument arrays so a title containing `$(…)` or backticks stays literal.

### The part that is genuinely not GitHub

Posting an inline comment on a GitLab MR needs a **`position` object**, not just a path and a line:
`base_sha`, `head_sha`, `start_sha`, `new_path`, `old_path`, `new_line`. The three SHAs come from
the MR's own `diff_refs`:

```bash
glab api "projects/:id/merge_requests/<iid>" --jq '.diff_refs'
```

Get this wrong and every inline comment fails while the summary note still posts — which looks like
a working transport that just happens to find nothing inline. `post-review.sh` fetches `diff_refs`
once per run and fails loudly if they are absent.

## Tests

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/post-review.test.sh"
zsh  "$CLAUDE_PLUGIN_ROOT/scripts/post-review.test.sh"
```

Plain shell, no arguments, portable to bash 3.2 and zsh. Builds its own fixtures under `$TMPDIR`
and removes them on exit; no network, and `glab` is stubbed on `PATH`. A test needing a binary this
machine lacks reports **skipped**, never a pass.

House style is **plant a defect, assert a non-zero exit** — including a command-injection case that
plants `$(…)` and backticks in a finding's text and asserts no file was created and the text
survived as literal.

## Dependencies

`code-review-core`, for the pipeline whose output this transports.

## License

MIT.
