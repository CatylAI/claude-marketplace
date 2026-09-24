#!/usr/bin/env bash
# impact.sh — changed exported symbols → consumers elsewhere in the repo.
#
# This is the detector that replaces the `review-impact` agent, which was doing whole-tree
# `grep -rn` sweeps from inside an LLM at sonnet prices. The work is pure text mechanics: pull
# definition lines out of the diff, ask `git grep` who references them, emit a bounded consumer
# list. `mypy` already catches signature breakage where types exist; this catches the rest, and its
# findings are NIT — a shortlist for the semantic agent to judge, never a verdict of its own.
#
# Needs the diff refs, which are not part of the standard detector argv, so review-scan.sh exports
# SCAN_BASE and SCAN_SOURCE. Absent those it skips rather than guessing a base.
#
# Detector contract: see _lib.sh. Always exits 0.

set -uo pipefail

LIST="${1:?changed-files list required}"
OUT="${2:?outdir required}"
RAW="$OUT/raw"
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib.sh"

mkdir -p "$RAW"

if [ -z "${SCAN_BASE:-}" ]; then
  skip "impact" "SCAN_BASE not set (review-scan.sh exports it; the detector will not guess a base)"
  exit 0
fi

SRC="$RAW/.impact-files"
filter_ext "$LIST" .py .ts .tsx .js .jsx .mjs .tf .sh .bash .zsh > "$SRC"
# Deleted files too (review-scan.sh lists them in SCAN_DELETED). Every definition in a deleted file is
# removed, and a removed definition with consumers is the break this detector exists to report.
if [ -n "${SCAN_DELETED:-}" ] && [ -f "$SCAN_DELETED" ]; then
  # Not filter_ext: it skips paths missing from disk, which is every deleted file.
  grep -E '\.(py|ts|tsx|js|jsx|mjs|tf|sh|bash|zsh)$' "$SCAN_DELETED" >> "$SRC" || :
fi

if ! any_lines "$SRC"; then
  skip "impact" "no files with extractable symbols in the diff"
  exit 0
fi

if ! python3 - "$SRC" "$RAW/impact.json" "$SCAN_BASE" "${SCAN_SOURCE:-}" <<'PY'
"""Extract changed definitions from the diff, then find their consumers with `git grep`.

Two bounds keep this cheap and keep the output reviewable:
  MAX_SYMBOLS  — most-referenced-first is not knowable before grepping, so cap the symbol count and
                 record the drop rather than fanning out over a 500-file refactor.
  MAX_CONSUMERS— a symbol referenced in 200 files is a fact about the codebase, not a review
                 finding; the count is what matters and the list is truncated.

MIN_NAME_LEN exists because `git grep -w run` matches half the repo. Short names carry no signal at
this level of analysis, so they are dropped instead of producing findings nobody can act on.
"""
import json, os, re, subprocess, sys

src_path, out_path, base, source = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# 40 symbols x one `git grep` each keeps the detector to seconds on a large repo; 20 consumer paths
# is a list a reviewer will actually read; 4 characters is the shortest name that is usually an
# identifier rather than a common word (`run`, `get`, `id` match half of any repo).
MAX_SYMBOLS, MAX_CONSUMERS, MIN_NAME_LEN = 40, 20, 4
# Seconds. A diff or grep that runs longer than this is on a repo too large for this cheap pass;
# the detector records nothing for it rather than stalling the whole scan.
DIFF_TIMEOUT, GREP_TIMEOUT = 120, 60
# quotePath=false: a non-ASCII path must match the changed-file list byte for byte, and git's
# default C-quoting (`"caf\303\251.py"`) never would. Literal pathspecs: `[ab].py` is a name.
GIT = ["git", "-c", "core.quotePath=false", "--literal-pathspecs"]

