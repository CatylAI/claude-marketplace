#!/usr/bin/env bash
# comments.sh — the mechanical half of comment quality: commented-out code, and undecorated markers.
#
# WHY THIS IS A SIBLING OF deps.sh AND NOT A SECTION INSIDE IT. The two rules landed in the same
# piece of work, so folding them into `deps.sh` was the smaller diff. It is the wrong file. A
# detector's identity in this pipeline is not its source file, it is its SKIP RECORD: `_lib.sh`
# requires every non-run to write `raw/<tool>.skipped` with a reason, and SCAN-SUMMARY.md prints
# those verbatim as the coverage gaps a reader's "nothing found" conclusion rests on. A detector
# named `deps` that also scans comments has exactly one skip line to spend on two unrelated jobs, so
# a diff of pure Python with no manifest would print "deps: no dependency manifest in the diff" and
# silently not mention that the comment rules never ran either. The file selections do not overlap
# (manifests versus source), the raw outputs would have to share one name, and `review-scan.sh`
# dispatches on separate signals. Two detectors, two records, two honest skip lines.
#
# WHAT IS MECHANICAL AND WHAT IS NOT. "Is this comment accurate?" needs someone to read the code
# underneath it and decide — that is the `code-comments` skill in dev-standards, and it stays there.
# "Is this a block of commented-out code?" and "does this TODO point at anything?" are decidable by
# looking at the text, so they are decided here, for free, on every change.
#
# BOTH RULES EMIT NIT, and that is the honest tier rather than a hedge. `code-review-standards`
# defines NIT as "no true impact": commented-out code does not change what the program does, and an
# unreferenced TODO is a note to nobody. Neither should block a merge. What they produce is a
# SHORTLIST — the places a human should look — which is the same contract impact.sh's findings
# carry, and for the same reason: a text match knows what the line looks like and nothing about
# whether it matters.
#
# Detector contract: see _lib.sh. Always exits 0.

set -uo pipefail

LIST="${1:?changed-files list required}"
OUT="${2:?outdir required}"
RAW="$OUT/raw"
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib.sh"

mkdir -p "$RAW"

SRC="$RAW/.comment-files"
# Only languages whose line-comment token is unambiguous, and only source. Markdown, YAML and JSON
# are excluded deliberately: `#` in a YAML file is overwhelmingly configuration prose, and a
# commented-out config block is a normal way to ship a documented default rather than a defect.
filter_ext "$LIST" .py .sh .bash .zsh .rb .tf .ts .tsx .js .jsx .mjs .go .rs .java .kt .swift \
  .c .h .cc .cpp .hpp .cs .php .scala .m > "$SRC"

if ! any_lines "$SRC"; then
  skip "comments" "no source file with a known comment syntax in the diff"
  rm -f "$SRC"
  exit 0
fi

need python3 || { rm -f "$SRC"; exit 0; }

if ! python3 - "$SRC" "$RAW/comments.json" <<'PY'
"""Two text-decidable comment defects. Same output shape as deps.sh; normalize.py's `p_comments`
reads it.

Both heuristics are written to UNDER-REPORT. A comment detector that fires on prose is the most
annoying thing a review pipeline can do, because comments are everywhere and the reader has no way
to tell a real hit from a bad one without reading each. So each rule carries an explicit reason for
every exclusion, and anything that cannot be decided from the text is left alone.
"""
import json, os, re, sys

src_path, out_path = sys.argv[1], sys.argv[2]
# ARCHITECTURE rather than a new `MAINTAINABILITY` word: `code-review-standards` fixes the category
# vocabulary at SECURITY / PERFORMANCE / TESTING / RELIABILITY / ARCHITECTURE / IMPACT, and inventing
# a seventh so two files disagree about the set is a worse trade than using the closest documented
# bucket. Commented-out code is duplicated code that nobody maintains, which is the architect's
# territory; neither rule touches behaviour, so RELIABILITY would be a lie.
NIT, ARCHITECTURE = "NIT", "ARCHITECTURE"

# Per-file caps. A file someone is mid-way through refactoring can hold dozens of commented blocks;
# listing all of them buries every other finding in the scan under one file's debris.
MAX_BLOCKS_PER_FILE, MAX_MARKERS_PER_FILE = 5, 10

