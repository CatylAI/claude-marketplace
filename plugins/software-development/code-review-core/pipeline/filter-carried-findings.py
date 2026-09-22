#!/usr/bin/env python3
"""filter-carried-findings.py — drop findings whose cited line is no longer in the diff.

Invoked by `pipeline/review-scan.sh` (see its `FILTER=` assignment) to diff-scope SCAN.json. That is
the ONLY caller. This docstring used to add "and used again during Tier 1
carry-forward", describing a per-specialist skip that no longer exists (the 3.0.0 cutover deleted the
fan-out it gated) inside a cache arm that could never execute (since deleted).
Neither ever called this file.

The stale-line problem below is still real for the one live caller, and is the check any future
carry-forward would need: some findings reference a `file:line` that no longer exists in the
current-round diff — e.g. a refactor moved `foo()` from
`a.py:42` to `b.py:100`, so a prior finding on `a.py:42` is now stale (the same defect may or
may not still be present, but on a *different* line). Rather than post noise, drop those.

Semantics.
    For each finding in the input JSON:
      - Parse `location: "path[:linespec]"`. `linespec` may be a bare int (`87`), a range
        (`87-90` or `87–90` with an em-dash), or "path:LineX+" style — we only try to extract
        integers.
      - If no line component: KEEP (we can't line-check → conservative).
      - If path not in the diff at all (no `diff --git` block): DROP.
      - Else `git diff -U0 target source -- <path>` and inspect hunks:
          hunk header `@@ -a,b +c,d @@` covers new-side lines `[c, c+d-1]` (d defaults to 1
          when omitted). If ANY cited line intersects ANY hunk range: KEEP. Else: DROP.
      - Findings with `location` empty / unparseable: KEEP (we can't tell → conservative).
      - Findings with `in_diff: false` explicitly set by the specialist: KEEP (the specialist
        already reasoned about this — they're pointing at cross-cutting or extra-diff state).

Output.
    Writes filtered JSON to <out>. Prints a per-finding disposition line to stderr
    (`KEEP <id> <location>` / `DROP <id> <location> — reason`) and a summary count to stdout
    (`FILTER: <kept>/<total> kept, <dropped> dropped from <path>`).

Portable: python3 only. No external deps (uses `subprocess` for git). No network.

Also filters the sibling .md report when `--in-md` / `--out-md` are supplied: any dropped
finding-ID has its `## <ID> — ...` section (from the heading through the next `## ` heading or
the REVIEW-COMPLETE trailer) removed. If the section can't be located, the .md is copied
through unchanged and the disposition is logged; the .json filter is always authoritative.

Usage:
    filter-carried-findings.py \
        --in  .code-review/archive/<prev-sha>/RELIABILITY.json \
        --out .code-review/RELIABILITY.json \
        --target <target-ref> --source <source-ref> \
        [--in-md  .code-review/archive/<prev-sha>/RELIABILITY.md \
         --out-md .code-review/RELIABILITY.md]

    Both refs may be branch names or SHAs. Errors from git bubble up as exit 2 with the
    subprocess stderr; a missing `--in` exits 3.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Iterable

HUNK_RE = re.compile(r"^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@")
LOCATION_RE = re.compile(
    r"^(?P<path>[^\s:]+):(?P<lines>[\d\-–—−\s+,]+)"
)


def parse_line_spec(spec: str) -> list[int]:
    """Extract every integer mentioned in a line-spec string.

    Accepts `"42"`, `"87-90"`, `"87–90"` (en-dash), `"87—90"` (em-dash),
    `"12, 15, 22"`, `"12+"` (trailing modifiers stripped). Returns a list of ints; empty if
    nothing parseable — the caller then treats the finding as "no line component" and keeps.
    """
    return [int(m.group()) for m in re.finditer(r"\d+", spec)]


def parse_location(loc: str) -> tuple[str, list[int]]:
    """Return (path, [lines]). If no `:linespec` present, `[lines]` is [].

    A trailing colon with no digits (`path:`) or with only non-numeric text (`path:Step 3a`)
    returns [] — we can't line-check, keep.
    """
    if not loc:
        return "", []
    # Fast path: no colon → whole thing is a path.
    if ":" not in loc:
        return loc.strip(), []
    m = LOCATION_RE.match(loc.strip())
    if not m:
        # Colon present but not a clean `path:linespec` — split on FIRST colon, take LHS as
        # path and try to extract lines from the rest.
        path, _, rest = loc.partition(":")
        return path.strip(), parse_line_spec(rest)
    return m.group("path").strip(), parse_line_spec(m.group("lines"))


def git_diff_new_hunks(target: str, source: str, path: str) -> tuple[bool, list[tuple[int, int]]]:
    """Return (path_in_diff, [(start, end_inclusive), ...]) on the new side.

    Runs `git diff -U0 <target>...<source> -- <path>` and parses hunk headers. A path with no
    diff block returns (False, []) — meaning the file wasn't touched at all in the range, so
    a carried finding on it is definitionally stale (except for `in_diff: false` findings,
    handled by the caller).
    """
    proc = subprocess.run(
        ["git", "diff", "-U0", f"{target}...{source}", "--", path],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        # Non-zero from `git diff` here almost always means bad ref. Bubble up.
        raise RuntimeError(
            f"git diff failed for {path} ({target}...{source}): {proc.stderr.strip()}"
        )
    hunks: list[tuple[int, int]] = []
    for line in proc.stdout.splitlines():
        m = HUNK_RE.match(line)
        if not m:
            continue
        start = int(m.group(1))
        length = int(m.group(2)) if m.group(2) else 1
        if length == 0:
            # Pure deletion — no new-side lines to intersect with. Skip.
            continue
        hunks.append((start, start + length - 1))
    # `git diff` with a path arg and no diff prints nothing at all (rc=0, empty stdout). No
    # hunks means the file is unchanged in this range.
    return (bool(hunks), hunks)


def any_line_in_hunks(lines: Iterable[int], hunks: list[tuple[int, int]]) -> bool:
    return any(any(start <= ln <= end for start, end in hunks) for ln in lines)


def strip_md_sections(md_text: str, drop_ids: set[str]) -> tuple[str, list[str]]:
    """Remove `## <ID> — ...` sections whose ID is in `drop_ids`.

    A "section" is the `## <ID> —` heading through (exclusive of) the next `## ` heading, or
    to a `<!-- REVIEW-COMPLETE ... -->` trailer line, or to EOF. Returns the filtered text
    and the list of IDs that could NOT be located (for logging — .md drift is not fatal).
    """
    lines = md_text.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    found: set[str] = set()
    while i < len(lines):
        line = lines[i]
        heading = re.match(r"^##\s+([A-Z][A-Z0-9\-]*(?:-[A-Z]+-\d+|-\d+))\b", line)
        if heading and heading.group(1) in drop_ids:
            found.add(heading.group(1))
            # Skip until the next `## ` heading OR a REVIEW-COMPLETE trailer OR EOF.
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if nxt.startswith("## ") or nxt.startswith("<!-- REVIEW-COMPLETE"):
                    break
                i += 1
            continue
        out.append(line)
        i += 1
    unlocated = sorted(drop_ids - found)
    return "".join(out), unlocated


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True, help="Prior-round findings JSON")
    ap.add_argument("--out", dest="outp", required=True, help="Filtered output path")
    ap.add_argument("--target", required=True, help="target ref (main branch)")
    ap.add_argument("--source", required=True, help="source ref (the branch under review)")
    ap.add_argument("--in-md", dest="in_md", help="Prior-round .md report (optional)")
    ap.add_argument("--out-md", dest="out_md", help="Filtered .md output (optional)")
    args = ap.parse_args()
    if bool(args.in_md) != bool(args.out_md):
        print(
            "filter-carried-findings: --in-md and --out-md must be given together (or neither)",
            file=sys.stderr,
        )
        return 2

    try:
        with open(args.inp) as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"filter-carried-findings: no input file {args.inp}", file=sys.stderr)
        return 3

    findings = data.get("findings", [])
    kept: list[dict] = []
    dropped_ids: list[str] = []
    # Memoize per-path diff results so a file with 30 findings only diffs once.
    diff_cache: dict[str, tuple[bool, list[tuple[int, int]]]] = {}

    for f in findings:
        fid = f.get("id", "?")
        loc = f.get("location", "")
        # Explicit `in_diff: false` — the specialist reasoned about extra-diff state (config
        # elsewhere, dangling reference in a peer file). Keep.
        if f.get("in_diff") is False:
            kept.append(f)
            print(f"KEEP {fid} {loc} — in_diff=false", file=sys.stderr)
            continue

        path, lines = parse_location(loc)
        if not path:
            kept.append(f)
            print(f"KEEP {fid} {loc} — unparseable location", file=sys.stderr)
            continue
        if not lines:
            kept.append(f)
            print(f"KEEP {fid} {loc} — no line component", file=sys.stderr)
            continue

        # Diff the path once, reuse.
        try:
            if path not in diff_cache:
                diff_cache[path] = git_diff_new_hunks(args.target, args.source, path)
        except RuntimeError as exc:
            # Git failed — don't drop on tool error. Keep, note.
            kept.append(f)
            print(f"KEEP {fid} {loc} — git diff error: {exc}", file=sys.stderr)
            continue

        path_in_diff, hunks = diff_cache[path]
        if not path_in_diff:
            dropped_ids.append(fid)
            print(f"DROP {fid} {loc} — path not in diff", file=sys.stderr)
            continue
        if not any_line_in_hunks(lines, hunks):
            dropped_ids.append(fid)
            print(f"DROP {fid} {loc} — cited line(s) not in any hunk", file=sys.stderr)
            continue
        kept.append(f)
        print(f"KEEP {fid} {loc} — line in diff", file=sys.stderr)

    data["findings"] = kept
    with open(args.outp, "w") as f:
        json.dump(data, f, indent=2)

    total = len(findings)
    n_kept = len(kept)
    n_dropped = len(dropped_ids)
    print(f"FILTER: {n_kept}/{total} kept, {n_dropped} dropped from {args.inp}")
    if dropped_ids:
        print(f"  Dropped IDs: {', '.join(dropped_ids)}")

    if args.in_md:
        try:
            with open(args.in_md) as f:
                md_text = f.read()
        except FileNotFoundError:
            print(
                f"filter-carried-findings: --in-md {args.in_md} missing — writing empty .md",
                file=sys.stderr,
            )
            md_text = ""
        filtered_md, unlocated = strip_md_sections(md_text, set(dropped_ids))
        with open(args.out_md, "w") as f:
            f.write(filtered_md)
        if unlocated:
            print(
                f"  WARN: {len(unlocated)} dropped ID(s) not found in .md — .json is authoritative: "
                f"{', '.join(unlocated)}",
                file=sys.stderr,
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
