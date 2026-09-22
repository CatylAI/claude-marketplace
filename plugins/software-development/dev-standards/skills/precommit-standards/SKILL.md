---
name: precommit-standards
license: MIT
description: Pre-commit hook conventions and how to review a repo's .pre-commit-config.yaml for drift — the always-on hook set, which stage each hook belongs to, generated-artifact excludes, and when a bespoke local hook should be promoted out of the repo. Use when adopting pre-commit in a repo, auditing an existing config, or when a hygiene hook keeps rewriting generated files.
---

# Pre-commit Standards

A reference config ships with this plugin at `templates/.pre-commit-config.yaml`. Treat it
as the baseline: a repo enables the sections its file types need and comments out the rest,
saying why.

## Install every hook type the config uses

```yaml
default_install_hook_types: [pre-commit, commit-msg, pre-push]
```

This line is load-bearing. Without it, `pre-commit install` writes **only** the pre-commit
shim, and every hook declared `stages: [pre-push]` or `stages: [commit-msg]` is configured
and never runs. A hook that never runs is indistinguishable from a hook that passes — which
is how a repo can show thirty configured hooks and zero enforcement.

Changing the list does not retro-install anything. Existing clones need one command:

```bash
pre-commit install --install-hooks
```

Verify by looking, not by reading the config: `ls .git/hooks/` must contain a shim for each
declared type.

## Stage the hook by its cost

| Stage | What belongs there | Budget |
| --- | --- | --- |
| `pre-commit` | Formatters, linters, secret scans, file hygiene | Under ~5s total |
| `commit-msg` | Commit message format enforcement | Instant |
| `pre-push` | Test suites, typecheck, whole-repo scans | Tens of seconds is fine |

The rule behind this: a slow pre-commit stage is the reason people reach for `--no-verify`,
and a config everyone bypasses enforces nothing. A test suite measured at ~50s belongs at
push time; the same suite at commit time gets the whole config disabled within a week.

## The always-on set

Whatever else a repo enables, these run everywhere:

| Hook | Guards against |
| --- | --- |
| Conventional-commit check (`commit-msg`) | Messages that break changelog and semver automation |
| `detect-private-key` | A key file committed by accident |
| `check-merge-conflict` | Conflict markers reaching the trunk |
| `end-of-file-fixer` | Missing trailing newlines |
| `trailing-whitespace` | Whitespace-only diff noise |
| A secret scanner | Credentials in the diff |

Run **two** secret scanners, not one. Their rulesets disagree at the edges — one vendor's
allowlist has been observed suppressing a live cloud key that the other caught. The
redundancy is deliberate; do not consolidate it away.

## Generated artifacts need an exclude

Machine-emitted files do not obey the rules a source file does. A diagram renderer writes
SVGs with no trailing newline, so `end-of-file-fixer` "fixes" them on every `--all-files`
run, producing diffs outside the change under review. Every such tree needs an exclude on
the hygiene hooks:

```yaml
exclude: '^docs/architecture/.*\.(svg|png)$'
```

Keep the repo-wide exclusions as a single verbose-mode alternation at the top of the file —
dependency directories, caches, build output, lockfiles, minified assets, tool scratch
directories. Two cautions:

- A top-level `exclude:` reaches **pre-commit only**. Hooks that run with
  `pass_filenames: false` (whole-tree scanners) need their own ignore configuration.
- Never exclude a file that is a hook's own trigger. Excluding a lockfile from the hook
  whose job is to regenerate that lockfile silently disables the hook.

## Pin every rev, and keep the pins current

Every `repo:` entry carries an explicit `rev:`. A floating rev makes the hook's behavior
depend on when it was last installed, so the same commit passes on one machine and fails on
another. Bumping a pin is a behavior change — do it deliberately, in its own commit, and
run `pre-commit run --all-files` afterwards.

Where a hook is known to break under a newer runtime, pin its `language_version` too and
say why in a comment next to the pin.

## Auditing a repo for drift

Walk these five categories, most impactful first:

1. **Missing required hooks** — any of the always-on set absent.
2. **A section the repo needs is disabled** — `.tf` files present but the IaC section
   commented out; `package.json` with a test script but the Node section off; `.py` files
   with no Python section.
3. **Missing generated-artifact excludes** — only flag this when the repo actually tracks
   generated files. A repo with no generated tree should stay quiet.
4. **Stale pinned revs.**
5. **Bespoke `repo: local` hooks** — see below.

Report the drift as a table before changing anything, and get approval for anything that
changes behavior (enabling a section, bumping a rev). Batch the low-risk fixes — adding an
`exclude:`, aligning a rev to the baseline — into one approval. After editing:

```bash
pre-commit validate-config .pre-commit-config.yaml
pre-commit run --all-files
```

## Bespoke local hooks

A `repo: local` hook that is not in the baseline is either a promotion candidate or an
intentional exception. Decide which, and say so:

- **Broadly useful** — recommend moving it into the shared baseline so every repo gets it,
  rather than leaving it as a one-off that drifts.
- **Genuinely repo-specific** — a build or test shim that only makes sense here. Leave it
  and note that it is intentional.

Write local hooks defensively. Resolve the interpreter at run time and fail loudly when the
environment is missing, rather than exiting 127 with a bare "command not found":

```yaml
- id: unit-tests
  name: unit tests (pre-push)
  entry: >
    sh -c 'root=$(git rev-parse --show-toplevel);
    if [ -x "$root/.venv/bin/pytest" ]; then py="$root/.venv/bin/pytest";
    elif command -v pytest >/dev/null 2>&1; then py=pytest;
    else echo "pytest not found — fix the environment, not this hook"; exit 1; fi;
    "$py" tests/ -m "not integration and not e2e" -q'
  language: system
  pass_filenames: false
  stages: [pre-push]
```

And scope any test runner to the main tree. A repo using worktrees will otherwise collect
every worktree's copy of every suite — which is red locally, green in CI where no worktrees
exist, and therefore goes unnoticed for a long time.

## Zero tolerance

The target is a config where `pre-commit run --all-files` is clean and produces no spurious
diffs. Never `--no-verify`, never disable a hook to silence it, never lower a threshold to
make one pass. Fix the underlying config or the underlying code. See
`zero-tolerance-testing`.