# The minimum run length. Two commented lines are as likely to be a two-line explanation as a
# deletion; three consecutive lines that all parse as code is the point where prose stops being the
# simpler explanation.
MIN_BLOCK = 3

findings, notes = [], []

HASH = {".py", ".sh", ".bash", ".zsh", ".rb", ".tf"}
SLASH = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".go", ".rs", ".java", ".kt", ".swift",
         ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".php", ".scala", ".m"}


def add(path, line, rule, title, rec):
    findings.append({
        "path": path, "line": int(line), "rule": rule, "severity": NIT,
        # Untruncated: normalize.py's mk() owns the title/recommendation caps.
        "category": ARCHITECTURE, "title": title, "recommendation": rec,
    })


# A comment body that looks like a statement rather than a sentence. Each alternative is a shape
# that prose essentially never takes.
CODE_SHAPES = (
    re.compile(r"^[\w.\[\]\"'$@]+\s*(?:[-+*/|&^]|\?\?)?=[^=~]"),   # assignment
    re.compile(r"^[\w.$]+\s*\(.*\)\s*[;,]?\s*$"),                  # a bare call
    re.compile(r"^(?:if|for|while|do|switch|case|else|elif|try|except|catch|finally|return|yield|"
               r"raise|throw|break|continue|pass|def|class|func|function|fn|impl|struct|import|"
               r"from|export|const|let|var|public|private|protected|static|await|async|package|"
               r"use|require|echo|print|println|printf|console\.|System\.|puts|local|readonly)\b"),
    re.compile(r"^[)}\]]+\s*[;,]?\s*$"),                           # a closing bracket alone
    re.compile(r"^[\w.$]+\s*=>\s*"),                               # an arrow function
    re.compile(r"^</?[a-zA-Z][\w:-]*[\s/>]"),                      # a JSX/HTML element
)

# Comments that are MACHINERY, not prose and not dead code. Every one of these is read by a tool,
# so a run of them is a working part of the file. Without this list a `# noqa` stack or a licence
# header block reads as three consecutive "code-shaped" lines.
DIRECTIVE = re.compile(
    r"^(?:"
    r"[!>]|-\*-|\.\.\.|@|"                                       # shebang, doctest, annotation
    r"(?:type|noqa|pylint|ruff|flake8|mypy|pragma|shellcheck|nolint|gofmt|go:|goland|"
    r"eslint|prettier|ts-|tslint|jshint|istanbul|c8|v8|biome|coverage|fmt:|region|endregion|"
    r"SPDX|Copyright|Licensed|codespell|cspell|spell-checker|depends-on|renovate|dependabot)\b"
    r")", re.I)

# Anchored at the START of the comment body (after any bullet or decoration), because a real marker
# opens the comment it lives in. An unanchored search fires on every sentence that MENTIONS a TODO —
# including this file's own commentary, and every standards document that states the rule — which is
# a detector reporting on its own explanation of itself.
# A COLUMN-ALIGNED TABLE inside a comment, which is prose that happens to be assignment-shaped:
#
#     # severity   = IMPACT only     BLOCKER | MAJOR | MINOR | NIT
#     # in_diff    = SCOPE           did this change introduce or worsen it
#
# Three of those in a row is a documentation table in every codebase and a deletion in none. It was
# the only false positive this detector produced across the 79 source files of this repository, and
# the shape is specific enough to exclude on: a formatter collapses runs of spaces inside a real
# statement, so a doubled space on the right of the `=` means a human aligned it by hand.
ALIGNED_TABLE = re.compile(r"=\s*\S+\s{2,}\S")

MARKER = re.compile(r"^[\s*\-=+#/]*\b(TODO|FIXME|XXX)\b")
# What counts as "tracked": an issue number, a tracker key, or a link to the thing that explains it.
# A bare owner name (`TODO(alice)`) deliberately does NOT count — a person is not a queue, and the
# note still disappears the moment alice does.
# NOT case-insensitive. With re.I the tracker-key alternative also matches `utf-8`, `sha-256` and
# `x-1`, so a marker sitting above an encoding declaration would read as tracked and the finding
# would be suppressed — a false NEGATIVE, which is the direction that cannot be noticed.
REFERENCE = re.compile(r"(#\d+)|(\b[A-Z][A-Z0-9]{1,9}-\d+\b)|(https?://\S+)")


