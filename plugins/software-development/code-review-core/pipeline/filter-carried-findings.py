#!/usr/bin/env python3
"""filter-carried-findings.py — drop findings whose cited lines are not on changed lines.

Invoked by `pipeline/review-scan.sh` (see its `FILTER=` assignment) to diff-scope SCAN.json. That is
the only caller. It is what stops a repository's existing lint debt from arriving as hundreds of
findings about code the change never touched.

Semantics.
    For each finding in the input JSON:
      - `in_diff: false` set explicitly: KEEP. The producer already reasoned that the finding is
        about state outside the diff (the coverage gate, a dangling reference in a peer file).
      - Parse `location: "path[:linespec]"`. `linespec` is any mix of single lines and ranges:
        `87`, `87-90` (also with an en-dash, em-dash or minus sign), `12, 15, 22`, `12+`.
      - No path, or no line component: KEEP (cannot line-check, so stay conservative).
      - Path with no hunks in `git diff -U0 target...source -- path`: DROP.
      - Otherwise KEEP when ANY cited line or range overlaps ANY hunk, else DROP.

    A range is an INTERVAL, not its two endpoints. `80-100` with only line 90 changed is kept: a
    finding about a resource block the change edited in the middle is in the diff.

    Hunks. `@@ -a,b +c,d @@` covers new-side lines [c, c+d-1] (d defaults to 1). A pure deletion
    has d == 0 and no new-side lines at all; git names the new-side line the deletion follows (0
    when it is at the top of the file). That boundary line is treated as changed, clamped to line 1,
    because a finding ABOUT the deletion can only be anchored there: `detectors/impact.sh` anchors
    "this removed symbol still has consumers" to exactly that line, and before this rule every such
    finding was dropped, which is the worst miss the impact detector can have.

Output.
    Writes the filtered JSON to --out. Prints one disposition line per finding to stderr
    (`KEEP <id> <location> — reason` / `DROP <id> <location> — reason`) and a summary to stdout
    (`FILTER: <kept>/<total> kept, <dropped> dropped from <path>`).

Exit status.
    0  the output was written. A `git diff` failure for one path does NOT fail the run: the
       findings on that path are KEPT and the error is in their disposition line, because dropping
       on a tool error would hide findings and a caller cannot tell that apart from a clean diff.
    2  bad arguments (argparse).
    3  --in is missing or is not a JSON object.

Portable: python3 only. No external deps (uses `subprocess` for git). No network.

Usage:
    filter-carried-findings.py --in SCAN.raw.json --out SCAN.json --target <ref> --source <ref>
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

HUNK_RE = re.compile(r"^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@")
LOCATION_RE = re.compile(r"^(?P<path>[^\s:]+):(?P<lines>[\d\-–—−\s+,]+)")
# A range `a-b` (any dash) or a single line. Tried as a range first so `87-90` is one interval.
SPEC_RE = re.compile(r"(\d+)\s*[-–—−]\s*(\d+)|(\d+)")

# quotePath=false keeps git's own messages readable for non-ASCII paths; literal pathspecs stop a
# path like `[ab].py` from being read as a glob that also matches `a.py`.
GIT = ["git", "-c", "core.quotePath=false", "--literal-pathspecs"]


def parse_line_spec(spec: str) -> list[tuple[int, int]]:
    """Return the cited lines as inclusive intervals; empty when nothing parses.

    `"42"` -> [(42, 42)], `"87-90"` -> [(87, 90)], `"12, 15"` -> [(12, 12), (15, 15)],
    `"12+"` -> [(12, 12)]. A reversed range is normalised.
    """
    out: list[tuple[int, int]] = []
    for m in SPEC_RE.finditer(spec):
        if m.group(1):
            a, b = int(m.group(1)), int(m.group(2))
            out.append((min(a, b), max(a, b)))
        else:
            n = int(m.group(3))
            out.append((n, n))
    return out


def parse_location(loc: str) -> tuple[str, list[tuple[int, int]]]:
    """Return (path, [intervals]). No `:linespec` gives []."""
    if not loc:
        return "", []
    if ":" not in loc:
        return loc.strip(), []
    m = LOCATION_RE.match(loc.strip())
    if not m:
        # A colon but not a clean `path:linespec` (a path with a space, `path:Step 3a`): split on the
        # FIRST colon and extract what lines there are from the rest.
        path, _, rest = loc.partition(":")
        return path.strip(), parse_line_spec(rest)
    return m.group("path").strip(), parse_line_spec(m.group("lines"))


def git_diff_new_hunks(target: str, source: str, path: str) -> list[tuple[int, int]]:
    """New-side hunk intervals for `path` in target...source. Empty means the path is unchanged.

    Raises RuntimeError when git fails, so the caller can keep rather than drop.
    """
    proc = subprocess.run(
        GIT + ["diff", "-U0", "--no-color", f"{target}...{source}", "--", path],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"git diff failed for {path} ({target}...{source}): {proc.stderr.strip()}"
        )
    hunks: list[tuple[int, int]] = []
    for line in proc.stdout.splitlines():
        m = HUNK_RE.match(line)
        if not m:
            continue
        start = int(m.group(1))
        length = int(m.group(2)) if m.group(2) is not None else 1
        if length == 0:
            # Pure deletion: the boundary line it follows (see the module docstring).
            anchor = max(start, 1)
            hunks.append((anchor, anchor))
            continue
        hunks.append((start, start + length - 1))
    return hunks


def overlaps(cited: list[tuple[int, int]], hunks: list[tuple[int, int]]) -> bool:
    """True when any cited interval shares at least one line with any hunk."""
    return any(a <= h_end and h_start <= b for a, b in cited for h_start, h_end in hunks)


def main() -> int:
    ap = argparse.ArgumentParser(description="Keep only findings on changed lines.")
    ap.add_argument("--in", dest="inp", required=True, help="findings JSON to filter")
    ap.add_argument("--out", dest="outp", required=True, help="filtered output path")
    ap.add_argument("--target", required=True, help="base ref")
    ap.add_argument("--source", required=True, help="the ref under review")
    args = ap.parse_args()

    try:
        with open(args.inp) as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"filter-carried-findings: no input file {args.inp}", file=sys.stderr)
        return 3
    except ValueError as exc:
        print(f"filter-carried-findings: {args.inp} is not valid JSON: {exc}", file=sys.stderr)
        return 3
    if not isinstance(data, dict):
        print(f"filter-carried-findings: {args.inp} is not a JSON object", file=sys.stderr)
        return 3

    findings = data.get("findings") or []
    kept: list[dict] = []
    dropped_ids: list[str] = []
    # One `git diff` per path, however many findings cite it.
    diff_cache: dict[str, list[tuple[int, int]]] = {}

    for f in findings:
        fid = f.get("id", "?")
        loc = f.get("location", "")
        if f.get("in_diff") is False:
            kept.append(f)
            print(f"KEEP {fid} {loc} — in_diff=false", file=sys.stderr)
            continue

        path, cited = parse_location(loc)
        if not path:
            kept.append(f)
            print(f"KEEP {fid} {loc} — unparseable location", file=sys.stderr)
            continue
        if not cited:
            kept.append(f)
            print(f"KEEP {fid} {loc} — no line component", file=sys.stderr)
            continue

        try:
            if path not in diff_cache:
                diff_cache[path] = git_diff_new_hunks(args.target, args.source, path)
        except RuntimeError as exc:
            kept.append(f)
            print(f"KEEP {fid} {loc} — git diff error: {exc}", file=sys.stderr)
            continue

        hunks = diff_cache[path]
        if not hunks:
            dropped_ids.append(fid)
            print(f"DROP {fid} {loc} — path not in diff", file=sys.stderr)
            continue
        if not overlaps(cited, hunks):
            dropped_ids.append(fid)
            print(f"DROP {fid} {loc} — cited line(s) not in any hunk", file=sys.stderr)
            continue
        kept.append(f)
        print(f"KEEP {fid} {loc} — line in diff", file=sys.stderr)

    data["findings"] = kept
    with open(args.outp, "w") as f:
        json.dump(data, f, indent=2)

    print(f"FILTER: {len(kept)}/{len(findings)} kept, {len(dropped_ids)} dropped from {args.inp}")
    if dropped_ids:
        print(f"  Dropped IDs: {', '.join(dropped_ids)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