# A symbol referenced in more than this many files is not a symbol with consumers, it is a common
# word. Measured on a real diff: `main` came back with 68 "consumers", `pass` with 53, `fail` with
# 38 — every one a `git grep -w` hit on an unrelated definition or a comment. Reporting that LIST
# buries the two or three findings that mean something, so above the threshold the list is thrown
# away. This is a cheap stand-in for real reference resolution; when a symbol is genuinely used in 60
# files, the reviewer needs an import graph, not a twenty-path shortlist.
#
# 3.0.0: the COUNT is kept even so, as a count-only finding. It used to drop with the list, which
# meant the widest blast radius in the diff was the one thing the reviewer never saw: a symbol with
# 60 consumers scored the same as a symbol with none. A count-only finding says "this is big and the
# list is not trustworthy", which is exactly what the semantic pass needs to decide whether to spend
# a read on it.
GENERIC_CONSUMER_LIMIT = 25
# These are never meaningful as "changed exports" no matter what the consumer count says: they are
# entry points and test-harness scaffolding that every file in the repo defines for itself.
STOPLIST = {"main", "pass", "fail", "setup", "teardown", "usage", "test", "init"}

files = [l.strip() for l in open(src_path).read().splitlines() if l.strip()]

# Definition patterns per extension. Anchored at the start of the (de-prefixed) diff line so a
# mention inside a call or a string does not register as a definition.
PATTERNS = {
    ".py": [re.compile(r"^\s*(?:async\s+)?def\s+(\w+)"), re.compile(r"^\s*class\s+(\w+)")],
    # variable / output / module ONLY. `resource "aws_s3_bucket" "logs"` has the TYPE in the first
    # quoted string, so matching it greps for `aws_s3_bucket` and "finds consumers" in every file
    # that happens to use that resource type — 20 meaningless NIT findings on the terraform
    # benchmark case. Variables, outputs and module names are the real cross-file interface, and
    # they are referenced by the name this captures.
    ".tf": [re.compile(r'^\s*(?:output|variable|module)\s+"([^"]+)"')],
    ".sh": [re.compile(r"^\s*(?:function\s+)?(\w+)\s*\(\)\s*\{?"), ],
}
for e in (".ts", ".tsx", ".js", ".jsx", ".mjs"):
    PATTERNS[e] = [
        re.compile(r"^\s*export\s+(?:default\s+)?(?:async\s+)?function\s+(\w+)"),
        re.compile(r"^\s*export\s+(?:const|let|var|class|type|interface|enum)\s+(\w+)"),
        re.compile(r"^\s*export\s+\{\s*([\w, ]+?)\s*\}"),
    ]
for e in (".bash", ".zsh"):
    PATTERNS[e] = PATTERNS[".sh"]

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def diff(*args):
    try:
        return subprocess.run(GIT + ["diff", "--no-color", "-U0"] + list(args),
                              capture_output=True, text=True, timeout=DIFF_TIMEOUT).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


rng = f"{base}...{source}" if source else base
# One `git diff` per batch of files, not one per file: the whole point of this detector is that it
# costs a couple of subprocesses rather than a fan-out. Batched because a 900-file diff would blow
# past ARG_MAX and `git diff` would fail wholesale rather than degrade.
text = "".join(diff(rng, "--", *files[i:i + 200]) for i in range(0, len(files), 200))

# symbol -> (defining path, new-side line). First sighting wins; a symbol defined in two changed
# files is reported once against the first, which is enough to trigger the consumer check.
#
# `added` and `removed` are tracked separately because they mean completely different things:
#   only in removed  -> the definition is gone (deleted or renamed) and every consumer breaks
#   in both          -> the definition line changed, i.e. a signature change; consumers may break
#   only in added    -> brand new. NOTHING outside the diff can be consuming it yet, so a grep hit
#                       is either inside the diff or a coincidental word match.
# Reporting the added-only case is what produced 16 useless NIT findings on the terraform benchmark
# case, where the change added a whole new module and every one of its variables was "changed with
# consumers". Only removed/changed symbols get a consumer search.
symbols, added, removed, dropped_short, path, old_path = {}, set(), set(), 0, None, None
new_line = 0
for line in text.splitlines():
    # git appends a TAB to the ---/+++ name when the path contains a space; it is not part of the
    # name. A deleted file has `+++ /dev/null`, so its path comes from the `--- a/` line; before,
    # the previous file's path carried over and the deletion was attributed to the wrong file.
    if line.startswith("diff --git"):
        path = old_path = None
        continue
    if line.startswith("--- a/"):
        old_path = line[6:].rstrip("\t")
        continue
    if line.startswith("+++ b/"):
        path = line[6:].rstrip("\t")
        continue
    if line.startswith("+++ /dev/null"):
        path = old_path
        continue
    if line.startswith("--- "):
        continue
    m = HUNK.match(line)
    if m:
        new_line = int(m.group(1))
        continue
    if not path:
        continue
    ext = os.path.splitext(path)[1]
    pats = PATTERNS.get(ext)
    if not pats:
        continue
    if line.startswith("+") or line.startswith("-"):
        body = line[1:]
        for p in pats:
            m = p.match(body)
            if not m:
                continue
            for name in (n.strip() for n in m.group(1).split(",")):
                # A leading underscore means module-private by convention in every language here;
                # a consumer outside the module is then a separate problem from this one.
                if not name or name.startswith("_"):
                    continue
                if len(name) < MIN_NAME_LEN:
                    dropped_short += 1
                    continue
                # Anchor on the hunk's new-side start line. For an ADDED definition that is the
                # definition itself; for a REMOVED one there is no new-side line at all, and the
                # hunk start is the line git says the deletion follows (0 at the top of the file,
                # clamped to 1). filter-carried-findings.py treats exactly that line as changed for
                # a pure-deletion hunk, so the deletion of a still-referenced symbol survives
                # diff-scoping. It was dropped before that rule existed, the worst miss in the set.
                symbols.setdefault(name, (path, max(new_line, 1)))
                (added if line.startswith("+") else removed).add(name)
        if line.startswith("+"):
            new_line += 1

