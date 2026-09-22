---
name: actions-authoring
description: "Write and harden GitHub Actions workflows: pin third-party actions to a full commit SHA instead of a mutable tag, declare least-privilege permissions per job instead of inheriting the default token scope, keep pull_request_target away from untrusted PR code, use OIDC instead of long-lived cloud keys, cancel superseded runs with a concurrency group, and name jobs so branch protection can require them. Also covers when caching, matrix builds, reusable workflows and composite actions earn their complexity, and how to read a failing run with gh run view --log-failed. Use when creating or editing anything under .github/workflows/, reviewing a workflow for supply-chain or secret-exposure risk, or debugging a red CI run."
license: MIT
when_to_use: "write a GitHub Actions workflow, add CI to this repo, pin actions to a SHA, workflow permissions, GITHUB_TOKEN scope, pull_request_target, OIDC to AWS from Actions, cancel in-progress runs, cache dependencies in CI, matrix build, reusable workflow, composite action, required status checks, why is my workflow failing"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(python3:*), Read, Write, Edit, Grep, Glob
---

# actions-authoring

A workflow file is production code with a credential attached. It runs on a machine you do not own,
with a token that can write to your repository, triggered by events that strangers can cause. Write
it that way.

## Anatomy and location

Workflows live in `.github/workflows/*.yml`, one file per workflow, at the repository root — not in a
subdirectory, and not anywhere else. A file elsewhere is silently never run.

```yaml
name: ci

on:
  pull_request:
  push:
    branches: [main]

# Workflow-level default. Every job starts from this and grants itself more only when it needs it.
permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    name: test (3.12)
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
      - uses: actions/setup-python@0b93645e9fea7318ecaed2b359559ac225c90a2b  # v5.3.0
        with:
          python-version: "3.12"
      - run: pip install -e '.[test]'
      - run: pytest -q
```

Two things that are not optional in any workflow you write: `timeout-minutes` on every job (the
default is six hours, and a hung job holds a runner for all of it) and an explicit `permissions`
block.

## Pin third-party actions to a full commit SHA

```yaml
# Wrong — a tag is a mutable pointer.
- uses: some-org/some-action@v3

# Right — an immutable commit, with the human-readable version in a trailing comment.
- uses: some-org/some-action@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
```

`@v3` is a git tag in someone else's repository, and a tag can be moved to any commit at any time by
anyone with write access there. You are not depending on the code you reviewed; you are depending on
whatever that name points at the next time your workflow runs. That is a remote-code-execution hole
with a step in your job, and it has been used: the pattern of a compromised action rewriting its own
tags to exfiltrate every secret in every repository that referenced it is the reason this rule
exists.

Resolve the SHA yourself rather than copying one. **Every SHA in this document is illustrative** — a
pin is only trustworthy if you resolved it for the version you actually reviewed:

```bash
gh api repos/actions/checkout/git/ref/tags/v4.2.2 --jq '.object.sha'
```

A 40-character SHA cannot be moved. The trailing comment keeps it readable and gives Dependabot
something to bump — configure `.github/dependabot.yml` with the `github-actions` ecosystem and it
will propose SHA updates with the release notes attached, which is the review you actually want.

Actions under the `actions/` and `github/` organizations are the same risk with a different owner.
Pin them too. The only thing that does not need pinning is a local action in your own repository
referenced by path (`./.github/actions/setup`).

## Permissions

The default `GITHUB_TOKEN` scope is a repository setting, not a property of your workflow — which
means a workflow with no `permissions:` block has whatever scope the organization happens to have
configured, and that can change without your file changing. Never leave it implicit.

```yaml
permissions:
  contents: read          # workflow-level floor

jobs:
  test:
    # inherits contents: read, and needs nothing else
    runs-on: ubuntu-latest

  comment:
    permissions:
      contents: read
      pull-requests: write   # this job posts a comment; nothing else in the workflow can
    runs-on: ubuntu-latest

  release:
    permissions:
      contents: write        # this job pushes a tag
      id-token: write        # and mints an OIDC token for the registry
    runs-on: ubuntu-latest
```

