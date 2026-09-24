#!/usr/bin/env bash
# python.sh — ruff, bandit, mypy, pylint over the changed .py files.
#
# These four replace what `code-review-security` and `code-review-reliability` were hand-grepping
# for. Verified during planning against a 7-line file: bandit finds the hardcoded password, the
# subprocess(shell=True) call and the partial executable path; ruff finds the bare except. Each
# comes back with a rule id, a severity and a doc URL — strictly more than an LLM grep produced,
# at zero token cost.
#
# pytest and coverage are deliberately NOT run here — see the note at the bottom.
#
# In-code suppressions are NOT honoured where the tool can be told to ignore them: ruff runs with
# --ignore-noqa and bandit with --ignore-nosec, so a `# noqa` / `# nosec` in the diff no longer
# deletes its own finding. mypy and pylint have no such flag and still honour `# type: ignore` and
# `# pylint: disable`; that gap is stated at each call site rather than left implied.
#
# Detector contract: see _lib.sh. Always exits 0.

set -uo pipefail

LIST="${1:?changed-files list required}"
OUT="${2:?outdir required}"
RAW="$OUT/raw"
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib.sh"

mkdir -p "$RAW"
PY="$RAW/.py-files"
filter_ext "$LIST" .py > "$PY"

if ! any_lines "$PY"; then
  skip "python" "no .py files in the diff"
  exit 0
fi

# Load the file list into the positional parameters. NOT `xargs`: xargs splits into several
# invocations once the argument list gets long, and two concatenated JSON documents are
# unparseable — a large diff would silently produce a broken raw file. NOT unquoted `$(cat)`
# either: that breaks on filenames with spaces, and bash word-splits it while zsh does not, so a
# script that must run under both cannot rely on the behaviour. `set --` gives one invocation with
# correct quoting in both shells.
set --
while IFS= read -r f; do
  [ -n "$f" ] && set -- "$@" "$f"
done < "$PY"

if need ruff; then
  # rc 1 = "findings exist", the normal case. Only rc >= 2 is a tool error.
  #
  # --ignore-noqa: report the finding even where the code carries `# noqa`. Without it a suppression
  # comment deletes the finding here, at the detector tier, so it never reaches triage and no
  # reviewer ever sees it, so the reviewer's "a comment is not evidence" rule cannot apply to a
  # finding that no longer exists. A suppression is also itself a violation of the team's
  # zero-tolerance rule on `# noqa`, which makes suppressed findings the ones most worth surfacing,
  # not least. Whether the suppression is justified is a judgement, and judgement belongs to
  # `review-semantic`'s scan triage, which can `drop` it on evidence it read.
  ruff check --output-format=json --no-cache --ignore-noqa "$@" > "$RAW/ruff.json" 2> "$RAW/.ruff.err"
  rc=$?
  if [ "$rc" -ge 2 ]; then
    skip "ruff" "exited $rc: $(excerpt "$RAW/.ruff.err")"
    rm -f "$RAW/ruff.json"
  else
    [ -s "$RAW/ruff.json" ] || printf '[]\n' > "$RAW/ruff.json"
    note ruff "ok"
  fi
fi

if need bandit; then
  # -q drops the progress banner. bandit exits 1 when it finds anything, so judge by output.
  # --ignore-nosec is the `# nosec` counterpart of ruff's --ignore-noqa above, and matters more here:
  # a silently suppressed bandit HIGH is a suppressed BLOCKER.
  bandit -f json -q --ignore-nosec "$@" > "$RAW/bandit.json" 2> "$RAW/.bandit.err"
  if [ ! -s "$RAW/bandit.json" ]; then
    skip "bandit" "produced no output: $(excerpt "$RAW/.bandit.err")"
    rm -f "$RAW/bandit.json"
  else
    note bandit "ok"
  fi
fi

