---
name: session-sync
license: MIT
description: "Bring every worktree of the current repository current with its base branch without ever force-pushing. Picks the safe route per branch from that branch's actual state: fast-forward the base checkout, rebase locally only where the branch was never pushed, ask the forge to rebase server-side where a pull or merge request is open, and leave alone anything where being behind is harmless. Skips dirty worktrees, refuses to discard local-only commits, and hands back one copy-pasteable command on a conflict rather than resolving it silently. Output is a per-worktree table: current, ff-only, rebased-local, rebased-server, skipped-dirty, conflict, no-request. Forge-neutral: the server-side step names the capability it needs and the installed forge adapter owns the command. Use when a session-start hook reports the checkout is behind the base, or when feature branches have drifted."
when_to_use: "sync my worktrees, I am behind main, bring my branches up to date, rebase my feature branches, my branches have drifted, behind origin/main, catch everything up to the base branch"
user-invocable: true
disable-model-invocation: true
allowed-tools: Read, Glob, Bash(git fetch:*), Bash(git worktree list:*), Bash(git rev-list:*), Bash(git rev-parse:*), Bash(git diff:*), Bash(git config --get:*), Bash(git symbolic-ref:*), Bash(git show-ref:*), Bash(git pull --ff-only:*), Bash(git rebase:*), Bash(git reset --hard origin/:*)
---

# Session sync

Bring every worktree of the current repository current with `origin/<base>` **without a single
force push**. This is the remediation for a session-start hook reporting `BEHIND origin/<base>`, and
for the slow drift that accumulates across a handful of long-lived feature worktrees.

The safety thesis is the whole point. The obvious implementation rebases every clean worktree
locally and then force-pushes the results, and it is wrong for one specific reason: a bulk sweep is
the worst possible place to rewrite remote branches. You are operating on branches you are not
thinking about, several at a time, and a single bad lease damages one you had no intention of
touching. So the route table below branches on *how a branch is published*, and picks the route that
needs no local rewrite wherever one exists.

The sibling `dev-guardrails` plugin blocks force pushes to protected branches with a pre-bash hook,
independently of this skill. The two agree by design and neither relies on the other: the hook is a
mechanical backstop against a command that slips through, and this skill simply never issues one.

## Guarantees

- **Never force-pushes.** Not with `--force`, not with `--force-with-lease`. Where a rewrite of a
  published branch is needed, it is requested from the forge, which rewrites the branch with its own
  push permission.
- **Never touches a dirty worktree.** Uncommitted work is left exactly as it is and reported.
- **Never destroys local-only commits.** `git reset --hard origin/<branch>` runs only after
  confirming both that the worktree is clean and that the branch is zero commits ahead of its
  remote. Failing to establish either fact is treated as "do not touch", never as "probably fine".
- **Never leaves you mid-conflict.** A conflicting rebase is aborted and you get one command to run
  yourself.
- **Never rebases onto the wrong base.** Before computing the base for a worktree, read
  `git -C <worktree> config --get branch.<branch>.releasetrainbase`. When that key is set, its value
  *is* the base for that worktree and the repository default is not. A `release-train` worker branch
  is cut from `release/<slug>` and merges back into it; rebasing it onto the default branch pulls in
  commits it was never cut from and conflicts against work no other worker has seen. This sweep
  enumerates worktrees mechanically, so it picks such worktrees up automatically and would otherwise
  do exactly that. Ordinary branches have no such key and are unaffected.

## The route depends on how the branch is published

| Worktree state | Route | Why |
| --- | --- | --- |
| On the base branch | `git pull --ff-only origin <base>` | The only branch that should ever fast-forward. `--ff-only` refuses to invent a merge commit. |
| Behind-count is `0` | nothing — `current` | Already up to date. |
| Behind-count indeterminate | nothing — `unknown` | A missing `origin/<base>` ref is not the same fact as "up to date". Report it; never guess. |
| Dirty working tree | nothing — `skipped-dirty` | Rebasing over uncommitted work risks it. |
| Never pushed | local `git rebase origin/<base>` | There is nothing on the remote to rewrite, so no force push can ever be needed. This is the safe local case. |
| Pushed, request open | server-side rebase — `rebased-server` | The forge rewrites the source branch with its own permission. No local force push. |
| Pushed, no request open | nothing — `no-request` | Nothing to rebase against yet. Open the request; most forges rebase at merge time anyway. |
| Pushed, ahead of its remote | nothing — `unpushed-commits` | A server-side rebase plus a local resync would discard them. Push first, then re-run. |

## The server-side step is a capability, not a command

Everything above except one row is plain `git`, fully specified below. The `rebased-server` row is
not, and this skill deliberately does not spell it.

**The capability required:** ask the forge to rebase the open request's source branch onto its
target, using the forge's own push permission, and report whether that rebase succeeded, is still
running, or hit conflicts.

`claude-craft` is a vendor-neutral plugin and depends on no forge CLI. The concrete command belongs
to whichever forge adapter is installed — on GitHub that is `github-workflow`, whose `pr-lifecycle`
skill owns the pull request surface including bringing a branch up to date with its base. Ask that
adapter for the spelling rather than assuming one here, and confirm two things about whatever it
returns before marking `rebased-server`:

- that the operation **rebased** the branch rather than merging the base into it, since a merge
  leaves the branch still behind by the measure this skill reports on;
- that it completed. Several forges enqueue the rebase and return immediately, so the adapter is
  also responsible for polling to a definite outcome, with a cap, rather than reporting success on
  the acknowledgement.

**If no forge adapter is installed, that row reports `no-adapter` and stops.** It does not fall back
to a local rebase plus a force push. That fallback is precisely the behaviour this skill exists to
avoid, and a missing adapter is a named gap rather than a reason to take the unsafe route.