A job-level `permissions` block **replaces** the workflow-level one rather than adding to it, so list
every scope that job needs. Declaring `permissions: {}` at the workflow level and granting everything
per job is the strictest form and is worth it in a repository with many jobs.

The blast radius is per job, so keep the job that touches untrusted input separate from the job that
holds a write scope. A single job that both builds a fork's PR and has `contents: write` is one
malicious `package.json` script away from a force-push.

## `pull_request` vs `pull_request_target`

This is the single most exploited distinction in GitHub Actions.

| Trigger | Runs the workflow file from | Token | Secrets |
| --- | --- | --- | --- |
| `pull_request` | the **base** branch | read-only by default, no write to the base repo for forks | not available to fork PRs |
| `pull_request_target` | the **base** branch | full scope, as configured | **available, including to fork PRs** |

`pull_request_target` exists so a maintainer can label or comment on a fork's PR, which a fork-scoped
token cannot do. It runs in the context of the base repository with the base repository's secrets.

**The rule: a `pull_request_target` workflow must not check out, build, install, or execute the pull
request's head.** No `ref: ${{ github.event.pull_request.head.sha }}`, no `npm install` on the PR's
lockfile, no running its tests, no action whose input is a file from the PR. Doing any of those runs
the contributor's code with your secrets in scope, and a `postinstall` script is enough to exfiltrate
every one of them.

```yaml
# Correct use: it reads metadata and writes a label. It never touches the PR's files.
name: triage
on:
  pull_request_target:
    types: [opened, reopened]
permissions:
  contents: read
  pull-requests: write
jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - run: gh pr edit "$PR" --add-label needs-triage
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR: ${{ github.event.pull_request.number }}
```

If you need to both build a fork's code and post a result, split it: a `pull_request` job builds with
no secrets and uploads an artifact, and a separate `workflow_run` job with the write scope downloads
that artifact and posts. The privileged half never executes untrusted code.

While you are there: never interpolate untrusted event data into a `run:` block. `${{
github.event.pull_request.title }}` inside a shell line is evaluated by the runner *before* the shell
sees it, so a PR titled with a command substitution runs that command. Pass it through `env:` and
reference `"$TITLE"` as a quoted shell variable, as above.

## Secrets and cloud credentials

`secrets.GITHUB_TOKEN` is minted per job, scoped by your `permissions:` block, and revoked when the
job ends. Prefer it over a personal access token for anything inside the repository — a PAT is a
long-lived credential with a human's full access, and it is the wrong tool for "this job needs to
comment on a PR".

For anything outside the repository, use OIDC rather than storing a key:

```yaml
jobs:
  deploy:
    permissions:
      id-token: write     # required to mint the OIDC token
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502  # v4.0.2
        with:
          role-to-assume: arn:aws:iam::<account-id>:role/<ci-role-name>
          aws-region: <region>
```

The runner exchanges a short-lived signed token for temporary cloud credentials. There is no static
key in the repository to leak, rotate, or find in a log. Scope the trust policy on the cloud side to
the specific repository *and* branch or environment — a trust policy that accepts any repository from
the GitHub OIDC issuer is not an improvement over a stored key.

Two more: secrets are masked in logs only when they appear verbatim, so a base64-encoded or
line-split secret prints in the clear; and `pull_request` runs from forks get no secrets at all, so a
workflow that silently degrades when a secret is empty will behave differently for contributors than
it did for you.

## Concurrency

Without a `concurrency` group, pushing three times to a branch runs three full builds and the first
two are already irrelevant.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Group on the workflow plus the ref so different branches do not cancel each other. Use
`cancel-in-progress: false` for deployment workflows — cancelling a half-finished deploy leaves the
target in a state nobody designed.

## Caching, matrices, reusable workflows, composite actions

Each of these buys something and costs something. Add one when the thing it buys is a problem you
actually have.

