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
# It also holds the other things both entry points must agree on: argument-value checking, base-ref
# resolution, the generated-file list, and how the changed-file list is built.
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

# need_value <flag> <remaining-argc> [<value>] — for a `case` arm that does `shift 2`.
#
# Without this, a value flag given LAST (`--base` with nothing after it) hangs the script: `shift 2`
# with one argument left fails WITHOUT shifting, these scripts deliberately run without `set -e`, and
# the `while [ $# -gt 0 ]` loop sees the same `--base` forever. A value that is itself a flag
# (`--base --out x`) is refused too, because it is always a forgotten value, never a ref.
# Usage:  --base) need_value "$1" $# "${2-}"; BASE="$2"; shift 2 ;;
need_value() {
  if [ "$2" -lt 2 ]; then
    printf '%s needs a value (try --help)\n' "$1" >&2
    exit 2
  fi
  case "${3-}" in
    --*) printf '%s needs a value, got the flag %s (try --help)\n' "$1" "$3" >&2; exit 2 ;;
  esac
}

# resolve_base <given> — print the base ref to diff against, or explain and return 1.
#
# An EXPLICIT --base is authoritative: CI passes a merge-base SHA, and silently substituting a
# different base would review a different change. It must resolve or the run stops.
#
# With no --base, try the remote's own default branch first (origin/HEAD, which is what `git clone`
# records), then the two conventional names. The error names every ref tried and any local branch
# that could be passed instead, so the reader knows what to type next rather than what went wrong.
resolve_base() {
  local given="${1-}" cand tried="" local_hint="" b
  if [ -n "$given" ]; then
    if git rev-parse --verify --quiet "$given^{commit}" >/dev/null; then
      printf '%s\n' "$given"
      return 0
    fi
    printf "base ref '%s' does not resolve. Pass a branch or SHA that exists, or omit --base to try origin/HEAD, origin/main and origin/master in turn.\n" "$given" >&2
    return 1
  fi
  for cand in origin/HEAD origin/main origin/master; do
    tried="$tried $cand"
    if git rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then
      # origin/HEAD is a symref; name the branch it points at so reports read `origin/main`.
      if [ "$cand" = "origin/HEAD" ]; then
        b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && cand="$b"
      fi
      printf '%s\n' "$cand"
      return 0
    fi
  done
  for b in main master trunk develop; do
    git rev-parse --verify --quiet "refs/heads/$b" >/dev/null && local_hint="$local_hint --base $b,"
  done
  local_hint="${local_hint%,}"
  printf 'no base ref given and none found (tried:%s). Pass --base <branch-or-sha>%s.\n' \
    "$tried" "${local_hint:+ — local candidates:$local_hint}" >&2
  return 1
}

# The ONE list of generated / vendored paths that are never linted or shown to a reviewer. Both entry
# points read it from here; it used to be restated in each and had drifted (one had the Cargo, Gemfile,
# composer and `.sum` entries, the other did not, under a comment claiming they were identical).
#
# Anchored on purpose. The old unanchored `build/` also matched `src/prebuild/x.py` and `vendor/` matched
# `myvendor/`, so real source vanished from the review. Directory names must be a whole path segment;
# lockfiles must be the whole basename.
#
# `\.sum$` covers go.sum and atlas.sum: a real scan once reported a gitleaks BLOCKER on an atlas
# migration checksum. Checksum and lock files are generated high-entropy blobs, which is exactly what a
# secret scanner is built to flag.
GENERATED_PATH_RE='(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|uv\.lock|Cargo\.lock|Gemfile\.lock|composer\.lock|\.terraform\.lock\.hcl)$|(^|/)(dist|build|node_modules|__pycache__|vendor)/|\.min\.(js|css)$|\.generated\.|\.pb\.go$|\.snap$|\.sum$'

# drop_generated <in-list> <out-list> — copy the list without generated paths.
drop_generated() {
  grep -vE "$GENERATED_PATH_RE" < "$1" > "$2" || : > "$2"
}

# list_changed <range> <out-list> <unlisted-out> [<diff-filter>] — the changed files in <range>, one
# per line. <diff-filter> defaults to ACMR; pass D for the deleted files.
#
# `-z` plus `core.quotePath=false`, because the default output C-quotes any non-ASCII name
# (`café.py` arrives as `"caf\303\251.py"`), `[ -f ]` then fails on the quoted string, and the file is
# silently never scanned. The detector contract is a newline-separated list, so a name that itself
# contains a newline cannot be carried in it: those are written to <unlisted-out> so the caller can
# record them as unscanned instead of dropping them quietly. ACMR by default: a deleted file cannot be
# linted. Deletions are listed separately (filter D) because they still break consumers and still
# belong in the diff a reviewer reads.
list_changed() {
  git -c core.quotePath=false diff --name-only -z --diff-filter="${4:-ACMR}" "$1" > "$2.z" || {
    rm -f "$2.z"
    return 1
  }
  python3 - "$2.z" "$2" "$3" <<'PY'
import sys
names = [n for n in open(sys.argv[1], "rb").read().split(b"\0") if n]
with open(sys.argv[2], "wb") as ok, open(sys.argv[3], "wb") as bad:
    for n in names:
        if b"\n" in n:
            bad.write(n.replace(b"\n", b"\\n") + b"\n")
        else:
            ok.write(n + b"\n")
PY
  local rc=$?
  rm -f "$2.z"
  return "$rc"
}