def comment_body(line, token):
    """The text after the first line-comment token, or None when the line is not comment-only.

    Comment-only is required on purpose: a trailing `x = 1  # was 2` is an explanation of the line
    it sits on, never a deletion, and treating it as one would fire on half of every file.
    """
    stripped = line.strip()
    if not stripped.startswith(token):
        return None
    return stripped[len(token):].strip()


def scan_file(path, lines, token):
    blocks = markers = 0

    # ---- rule 1: a run of MIN_BLOCK+ comment-only lines that all read as code.
    #
    # ALL of them, not "most": one prose line inside a run is the signal that the run is an
    # explanation containing a code example, which is exactly the thing that must not be reported.
    # An empty comment line (`#` alone) is allowed to continue a run without voting either way,
    # because that is how a commented-out block with a blank line in it looks.
    run_start, run_code = None, 0

    def close_run(end_line):
        nonlocal run_start, run_code, blocks
        if run_start is not None and run_code >= MIN_BLOCK and blocks < MAX_BLOCKS_PER_FILE:
            blocks += 1
            add(path, run_start, "commented-out-code",
                f"{run_code} consecutive lines of commented-out code (lines "
                f"{run_start}-{end_line})",
                "Delete it. Version control is the archive — the lines are recoverable from "
                "history with the commit message that explains why they went, which a commented "
                "block does not carry. Code that is kept because it might come back is code "
                "nobody maintains, and it rots against the lines around it.")
        run_start, run_code = None, 0

    for i, line in enumerate(lines, 1):
        body = comment_body(line, token)
        if body is None:
            close_run(i - 1)
            continue
        if not body:
            continue                               # a bare `#` neither starts nor breaks a run
        if DIRECTIVE.match(body) or MARKER.match(body) or ALIGNED_TABLE.search(body):
            close_run(i - 1)
            continue
        if any(p.match(body) for p in CODE_SHAPES):
            if run_start is None:
                run_start = i
            run_code += 1
            continue
        close_run(i - 1)                           # prose: the run, if any, was an explanation
    close_run(len(lines))

    # ---- rule 2: a marker with no tracked reference within one line either way.
    #
    # The window is one line in each direction because the common correct shape puts the link on
    # the following line when it will not fit:  `# TODO: drop the shim once the API ships` /
    # `# https://tracker/PROJ-412`.
    for i, line in enumerate(lines, 1):
        body = comment_body(line, token)
        if body is None:
            # A trailing marker still counts — `foo()  # FIXME` is the same note — so fall back to
            # the whole line, but only when the comment token is actually present on it.
            if token not in line:
                continue
            body = line.split(token, 1)[1]
        m = MARKER.match(body)
        if not m:
            continue
        window = " ".join(lines[max(0, i - 2): i + 1])
        if REFERENCE.search(window):
            continue
        if markers >= MAX_MARKERS_PER_FILE:
            notes.append(f"{path}: more than {MAX_MARKERS_PER_FILE} untracked markers; only the "
                         "first were reported")
            break
        markers += 1
        add(path, i, "untracked-marker",
            f"`{m.group(1)}` with no issue reference: {body.strip()[:120]}",
            "A marker nobody can find is decoration: it is invisible to every backlog, and the "
            "person who could act on it will never see it. Either file the issue and put its id "
            "or URL on the line, or do the work now, or delete the marker.")


for path in [l.strip() for l in open(src_path).read().splitlines() if l.strip()]:
    ext = os.path.splitext(path)[1].lower()
    token = "#" if ext in HASH else "//" if ext in SLASH else None
    if not token:
        continue
    try:
        with open(path, errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        continue
    scan_file(path, lines, token)

json.dump({"findings": findings, "notes": notes}, open(out_path, "w"))
print(f"{len(findings)} comment finding(s)", file=sys.stderr)
PY
then
  skip "comments" "comment scan failed"
  rm -f "$RAW/comments.json"
else
  note comments "ok"
fi

rm -f "$SRC" 2>/dev/null
exit 0
