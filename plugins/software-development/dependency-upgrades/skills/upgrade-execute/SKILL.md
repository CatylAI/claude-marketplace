---
name: upgrade-execute
description: "Executes an upgrade plan one change at a time — apply a single step, make the code modifications that step requires, run the full suite plus typecheck and lint, compare against the baseline captured before any change, then commit before moving on. Use when carrying out a dependency or runtime upgrade that has already been planned. Handles a failing step by reverting that step alone and continuing with the independent ones, and stops on a red baseline, an unplanned major, or an unapproved change to a deployment-pinned runtime."
license: MIT
---

# upgrade-execute

Stage 4. Carry out the plan from `upgrade-plan`, one step at a time, so that any failure names its
own cause.

The entire discipline is one sentence: **one change, verified against a baseline, committed, before
the next change starts.**

## Before the first change

Confirm three things. If any is missing, go back to stage 3 rather than improvising.

1. **A written plan exists**, with ordered steps, each carrying its verification and rollback. An
   upgrade executed without one is a batch upgrade with extra steps.
2. **The baseline is captured** — the full output of the test suite, typecheck and lint on the
   current versions, saved where it can be diffed against later. Not the exit code. The output.
3. **The working tree is clean and on a branch.** Unrelated uncommitted changes make every
   subsequent revert ambiguous.

```bash
git status --short                 # must be empty
git rev-parse --abbrev-ref HEAD    # must not be the default branch
```

If a baseline was not captured in stage 3, capture it now, before touching a single version. The
commands are in `upgrade-plan`'s gate 1. Save it:

```bash
npm test > .upgrade-baseline.txt 2>&1; echo "exit:$?" >> .upgrade-baseline.txt
```

Keep it out of the commit — add it to `.git/info/exclude` rather than to `.gitignore`, so the
repository's ignore rules are not themselves part of the upgrade diff.

**If the baseline is red, stop.** That is a stop condition, not a caveat. See below.

## The step loop

For each step in the plan, in plan order:

### 1. Apply exactly one change

Edit the manifest, then let the package manager regenerate the lockfile. Never both by hand, and
never more than one step's worth of edits at a time.

```bash
npm install <pkg>@<version>              # writes package.json and package-lock.json together
npm install                              # after a manual package.json edit
uv lock && uv sync                       # Python, uv
poetry lock --no-update && poetry install
pip-compile requirements.in              # pip-tools
go get <module>@<version> && go mod tidy
cargo update --package <crate> --precise <version>
bundle update <gem> --conservative       # --conservative moves only the named gem
terraform init -upgrade -backend=false
./gradlew dependencies --write-locks     # when dependency locking is enabled
```

**Lockfile discipline.** Regenerate; never hand-edit. A hand-edited lockfile describes a tree the
resolver would not have produced, so the next legitimate install silently undoes the edit, or
produces something different, and nobody can reproduce what was tested. Commit the lockfile in the
same commit as its manifest — they are one change, and split across commits either half is a broken
checkout.

For Terraform, regenerate hashes for every platform in use, not just the local one:

```bash
terraform providers lock \
  -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
```

### 2. Make the code changes this step requires

**Modifications required by the upgrade are part of the step, not follow-up work.** A step that
leaves the build broken "to be fixed in the next commit" has destroyed the bisect property that the
one-change-per-commit rule exists to create.

In scope for this step:

- Call sites the new version removed or renamed — the ones stage 3 located by name.
- Type errors introduced by new type definitions.
- Configuration schema changes (a config key renamed, a default changed, an option removed).
- Test updates where the *test* depended on old behaviour that legitimately changed. Be careful
  here: a test changed to accommodate an upgrade is either a correct adaptation or a silenced
  regression, and only reading the migration notes tells you which. Say which, in the commit body.
- Deprecation warnings the bump introduced: resolve them, or defer them explicitly with a written
  reason and a follow-up note. A step is not done while it emits new deprecations that nobody has
  looked at.

Out of scope for this step: anything the upgrade did not force. Unrelated refactors, drive-by
cleanups and style changes belong in their own commits, because they make the step's diff stop being
a readable answer to "what did this upgrade require".

### 3. Verify, against the baseline

Run the full suite plus every other gate that exists, not only the tests that seem related.

```bash
npm test
npm run typecheck 2>/dev/null || npx tsc --noEmit
npm run lint 2>/dev/null
npm run build 2>/dev/null

pytest && mypy . && ruff check .
go build ./... && go vet ./... && go test ./...
cargo build && cargo clippy -- -D warnings && cargo test
terraform validate && terraform fmt -check -recursive && terraform plan -detailed-exitcode
```

Then **diff against the baseline**, which is the step people skip and the reason upgrades get
blamed for failures they did not cause:

```bash
npm test > .upgrade-step-N.txt 2>&1; echo "exit:$?" >> .upgrade-step-N.txt
diff .upgrade-baseline.txt .upgrade-step-N.txt
```

Three possible readings, and they are not interchangeable:

| Result | Reading |
| --- | --- |
| Same failures as baseline, no new ones | The step is clean. Pre-existing failures stay pre-existing; do not fix them here. |
| New failures | The step caused them. Go to the failure procedure. |
| Baseline failures now passing | Note it, do not celebrate it. It is usually real, occasionally it means a test stopped running. Confirm the test count did not drop. |

