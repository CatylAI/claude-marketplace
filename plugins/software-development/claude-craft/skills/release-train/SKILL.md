---
name: release-train
license: MIT
description: "Run a large change as an orchestrated release: one leader session supervising several named worker sessions, each in its own git worktree, all merging into a shared release branch per repository. The leader owns decomposition into provably disjoint work bundles, briefing, verification of every worker branch against its declared scope, merge order, and integration; workers commit, push, and stop. Forge-neutral — it converges branches with git and never opens a pull or merge request, which belongs to a forge plugin such as github-workflow. Use when a change spans many files or several repositories and would otherwise be one long serial session. Not for a single focused change, where the multi-agent token multiplier buys nothing; not for reviewing or shipping one branch."
when_to_use: "run this as a release, fan this out across repos, orchestrate this change, spin up workers for this, release train, coordinate several workstreams, parallelize this refactor. Also when a plan already has independent workstreams you can name out loud and their file sets do not overlap."
user-invocable: true
disable-model-invocation: true
argument-hint: "[release slug, or a short description of the change]"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(mkdir:*), Bash(mktemp:*), Bash(sort:*), Bash(comm:*), Agent, SendMessage, TaskStop, AskUserQuestion
---

# Release train

An orchestrated release. One leader session supervises a small set of named worker sessions, each
pinned to its own git worktree, all converging on one shared `release/<slug>` branch per repository.

This is the procedural counterpart to `agent-orchestration`. That skill supplies the doctrine —
when delegation earns its token multiplier, hub-and-spoke routing, decomposition as the owner of
coverage, complete context in the spawn prompt, review by a fresh instance. Read it first. This
file does not restate any of it; it specifies the mechanics that doctrine leaves open when the
delegated work **writes to a shared repository** instead of returning a report.

**The admission criterion is disjointness, not worker count.** If you cannot demonstrate that the
bundles touch non-overlapping sets of files, you do not have parallel work. You have one serial job
and a merge conflict scheduled for later.

## Forge neutrality

This skill converges branches with `git` and stops there. It does not open a pull request or a
merge request, does not read review state, and requires no forge CLI. Once the release branch is
green and integrated, opening and driving the request that lands it on the default branch belongs
to a forge plugin — `github-workflow` on GitHub. That boundary is deliberate: the orchestration
discipline below is identical on every forge, and mixing a provider API into it would make it
portable nowhere.

## When to run it, and when not

| Situation | Verdict |
| --- | --- |
| A change touching many files across areas you can name separately | Run it |
| A change spanning several repositories that must land together | Run it |
| One focused change, however large it feels | Decline; do it directly |
| Work where every bundle needs the same deep shared context | Decline; the briefing cost exceeds the fan-out saving |
| Bundles you cannot prove disjoint after two attempts at recutting | Decline; collapse to fewer, larger bundles |

Declining is a normal outcome and should be stated plainly, with the reason.

## 1. Decomposition, and proving the bundles disjoint

A **bundle** is the unit a worker owns. It carries a name, a repository root, an explicit list of
owned path globs, acceptance criteria phrased as observable facts, and any `depends_on` edges to
other bundles.

The leader writes the bundles, then *proves* the disjointness rather than eyeballing it. Comparing
globs as strings is the failure that looks like success: two globs where neither is a textual prefix
of the other can still select the same files.

```text
Bundle A owns:  services/*/config/**
Bundle B owns:  services/billing/**
```

Neither glob is a prefix of the other, so a string comparison calls them disjoint. They share every
file under `services/billing/config/`.

Expand each bundle to a concrete file set and intersect the sets:

```sh
WORK=$(mktemp -d)
git -C "$REPO" ls-files -- ':(glob)services/*/config/**' | sort > "$WORK/bundle-a"
git -C "$REPO" ls-files -- ':(glob)services/billing/**'  | sort > "$WORK/bundle-b"
comm -12 "$WORK/bundle-a" "$WORK/bundle-b"        # any output at all means not disjoint
```