| Mechanism | Earns its place when | Costs |
| --- | --- | --- |
| `actions/cache` | restore is meaningfully faster than a clean install, and the key is exact | a stale or over-broad key makes builds non-reproducible in a way that is miserable to debug; `setup-*` actions already cache with `cache: pip`/`cache: npm`, so reach for those first |
| `strategy.matrix` | the same job must genuinely run across versions or platforms | N times the minutes; add `fail-fast: false` only when you want every cell's result, and cap with `max-parallel` on a shared runner pool |
| reusable workflow (`workflow_call`) | three or more repositories need the *same* pipeline, versioned centrally | a change in one place changes every caller; pin callers to a tag or SHA of the reusable workflow |
| composite action | a sequence of steps repeats within a repository | another unit to version and test; two steps repeated twice is not worth it |

Cache keys should include the lockfile hash so a dependency change invalidates them:

```yaml
- uses: actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57  # v4.2.0
  with:
    path: ~/.cache/pip
    key: pip-${{ runner.os }}-${{ hashFiles('**/requirements*.txt') }}
    restore-keys: pip-${{ runner.os }}-
```

## Naming jobs so branch protection can require them

Branch protection matches a required check by the **name the check reports**, which is the job's
`name:` — or, in a matrix, `name (value1, value2)`. Rename a job and the required check silently
stops matching: the rule now requires a check that never reports, so the PR either blocks forever or,
depending on configuration, stops being gated at all.

```yaml
jobs:
  test:
    name: test            # required check is "test", and stays "test"
    strategy:
      matrix:
        python: ["3.11", "3.12"]
    # reports as: test (3.11), test (3.12)
```

For a matrix, either require every cell by name or add a single aggregate job that `needs:` all of
them and require that one instead — the aggregate keeps its name when the matrix changes:

```yaml
  ci-ok:
    name: ci-ok
    needs: [test, lint]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: |
          [ "${{ needs.test.result }}" = "success" ] || exit 1
          [ "${{ needs.lint.result }}" = "success" ] || exit 1
```

`if: always()` matters: without it the aggregate is skipped when a dependency fails, and a skipped
required check can read as satisfied.

Read what protection currently requires before renaming anything:

```bash
gh api "repos/<owner>/<repo>/branches/main/protection" --jq '.required_status_checks.contexts'
```

## Debugging a failing run

```bash
# What ran, and how it ended
gh run list --limit 10
gh run list --workflow ci.yml --branch "$(git branch --show-current)" --limit 5

# Only the failing steps' output — the difference between 50 lines and 50,000
gh run view <run-id> --log-failed

# The whole log when the failure is an ordering or environment problem
gh run view <run-id> --log

# A specific job
gh run view <run-id> --job <job-id> --log-failed

# Re-run only what failed, once you have a reason to think it was flaky
gh run rerun <run-id> --failed

# Follow a run that is still going
gh run watch <run-id>
```

Validate the file before pushing it — a YAML error means the workflow does not appear at all, which
looks exactly like a trigger that did not match:

```bash
python3 -c 'import sys,yaml;yaml.safe_load(open(sys.argv[1]))' .github/workflows/ci.yml
```

When a workflow did not run at all, the cause is almost always one of: the file is not on the default
branch (for `schedule` and `workflow_dispatch`), the `on:` filters do not match, `paths`/`branches`
filters excluded it, or the YAML did not parse. Check in that order.

For step-level tracing, set the repository variables `ACTIONS_STEP_DEBUG` and `ACTIONS_RUNNER_DEBUG`
to `true` and re-run. Turn them off afterwards — debug logs are much more likely to print something
you did not intend to keep.

## Review checklist

Before merging any change to a workflow file:

- Every third-party `uses:` is a 40-character SHA with a version comment.
- A `permissions:` block exists at the workflow level, and each job grants only what it needs.
- No `pull_request_target` job checks out, installs, builds or runs the PR head.
- No `${{ }}` interpolation of event data inside a `run:` block.
- Every job has `timeout-minutes`.
- Cloud auth is OIDC, not a stored access key.
- Any job name that branch protection requires has not changed.

## Surface

Claude Code only for the `gh` commands. Writing and reviewing the YAML is file work and reads fine
anywhere; running `gh run view` needs a shell, which Cowork does not have.
