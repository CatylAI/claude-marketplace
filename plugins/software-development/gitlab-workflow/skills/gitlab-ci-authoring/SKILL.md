---
name: gitlab-ci-authoring
description: "Write and harden .gitlab-ci.yml: pin every remote include to a tag or commit SHA instead of a mutable branch, use rules: rather than the legacy only/except, build a DAG with needs:, keep artifacts and cache distinct, get cloud credentials from OIDC id_tokens instead of long-lived keys, cancel superseded pipelines with interruptible, and select runners by tag. Also covers when extends:, child pipelines and reusable templates earn their complexity, and how to read a failing job. Use when creating or editing .gitlab-ci.yml, reviewing a pipeline for supply-chain or secret-exposure risk, or debugging a red pipeline."
license: MIT
when_to_use: "write a gitlab ci pipeline, add CI to this repo, gitlab-ci rules vs only except, needs DAG, cache vs artifacts, OIDC to AWS from GitLab, id_tokens, masked variable, protected variable, interruptible, runner tags, child pipeline, why is my pipeline not running"
allowed-tools: Bash(glab:*), Bash(git:*), Bash(python3:*), Read, Write, Edit, Grep, Glob
---

# gitlab-ci-authoring

A pipeline file is production code with a credential attached. It runs on a machine you do not own,
with access to your registry and your cloud. Treat it accordingly.

## Step 1 — see what exists

```bash
ls -la .gitlab-ci.yml .gitlab/ci 2>/dev/null
git log --oneline -5 -- .gitlab-ci.yml
glab ci list --per-page 5
```

If there is no shell available, ask for the current `.gitlab-ci.yml` and the last few pipeline
results to be pasted in. Do not propose edits to a file you have not read.

## Pin every remote `include:` to a tag or a SHA

```yaml
# Wrong — a branch is a mutable pointer. Whoever controls it controls your pipeline.
include:
  - project: '<group>/ci-templates'
    file: '/templates/build.yml'
    ref: main

# Right — a tag, or better a commit SHA, with the human-readable version alongside.
include:
  - project: '<group>/ci-templates'
    file: '/templates/build.yml'
    ref: 3d3c42e5aac5ba805825da76410c181273ba90b1  # v2.4.0
```

This is the same rule the sibling `github-workflow` plugin's `actions-authoring` states for
third-party actions, for the same reason and at the same bar: **a mutable ref means an upstream
compromise runs arbitrary code in your pipeline with your secrets.** A tag is better than a branch
because it is *conventionally* stable; a SHA is better than a tag because it is *actually*
immutable. Where a remote include is from a project you do not control, a SHA is the only honest
choice.

`include:remote:` fetching a URL is worse still — it has no ref at all. Prefer `project:` or
`component:`.

## `rules:` replaces `only/except`

`only/except` is legacy and cannot express most of what real pipelines need. Everything new uses
`rules:`.

```yaml
deploy:
  script: ./deploy.sh
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
      when: never
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
      when: on_success
    - when: never          # default-deny. Say it out loud.
```

**Rules are evaluated top to bottom and the first match wins.** Order is the logic. End with an
explicit `when: never` rather than relying on the implicit default — a reader should not have to
know the default to know whether the job runs.

`changes:` is the common trap: on a branch pipeline it compares against the previous commit, which
after a squash or a force-push is not what you meant. Scope it to merge-request pipelines where the
comparison is against the target branch.

## `needs:` turns stages into a DAG

Stages run in sequence; `needs:` lets a job start as soon as its own dependencies finish.

```yaml
test:unit:
  stage: test
  needs: ['build']        # starts when build finishes, not when all of stage build does
```

`needs: []` starts a job immediately, in parallel with the first stage — right for a lint job that
depends on nothing. The cost is that a DAG is harder to read than a sequence, so use it where the
wall-clock saving is real and keep the stage list meaningful.

## `cache` and `artifacts` are not the same thing