if need mypy; then
  # KNOWN HOLE, stated rather than implied: mypy has NO equivalent of --ignore-noqa. There is no flag
  # that makes it re-report an error a `# type: ignore` suppressed, so a `# type: ignore` in the diff
  # still deletes its finding before triage. `--warn-unused-ignores` is not the flag; it reports
  # ignores that suppressed nothing, which is the opposite population. Closing this would mean
  # stripping the comments from a copy of the file before analysis, which changes line numbers and
  # would break the hunk intersection, so it is deliberately not done here.
  #
  # --output=json emits JSONL (one object per line), NOT a JSON document — normalize.py reads it
  # with a line loop for exactly that reason. Needs mypy >= 1.11; an older build ignores the flag
  # and prints text, which the JSONL loader would read as zero findings. So check for the flag
  # rather than assuming, and skip loudly if it is absent.
  if mypy --help 2>&1 | grep -q -- '--output'; then
    # mypy needs the project's environment to resolve imports. In a bare benchmark clone or a CI
    # container without the venv installed it emits an import error for every third-party module —
    # noise, not findings. --ignore-missing-imports keeps it to real type errors in the changed
    # files, at the cost of missing genuine bad-import bugs. That trade is right for an advisory
    # review scan; the project's own CI type-check job does the strict pass.
    mypy --output=json --no-error-summary --ignore-missing-imports "$@" \
      > "$RAW/mypy.json" 2> "$RAW/.mypy.err"
    if [ ! -s "$RAW/mypy.json" ] && [ -s "$RAW/.mypy.err" ]; then
      skip "mypy" "no JSON output: $(excerpt "$RAW/.mypy.err")"
      rm -f "$RAW/mypy.json"
    else
      [ -f "$RAW/mypy.json" ] || : > "$RAW/mypy.json"
      note mypy "ok"
    fi
  else
    skip "mypy" "installed mypy has no --output=json (needs >= 1.11)"
  fi
fi

if need pylint; then
  # KNOWN HOLE, same as mypy above: pylint has NO equivalent of --ignore-noqa either. An inline
  # `# pylint: disable=` still deletes its finding before triage. `--enable=useless-suppression`
  # (I0021) is not the flag; it reports disables that suppressed nothing, again the opposite
  # population. So of the four tools in this detector, two ignore in-code suppressions (ruff, bandit)
  # and two still honour them (mypy, pylint). A reviewer reading a clean python scan should know that.
  #
  # pylint's rc is a bitfield (1=fatal 2=error 4=warning 8=refactor 16=convention), so non-zero is
  # the normal case and says nothing about tool health. Judge by whether the JSON parses.
  # normalize.py drops convention/refactor as style noise — see its module docstring.
  pylint --output-format=json2 --score=n "$@" > "$RAW/pylint.json" 2> "$RAW/.pylint.err"
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$RAW/pylint.json" 2>/dev/null; then
    skip "pylint" "unparseable output: $(excerpt "$RAW/.pylint.err")"
    rm -f "$RAW/pylint.json"
  else
    note pylint "ok"
  fi
fi

# pytest and coverage are NOT run from this detector, on purpose.
#
# The suite needs the project's installed environment and its services (a DB, localstack), runs
# via the project's own make target, and takes minutes to tens of minutes. Doing that inside a
# review scan would make the scan slower and less reliable than the review it feeds, and in a bare
# benchmark clone it fails outright. The project's own CI test job, run with `--junitxml` and
# `--cov-report=xml`, is far better placed for it.
#
# So the scanner INGESTS results that are already on disk (raw/pytest.json, raw/coverage.json) and
# records a skip when they are absent. The test-failure and coverage-below-gate findings are wired
# through normalize.py already and light up the moment CI hands those artifacts over.
[ -f "$RAW/pytest.json" ] || skip "pytest" \
  "not run by the scanner (needs the project env + services); drop raw/pytest.json in from CI to ingest"
[ -f "$RAW/coverage.json" ] || skip "coverage" \
  "not run by the scanner; drop raw/coverage.json (coverage json) in from CI to ingest"

rm -f "$RAW"/.ruff.err "$RAW"/.bandit.err "$RAW"/.mypy.err "$RAW"/.pylint.err "$PY" 2>/dev/null
exit 0