## Procedure

1. **Resolve the base branch.** Ask the remote first: a repository whose default is `develop` or
   `trunk` has no local `main`, and a local-ref probe silently answers "none".

   ```sh
   git symbolic-ref --quiet refs/remotes/origin/HEAD    # -> refs/remotes/origin/<base>
   ```

   Strip the `refs/remotes/origin/` prefix. If it is unset, fall back to `main`, then `master`:

   ```sh
   git show-ref --verify --quiet refs/heads/main && echo main \
     || (git show-ref --verify --quiet refs/heads/master && echo master) \
     || echo NONE
   ```

   On `NONE`, stop and report that no base branch could be resolved. Do not pick one.

2. **Fetch once** — the only unavoidable network call:

   ```sh
   git fetch origin --prune
   ```

3. **Fast-forward the base checkout.** Find the worktree whose branch is the base and run:

   ```sh
   git -C "<base-worktree>" pull --ff-only origin <base>
   ```

   If this fails, say so loudly and do not work around it. `--ff-only` refuses only when the local
   base has commits of its own — commits that were never meant to be there. Report that as a
   finding. Never fall back to a plain `git pull`, which quietly creates a merge commit, and never
   to `reset --hard`.

4. **Enumerate the other worktrees:**

   ```sh
   git worktree list --porcelain
   ```

   Parse the `worktree <path>` and `branch refs/heads/<name>` pairs. Skip the base checkout, handled
   in step 3, and skip any detached-HEAD entry.

5. **For each worktree, gather every fact before deciding anything.** Deciding from a partial
   picture is how a route gets chosen that the next fact would have forbidden.

   ```sh
   git -C "<path>" config --get "branch.<branch>.releasetrainbase"        # base override, if any
   git -C "<path>" rev-list --count HEAD..origin/<base>                   # behind; error = unknown
   git -C "<path>" diff --quiet && git -C "<path>" diff --cached --quiet  # clean?
   git -C "<path>" rev-parse --verify --quiet origin/<branch>             # published?
   git -C "<path>" rev-list --count origin/<branch>..HEAD                 # ahead of its remote
   ```

   Then apply the route table:

   - **behind is 0** — `current`. Nothing else runs.
   - **behind is indeterminate** (that `rev-list` errored) — `unknown`. Do not read it as 0.
   - **dirty** — `skipped-dirty`. Print the manual path, do not run it:

     ```sh
     git -C "<path>" stash && git -C "<path>" rebase origin/<base> && git -C "<path>" stash pop
     ```

   - **not published** (`origin/<branch>` does not resolve) — local rebase, abort on conflict:

     ```sh
     git -C "<path>" rebase origin/<base> || git -C "<path>" rebase --abort
     ```

     Success is `rebased-local`. An abort is `conflict`, handled in step 7.

   - **published and ahead** (`origin/<branch>..HEAD` is greater than 0) — `unpushed-commits`. Stop
     for this worktree: the resync in step 6 would throw those commits away.
   - **published and fully in sync** — the server-side route, step 6.

6. **Server-side rebase.** Ask the installed forge adapter for the capability described above,
   passing the branch name. Three outcomes:

   - **No open request for the branch** — `no-request`. Skip it.
   - **Rebase completed** — resync the local worktree to the branch the forge just rewrote, and mark
     `rebased-server`:

     ```sh
     git -C "<path>" fetch origin && git -C "<path>" reset --hard origin/<branch>
     ```

     The preconditions for that `reset --hard` were established in step 5 — clean tree, zero commits
     ahead. Do not run it on a worktree that failed either check.

   - **Rebase reported conflicts, or the forge declined for lack of push permission on the source
     branch** — record `conflict` or `no-permission` and go to step 7. Do not substitute a local
     rebase and a force push.

7. **Conflicts are handed back, not resolved silently.** For a conflicting rebase, local or
   server-side, print exactly one line for the user to run and stop touching that worktree:

   ```text
   cd <path> && git rebase origin/<base>   # resolve, then: git rebase --continue
   ```

   If the branch was already published, the follow-up push after a hand-resolved rebase does need a
   force. This skill prints that as text and does not run it, because the sweep may be partway
   through several worktrees and rewriting a remote branch is not the sweep's job. In a focused
   single-branch session it is a reasonable thing to run deliberately, after a fresh `git fetch` —
   a lease only protects against commits you have not yet fetched.

8. **Print one row per worktree.**

   | Worktree (branch) | Behind | Result |
   | --- | --- | --- |
   | `main` | 3 | ff-only |
   | `feature/payments-retry` | 4 | rebased-server |
   | `feature/config-loader` | 2 | rebased-local (never pushed) |
   | `feature/search-index` | 2 | skipped-dirty |
   | `feature/auth-tokens` | 6 | conflict — command printed above |
   | `feature/docs-nav` | 1 | no-request — open a request first |
   | `release/q3-refactor-api` | 0 | current (release-train base) |

## Notes

- Only worktrees of the **current** repository. Run from anywhere inside it.
- Being behind the base is not an error and does not block a push. Where the forge rebases onto the
  latest base at merge time, `current` and `no-request` rows usually need no action at all.
- Syncing a branch is not marking it ready. Never clear a draft flag on a request as part of this.
- The route table is about blast radius, not about what is permitted. `dev-guardrails` allows a
  lease push off a protected branch; this skill still does not take it during a sweep.

## Surface

Claude Code only. It enumerates worktrees from disk and runs `git`, and Cowork has neither a
checkout nor a shell. There is no pasted-configuration fallback, because the input is the state of
the working trees themselves.