The `:(glob)` pathspec magic is not decoration. Without it, git matches the pattern with its default
semantics, where a bare `*` also matches `/` — so an unmarked glob selects a wider set than the one
you wrote and the proof answers a question you did not ask. With `:(glob)`, `*` stops at a path
separator and `**` crosses one, which is what the bundle definition means.

Run the intersection for every pair, not just the pairs that look suspicious. Three bundles are
three pairs; five are ten. This is cheap, and it is the only check that actually answers the
question.

Two cases the intersection alone misses, and both have to be handled before dispatch:

- **Files that do not exist yet.** `git ls-files` sees tracked files only. A bundle that creates
  `services/billing/retry.ts` and a bundle that creates a file at the same path collide, and the
  expansion shows nothing. Each bundle declares its planned new paths alongside its globs, and those
  go into the same intersection.
- **Files every bundle needs.** A lockfile, a changelog, a central registry or barrel file, a
  generated index, a shared type module. These are the real source of release-train conflicts,
  because they are exactly the files no decomposition naturally separates. Two ways out, and no
  third: assign the file to **exactly one** bundle and have the other workers state their required
  change in their report for that owner to apply, or hoist it out of the fan-out entirely — the
  leader makes the shared edit once, before dispatch or after integration, in a single pass.

When a pair overlaps, the fix is to **merge them into one bundle**, not to give them separate
worktrees and hope. Worktree isolation prevents workers from seeing each other's uncommitted state;
it does nothing about two commits changing the same lines.

Keep the count small. Every additional worker adds a brief to write, a branch to verify, a merge to
order, and a share of the leader's finite attention. Six concurrent writers is a realistic ceiling
before supervision quality falls off; fewer is usually better.

## 2. A worktree per worker, not a branch per worker

Every worker gets `git worktree add` against a path of its own, with its branch cut from the shared
release branch. Not a branch in a shared checkout, and not a clone.

A shared checkout has exactly one HEAD and one working tree. Two agents working in it are two
processes contending for that single mutable state: one runs `git checkout` and the other's
in-flight edits land on the wrong branch, or its build reads half-swapped files. Nothing about
branches helps — the branch is a pointer, and the contention is over the tree. Separate worktrees
give each worker its own HEAD, index, and files, while sharing one object database and one refs
namespace, so the leader can inspect and merge every worker's branch from the base checkout without
a fetch.

Clones would also isolate, at the cost of a push-and-fetch round trip for every inspection and a
second copy of history per worker. Worktrees are strictly better here.

Three constraints on how the worktrees come into existence:

- **The leader creates every worktree before dispatch.** A worker that creates its own can put it
  anywhere, including inside another worker's.
- **Do not use the Agent tool's built-in worktree isolation for writer workers.** That mode
  provisions a throwaway worktree and reclaims it when the agent finishes, which would delete the
  checkout of a pushed-but-unintegrated branch. Workers enter a worktree the leader already made —
  in Claude Code, with the harness's worktree-entry tool, once.
- **One worker, one repository, one worktree, for the whole run.** Workers do not move between them.

Record the release branch on each worker branch so a later sweep cannot rebase it onto the wrong
base:

```sh
git -C "$WORKTREE" config "branch.$BRANCH.releasetrainbase" "release/$SLUG"
```

The `session-sync` skill reads that key and honours it. Without it, a repo-wide sweep rebases a
worker branch onto the default branch — pulling in commits it was never cut from and conflicting
against work no other worker has seen.

## 3. What the leader keeps, and what it delegates

The leader supervises. The moment it starts writing bundle code, it has spent the context it needs
to integrate, and the run degrades into one serial session with expensive observers attached.

| Leader keeps | Delegated to workers |
| --- | --- |
| Decomposition and the disjointness proof | Implementation inside one bundle |
| Creating the release branch and every worktree | Committing and pushing on their own branch |
| Writing each brief | Choosing how to satisfy the acceptance criteria |
| Verifying each branch against its declared scope | Reporting a short structured status |
| Merge order and conflict adjudication | Resolving conflicts in code they wrote |
| Cross-bundle integration and the final review | Nothing cross-bundle |
| The decision to stop, recut, or decline | Nothing about scope |