| | `cache` | `artifacts` |
|---|---|---|
| Purpose | Speed. Reusable between pipelines. | Output. Passed between jobs, downloadable. |
| If missing | Job is slower | Job is **wrong** |
| Keyed by | `cache:key`, usually a lockfile hash | Nothing — produced by the job |

**A pipeline that is correct only when the cache is warm is broken.** Test it cold. The failure mode
is a green pipeline on every machine that has run it before and a red one for the new contributor.

`dependencies:` controls which jobs' artifacts a job downloads. Absent, a job downloads artifacts
from **every** job in every earlier stage — usually wasteful, occasionally wrong when two jobs
produce the same path. Set `dependencies: []` on jobs that need none.

## Secrets

- **Masked** hides a value in job logs. It only works for values matching GitLab's mask rules, and a
  variable that silently fails to mask looks exactly like one that masked successfully. Check.
- **Protected** restricts a variable to protected branches and tags. Without it, anyone who can push
  a branch can open an MR whose pipeline prints your production credential.
- Masking is not secrecy. A script that sends a secret somewhere is not stopped by masking, and a
  value that is base64'd in transit is not masked at all.

### Prefer OIDC over stored cloud keys

```yaml
deploy:
  id_tokens:
    AWS_TOKEN:
      aud: https://gitlab.example.com     # your instance, per the cloud's trust policy
  script:
    - aws sts assume-role-with-web-identity
        --role-arn "$AWS_ROLE_ARN"
        --web-identity-token "$AWS_TOKEN"
        --role-session-name "ci-$CI_PIPELINE_ID"
```

A long-lived access key in a CI variable is a credential with no expiry, readable by anyone who can
run a job. OIDC exchanges a short-lived pipeline-scoped token instead, and the cloud side can
condition the trust on the project, the branch and whether the ref is protected. See the
`terraform-aws` plugin's `aws-iam-boundaries` skill for the role side of this.

## Cancel superseded pipelines

```yaml
default:
  interruptible: true      # per job, or here for all of them
```

With **auto-cancel redundant pipelines** enabled on the project, a new push cancels the older
running pipeline for that ref. Jobs that must not be killed mid-flight — anything that has already
started a deploy or a migration — set `interruptible: false` explicitly.

## Runners

```yaml
build:
  tags: ['<runner-tag>']
```

A job whose tags match no available runner does not fail. It sits pending, which during an incident
reads as a slow pipeline rather than a broken one. If a job is pending for more than a minute,
check that a runner with those tags exists and is online before debugging the job.

## When the bigger mechanisms earn their complexity

- **`extends:`** — three or more jobs sharing a shape. Clearer than YAML anchors because it composes
  and can be overridden per key. Prefer it to `<<: *anchor`.
- **Child pipelines** (`trigger:include:`) — a monorepo where each component has its own real
  pipeline. Worth it when the alternative is one file nobody can read; not worth it for two jobs.
- **Components / templates** — the same pipeline shape across repositories. Version them and pin
  them, per the rule at the top.
- **`parallel:matrix:`** — the same job across a version or platform matrix. Watch the job count;
  a three-by-three matrix is nine runners.

## Debugging a red pipeline

```bash
glab ci status
glab ci view
glab ci trace <job-id>
```

Three failures that are not what they look like:

- **The pipeline did not run at all.** Almost always `rules:` — or `workflow:rules:` at the top of
  the file, which gates whether a pipeline is created in the first place and is easy to forget.
- **A job is pending forever.** Runner tags, above.
- **A YAML error.** GitLab rejects the file and the pipeline never appears, which looks identical to
  a rule that did not match. Lint before pushing:

```bash
glab ci lint
python3 -c 'import sys,yaml;yaml.safe_load(open(sys.argv[1]))' .gitlab-ci.yml
```

`glab ci lint` is the authority — it validates against the server, which resolves `include:` and
catches a broken remote reference that local YAML parsing cannot see.
