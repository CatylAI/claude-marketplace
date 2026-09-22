#!/usr/bin/env bash
# _lib.sh — invariants shared by the pipeline's entry-point scripts.
#
# WHY THIS FILE EXISTS. `review-scan.sh` and `prepare-context.sh` are separate entry points that both
# create an artifact directory and fence it with a `.gitignore` containing `*`. The guard protecting
# that fence was written into both, verbatim, comment and all — in a change whose entire thesis is
# that a restated invariant drifts. The objective review said so, and it was right: a security check
# duplicated across two files is two things to keep correct.
#
# Sourced, not re-implemented. Both scripts resolve `$SELF_DIR` already, so this costs a `.` and
# nothing else. A missing or unreadable lib is a HARD FAILURE at both call sites rather than a
# silently-skipped guard — that distinction is the whole reason to extract it.
#
# Portable bash 3.2+ / zsh, like its callers.

# require_safe_out <out-dir> — reject the TYPO-SHAPED --out values, and only those.
#
# SCOPE, stated precisely because the previous wording ("refuse an --out value that must never receive
# a `*` .gitignore") promised a general safety property this does not provide. What it actually
# rejects is the empty string, `.`, `./`, `/`, and any value containing `..`. Every OTHER value passes,
# including an existing directory that would be a terrible choice: `--out src` is accepted and gets a
# repo-ignoring `*` fence. That is tolerable only because every caller passes a fixed literal
# (`.code-review`, `.orchestration`) — so treat this as a typo guard, not as validation you may rely on
# when adding a caller that takes `--out` from user input.
#
# The hazard it does cover: the fence writes a `.gitignore` containing `*` into whatever `--out`
# names, and `*` at a REPO ROOT makes git ignore the entire working tree. `--out .` or `--out ""` is a
# typo, not a use case, and that blast radius is bad enough that refusing is cheaper than trusting.
#
# An ABSOLUTE --out is deliberately NOT restricted to the repo. That check was written and removed:
# `$REPO_ROOT` comes from `git rev-parse --show-toplevel`, which returns the RESOLVED path, so on
# macOS (where /var is a symlink to /private/var) a caller passing a perfectly valid
# "$TMPDIR/repo/.code-review" was refused by the string prefix comparison. Comparing resolved paths
# would fix that, and it is not worth it: the hazard this guard exists for is a `*` fence at a repo
# root blinding the whole tree, which the cases below catch. A stray `.gitignore` in a temp directory
# is noise, not a repo-blinding write, and a fragile guard on the path every review takes is worse
# than the thing it prevents.
#
# Writes to stderr and returns 1; the caller decides how to exit (each has its own `die`).
require_safe_out() {
  case "${1-}" in
    ""|"."|"./"|"/")
      printf 'refusing --out %s: it must name a subdirectory, because a "*" fence there would make git ignore the whole tree\n' \
        "'${1-}'" >&2
      return 1 ;;
    *..*)
      printf "refusing --out '%s': it must not traverse upward\\n" "$1" >&2
      return 1 ;;
  esac
  return 0
}