The one exception is the shared-file edit hoisted out of the fan-out in section 1. It is a single
small change the leader makes deliberately, not a bundle it quietly absorbed.

The brief is the entire budget. A worker's spawn prompt is the only channel into it, so it carries
the worker's identity, its owned paths, its acceptance criteria, the base it branched from, and the
procedure — and nothing else. Pasting a full plan, a prior handoff, or this file into a brief
inflates every worker's window with context it will never use and buries the part it must follow.

## 4. Bounded supervision

The leader's context window is the integration budget. Anything spent watching is not available for
merging, and a leader that runs out mid-integration cannot be rescued — it is the only session that
knows the shape of the whole change.

Four rules keep supervision from eating it:

- **Never poll in a tight loop.** Prefer the harness's completion notification. Where you must
  check, check on a bounded cadence with an explicit cap on the number of checks, and report a
  timeout rather than looping forever.
- **Never pull worker output into the leader's window.** Workers report a few lines of structured
  status. The ground truth is on disk, and `git log --oneline` and `git diff --stat` cost the leader
  a fraction of what reading a transcript costs.
- **Never block on a long-running command.** Tool calls have a wall-clock cap, and it applies to the
  call that launches the work. Start it, return, check later.
- **If the window is getting long before integration starts, the cut was wrong.** Too many bundles,
  or bundles too small to be worth a session. Stop, collapse them, and say so.

## 5. Verifying a worker, because its own report is not evidence

A worker reporting success is a claim about its intent. Check the branch.

```sh
git -C "$WORKTREE" log --oneline "release/$SLUG..$BRANCH"     # commits actually exist
git -C "$WORKTREE" diff --stat "release/$SLUG..$BRANCH"       # and are not empty
git -C "$WORKTREE" diff --name-only "release/$SLUG..$BRANCH"  # and stay inside owned paths
```

Three distinct failures hide behind one confident report, and only the branch distinguishes them:

| What you find | Verdict |
| --- | --- |
| No commits, or a diff that is entirely empty files | Reported done, produced nothing. Re-dispatch. |
| Changed files outside the bundle's owned paths | Scope violation. It may already conflict with another worker's branch, so adjudicate before any merge. |
| Work present, acceptance criteria not observably met | Send it back once with the specific unmet criterion. |

A scope violation found *after* the work is the same defect the disjointness proof prevents *before*
it. Finding one means the proof was run on the wrong globs, or the bundle grew during the run.

## 6. Integration

Merge into the release branch in dependency order first: any bundle another bundle declared
`depends_on` lands before its dependent. Among bundles with no edges between them, land the one
touching the widest surface first, so the remaining workers rebase onto the larger change rather
than the other way around.

Merge each branch **from the worker's own worktree**, so the worker that wrote the code is the one
that resolves anything that conflicts:

```sh
git -C "$WORKTREE" fetch origin
git -C "$WORKTREE" rebase "origin/release/$SLUG"   # resolve here, in the worktree that owns it
git -C "$WORKTREE" push origin "$BRANCH"
git -C "$BASE_CHECKOUT" merge --no-ff "$BRANCH"    # bookkeeping only; cannot conflict after the rebase
git -C "$BASE_CHECKOUT" push origin "release/$SLUG"
```

The split is the point. The rebase is where conflicts surface, and it runs in the worker's worktree
so the author resolves them. By the time the release checkout merges, the branch already sits on top
of the release tip, so the merge is pure bookkeeping and has nothing left to conflict over. If it
does conflict, someone pushed to the release branch between the rebase and the merge — re-run the
rebase rather than resolving it in the base checkout.

Confirm the release ref actually advanced afterwards. A merge that returned 0 and moved nothing is
an already-merged or empty branch, and is worth noticing.