notes = []
# Removed-or-changed only. `removed` holds every symbol whose definition line disappeared, which
# covers both an outright deletion and a signature edit (the old line goes, a new one arrives).
names = sorted(removed)
new_only = len(added - removed)
if new_only:
    notes.append(f"{new_only} newly added definition(s) not checked for consumers — nothing outside "
                 "the diff can reference a name that did not exist before it")
if len(names) > MAX_SYMBOLS:
    notes.append(f"{len(names)} changed symbols found; consumer search limited to the first "
                 f"{MAX_SYMBOLS} (alphabetical)")
    names = names[:MAX_SYMBOLS]
if dropped_short:
    notes.append(f"{dropped_short} definition(s) skipped: name shorter than {MIN_NAME_LEN} chars "
                 "(a word-grep for those matches too much to be useful)")

changed = set(files)
findings, dropped_generic, count_only = [], [], []
for name in names:
    if name in STOPLIST:
        dropped_generic.append(name)
        continue
    path, line = symbols[name]
    try:
        r = subprocess.run(GIT + ["grep", "-l", "-w", "-F", "--", name],
                           capture_output=True, text=True, timeout=GREP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        continue
    # rc 1 = no match, which is normal and not an error. Anything else means git failed.
    if r.returncode not in (0, 1):
        continue
    consumers = [p for p in r.stdout.splitlines() if p and p not in changed]
    if not consumers:
        continue
    if len(consumers) > GENERIC_CONSUMER_LIMIT:
        # Count only: no `consumers`, because above the limit the list is mostly word-grep noise, and
        # a noisy list is what the limit exists to suppress. `consumer_count` still carries the size,
        # which is the part a reviewer can act on. STOPLIST names above still drop outright; their
        # counts are a fact about the language, not about this diff.
        findings.append({
            "path": path, "line": line, "symbol": name,
            "kind": "changed" if name in added else "removed",
            "consumers": [], "consumer_count": len(consumers), "count_only": True,
        })
        count_only.append(f"{name} ({len(consumers)})")
        continue
    findings.append({
        "path": path, "line": line, "symbol": name,
        "kind": "changed" if name in added else "removed",
        "consumers": sorted(consumers)[:MAX_CONSUMERS],
        "consumer_count": len(consumers),
    })

if dropped_generic:
    notes.append("entry-point / harness names that are never a real changed export, dropped: "
                 + ", ".join(sorted(dropped_generic)))
if count_only:
    notes.append(f"reported COUNT-ONLY, over the {GENERIC_CONSUMER_LIMIT}-consumer limit where a "
                 "word-grep list is mostly noise: " + ", ".join(sorted(count_only)))
json.dump({"findings": findings, "notes": notes}, open(out_path, "w"))
print(f"{len(findings)} symbol(s) with outside consumers", file=sys.stderr)
PY
then
  skip "impact" "symbol extraction failed"
  rm -f "$RAW/impact.json"
else
  note impact "ok"
fi

rm -f "$SRC" 2>/dev/null
exit 0