For a Terraform step, `terraform plan` producing a non-empty diff **when no configuration changed**
is a finding in its own right: a provider upgrade that wants to modify live infrastructure has to be
read line by line before anything is applied. `-detailed-exitcode` returns 2 for a non-empty plan,
which makes this mechanically detectable rather than a matter of noticing.

### 4. Commit, alone

One step, one commit. The message says what moved and why, and names the code changes the upgrade
forced.

```bash
git add <manifest> <lockfile> <changed source files>
git commit
```

Follow the repository's commit conventions (`dev-standards` carries `commit-standards` for the
house format). The body should carry the version transition, the ladder reason, and any test
modification with its justification, so that a future bisect lands on a commit that explains itself.

Do not batch two steps into one commit because they both passed. The value of the separate commit is
realised later, when something breaks in production and `git bisect` has to find it.

### 5. Next step

Re-read the plan before continuing. A completed step can change what the next one needs — a lockfile
regeneration may have moved transitives that a later step was going to move, and that later step
might now be a no-op or might now conflict. Verify the next step is still the right change before
applying it.

## When a step fails

A failing step is information, not a crisis, and it must not take the rest of the plan with it.

1. **Revert that step alone.** Not the whole branch.

   ```bash
   git checkout -- <manifest> <lockfile>     # if uncommitted
   git revert --no-edit <sha>                # if committed
   npm install                               # restore the tree to the reverted lockfile
   ```

2. **Re-verify the baseline** after the revert, to confirm the revert actually restored the previous
   state rather than leaving a half-reverted tree.

3. **Record why**, concretely: the failing test names, the error, and the likely cause. "Step 4
   failed" is not a record; "Step 4 (`redis` 4 to 5) failed: connection options moved from the
   constructor to an options object; 11 tests in `test/cache.spec.ts` fail with
   `TypeError: invalid options`" is one a person can act on.

4. **Continue with the independent steps.** Steps the plan marked independent of the failed one are
   unaffected. Skip steps the plan marked blocked on it, and say so.

5. **Report the blocked one** in the final report, with what it would take to unblock it.

Two things not to do:

- **Do not abandon the whole plan because one item failed.** Four of five upgrades landing is a
  materially better outcome than zero, and the failed one is now documented rather than unknown.
- **Do not force a failing step through.** No `--force`, no `--legacy-peer-deps`, no deleting the
  failing test, no `continue-on-error`, no skipping the suite to "come back to it". A step that
  cannot go green honestly is a blocked step, and blocked is a legitimate outcome.

## Stop conditions

Stop and return to the user — do not work around any of these.

| Condition | Why it stops execution |
| --- | --- |
| **The baseline is red** | Nothing can be validated. Every result afterwards is ambiguous between the upgrade and the pre-existing failure. Fix the baseline as its own change first, or get explicit agreement to proceed unverified. |
| **A step needs an unplanned major bump** | The resolver demanding a major that stage 3 did not analyse means the breaking changes have not been located in this codebase. Go back to stage 3 for that row. |
| **A deployment-pinned runtime would change without approval** | A Lambda runtime identifier, a Kubernetes version, a Terraform Cloud CLI pin, a base image tag. These change what deploys, and a broken deployment is worse than an outdated one. The ceiling is the user's to move, not the executor's. |
| **`terraform plan` proposes infrastructure changes** nobody asked for | A provider upgrade that wants to replace resources needs a human read before apply. |
| **The lockfile will not resolve** without a force flag | See above: a forced tree is not a reproducible tree. |
| **A step would need the suite disabled or a test deleted** to pass | That is the suite doing its job. |

## The final report

Three sections, in this order. The second and third are the ones that carry the value.

**What moved.** Per completed step: the version transition, the commit SHA, the code changes the
upgrade forced, and the verification result against the baseline.

| Step | Change | Commit | Code changes required | Verified |
| --- | --- | --- | --- | --- |
| 1 | terraform 1.7.5 to 1.9.8 | `a1b2c3d` | none | validate + plan clean |
| 2 | hashicorp/aws 5.40 to 5.62 | `d4e5f6a` | none | plan empty; lock relocked for 3 platforms |
| 3 | node 20.11 to 22.11 (`.nvmrc`, `engines`, CI, Dockerfile) | `7a8b9c0` | `@types/node` to 22.x; two `fs` promise call sites | suite green, matches baseline |

**What did not move, and why.** Blocked steps with their cause and what would unblock them; steps
skipped because they were blocked on a failure; rows deliberately deferred by the plan. A blocked
step that is reported is a known issue; one that is omitted is a surprise later.

**What remains unverified.** Every step the adequacy gate marked unverifiable, every step whose
suite does not actually exercise the upgraded dependency, and anything only checked by a build
rather than by a test. This section exists so that nobody reads "upgraded and tests pass" as
"upgraded and verified" when those are different claims.

Close with the state of the branch, the baseline file's disposition (deleted, or kept for the
reviewer), and whatever still needs a human: a deployment-pinned runtime awaiting approval, a
`terraform plan` diff awaiting a read, a deferred deprecation with its reason.