If disjointness held, conflicts are structural rather than semantic: a lockfile, a generated index,
a changelog, an import barrel. Those resolve mechanically. **A semantic conflict is a decomposition
bug**, not a merge problem — the bundles overlapped and the proof missed it. Stop merging, record
which files collided, and recut rather than hand-resolving your way through a cut that was wrong.

The leader never resolves a conflict in code it did not write. It decides *who* resolves it.

## 7. When a worker fails or stalls

Define a stall before the run: no new commit and no status between two consecutive supervision
checks. Then the ladder is fixed, and it never ends in the leader absorbing the bundle silently.

1. Ask the worker directly, once, naming what you expected to see.
2. No useful answer — stop it. Keep its worktree and its branch; the partial work is committed or
   it is not, and either way the branch is the record.
3. Inspect the branch with the section 5 commands and decide: usable partial work, or nothing.
4. Re-dispatch a fresh worker with a brief that names exactly what already landed on that branch and
   what remains. Do not resume the stalled session — its window is the thing that failed.
5. If the same bundle fails twice, it is too large or under-specified. Split it or fold it into the
   leader's own serial work, and say which.

A failed bundle that no other bundle depends on does not stop the release. One that others depend on
does — land its dependents only after it is genuinely complete, never "around" it.

## Worked examples

<example>
Request: "Run the auth refactor as a release across the API service and the web client."

Correct: cut bundles per repository with declared owned paths; expand and intersect every pair, and
include the new files each bundle plans to create; create `release/auth-refactor` in both
repositories and one worktree per bundle off it; dispatch one named worker per bundle; supervise on
a bounded cadence; verify each branch against its owned paths; merge in dependency order from each
worker's own worktree; run an integration review with a fresh instance; hand the green release
branch to `github-workflow` to open the request that lands it.
</example>

<example>
Request: "Fix the typo in the retry-policy docs."

Correct: decline the fan-out and do it directly. One focused change has no independent subtasks to
name, so the multi-agent multiplier buys nothing. This is `agent-orchestration` rule 1, and the
right answer is a one-line edit.
</example>

<example>
Two bundles are proposed as `services/*/config/**` and `services/billing/**`.

The pairwise intersection returns 40-odd files under `services/billing/config/`. Neither glob is a
prefix of the other, so a string comparison would have called them disjoint.

Correct: merge them into one bundle. Wrong: give them separate worktrees and expect the merge to
sort it out — separate worktrees isolate working state, not commits.
</example>

<example>
A worker reports "done, all criteria met." `git diff --name-only release/x..branch` lists two files
outside its owned paths, one of which another worker also owns.

Correct: treat the bundle as unverified. Adjudicate the shared file to a single owner before any
merge, have the violating worker revert its half, and re-verify. Merging first and reconciling
afterwards is how a release train produces a branch nobody can explain.
</example>

## Failure modes

**Disjointness assumed from the glob strings.** The most common one, and it fails silently until the
second merge. The intersection is three commands.

**A leader that started coding.** It writes one "quick" bundle itself, then has neither the window
nor the neutrality to integrate the rest. Everything after that looks like worker failure.

**Tight-loop polling.** The leader spends its budget confirming that workers are still working, then
compacts mid-integration and loses the merge order it was holding.

**Worker reports treated as verification.** Three different failures — nothing produced, out of
scope, criteria unmet — all present as the same cheerful message.

**Agent-tool worktree isolation for a writer.** The worktree is reclaimed on completion and the
branch checkout disappears, sometimes before it was integrated.

**Hand-resolving a semantic conflict.** It merges, it builds, and the resulting behaviour is a blend
neither worker designed or reviewed. A semantic conflict means recut, not resolve.

## Surface

Claude Code only. This skill spawns subagents, creates worktrees, and runs `git` — none of which
exist in Cowork, where there is no checkout and no shell. There is no degraded mode: a release train
without workers is just a serial session, and you should run that deliberately rather than by
accident.
