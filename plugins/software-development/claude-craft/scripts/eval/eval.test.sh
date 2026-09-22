#!/usr/bin/env bash
# eval.test.sh — the test suite for the eval harness itself.
#
#   bash scripts/eval/eval.test.sh        (from the claude-craft plugin root)
#   bash eval.test.sh                     (from this directory)
#
# A harness that measures other people's work has to be measured itself, and the two properties
# worth proving are the two whose failure is INVISIBLE:
#
#   1. A 0% because the skill did not fire must be distinguishable from a 0% because nothing ran.
#      The donor implementation this was rewritten from collapsed both into False, so a machine
#      with no `claude` on PATH reported a confident 0% trigger rate for every query. Sections 3
#      and 4 below construct all four cases — absent binary, dead binary, real non-trigger, real
#      trigger — and assert the exit codes and reports differ.
#
#   2. The holdout must actually be held out. A winner selected on the training score is a
#      description fitted to the twelve sentences its author happened to write, and nothing about
#      the numbers would look wrong. Section 5 plants exactly that defect and asserts this suite
#      goes red on it.
#
# House idiom: plant a defect, assert non-zero exit. Sections 2 and 5 both do.
#
# Everything runs against FAKE `claude` executables written into $TMP. No network, no real session,
# no tokens spent, nothing written outside $TMP. Portable bash 3.2+ / zsh.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-craft-eval-test.XXXXXX")"

PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

printf 'eval harness tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

PY="$(command -v python3 2>/dev/null)"
if [ -z "$PY" ]; then
  fail "python3 is available" "python3 not on PATH — this suite cannot run"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi
# The REAL interpreter, not whatever wrapper is first on PATH. `python3` is frequently a shell
# shim (pyenv, asdf), and every subject process below runs under a deliberately minimal PATH so
# that `claude` can be made absent — which breaks a shim that needs its own interpreter on PATH.
PY="$("$PY" -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -z "$PY" ] || [ ! -x "$PY" ]; then
  fail "python3 is available" "could not resolve a real python3 interpreter"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi
pass "python3 is available"

# The PATH every subject process runs under. `claude` must NOT be reachable through it, or the
# absent-binary case below would quietly find the operator's real CLI and start spending money.
SAFEPATH="/usr/bin:/bin:/usr/sbin:/sbin"
if env PATH="$SAFEPATH" command -v claude >/dev/null 2>&1; then
  fail "the test PATH carries no real claude" \
       "claude is reachable under $SAFEPATH — this suite would spawn real sessions"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi
pass "the test PATH carries no real claude"

# A python program always comes from a FILE, never from an interpolated `python3 -c` string: a
# `-c` body in double quotes is still subject to shell expansion, which is how a comment inside
# one becomes a command substitution.
mkdir -p "$TMP/bin" "$TMP/empty" "$TMP/fixtures"

# ---------------------------------------------------------------- fixtures
cat > "$TMP/fixtures/evalset.json" <<'JSON'
[
  {"query": "reconcile the March statement against the general ledger", "should_trigger": true},
  {"query": "clear out the suspense account for Q1", "should_trigger": true},
  {"query": "what is the office wifi password", "should_trigger": false},
  {"query": "summarise this meeting transcript", "should_trigger": false}
]
JSON

mkdir -p "$TMP/fixtures/skill"
cat > "$TMP/fixtures/skill/SKILL.md" <<'MD'
---
name: ledger-reconciliation
description: |
  Use when reconciling a bank or credit statement against the general ledger, clearing
  suspense accounts, or explaining a reconciliation difference. Not for accruals,
  payroll, or general document summarisation.
license: MIT
---

# Ledger reconciliation

Placeholder body.
MD

# jget.py — read one dotted path out of a JSON file. Used instead of grepping report text, so an
# assertion fails on the VALUE rather than on incidental formatting.
cat > "$TMP/bin/jget.py" <<'PY'
import json
import sys

path, dotted = sys.argv[1], sys.argv[2]
node = json.load(open(path))
for part in dotted.split("."):
    if isinstance(node, list):
        node = node[int(part)]
    else:
        node = node[part]
print(json.dumps(node))
PY

# ---------------------------------------------------------------- fake claude binaries
#
# Each one emits the `--output-format stream-json --include-partial-messages` envelope shapes the
# detector reads, so these exercise the real parser rather than a mock of it.

# Fires the skill: Skill tool, probe name arriving in input_json_delta fragments.
cat > "$TMP/bin/claude-fires" <<PY
#!$PY
import glob, json, os, sys

dirs = sorted(glob.glob(".claude/skills/*/"))
name = os.path.basename(dirs[0].rstrip("/")) if dirs else "no-skill-found"
if os.environ.get("EVAL_TEST_SENTINEL"):
    open(os.environ["EVAL_TEST_SENTINEL"], "w").write("spawned")

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

emit({"type": "system", "subtype": "init"})
emit({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
      "content_block": {"type": "tool_use", "name": "Skill", "input": {}}}})
# Split across two fragments, as a real stream does.
payload = json.dumps({"skill": name})
emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
      "delta": {"type": "input_json_delta", "partial_json": payload[:9]}}})
emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
      "delta": {"type": "input_json_delta", "partial_json": payload[9:]}}})
emit({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}})
emit({"type": "result", "subtype": "success", "is_error": False})
PY

# Runs fine, declines the skill: a real session that reaches for something else and finishes.
cat > "$TMP/bin/claude-declines" <<PY
#!$PY
import json, os, sys

if os.environ.get("EVAL_TEST_SENTINEL"):
    open(os.environ["EVAL_TEST_SENTINEL"], "w").write("spawned")

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

emit({"type": "system", "subtype": "init"})
emit({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
      "content_block": {"type": "tool_use", "name": "Grep", "input": {}}}})
emit({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}})
emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "answered directly"}]}})
emit({"type": "result", "subtype": "success", "is_error": False})
PY

# Present on PATH but broken: exits non-zero with nothing on stdout. Auth failure, bad flag,
# untrusted directory. This is the case that MUST NOT read as a 0% trigger rate.
cat > "$TMP/bin/claude-dead" <<PY
#!$PY
import sys
sys.stderr.write("Invalid API key. Please run /login.\n")
sys.exit(1)
PY

for f in claude-fires claude-declines claude-dead; do
  chmod +x "$TMP/bin/$f"
done

# on_path <fake> -- install a fake as `claude` in its own PATH-front directory, echo that dir
on_path() {
  local dir="$TMP/path-$1"
  mkdir -p "$dir"
  cp "$TMP/bin/$1" "$dir/claude"
  chmod +x "$dir/claude"
  printf '%s' "$dir"
}

run_trigger() {  # run_trigger <path-prefix-dir> <out.json> [extra args...]
  local pathdir="$1" out="$2"; shift 2
  env PATH="$pathdir:$SAFEPATH" "$PY" "$SELF_DIR/trigger_rate.py" \
    --skill "$TMP/fixtures/skill" \
    --eval-set "$TMP/fixtures/evalset.json" \
    --runs-per-query 2 --workers 2 --timeout 15 --quiet \
    --out "$out" "$@" >"$out.stdout" 2>"$out.stderr"
}

# ================================================================ 1. the contract holds
printf '\n1. contract and schema\n'

t="committed schemas match what contract.py generates"
if (cd "$SELF_DIR" && "$PY" contract_schema.py >/dev/null 2>&1); then
  pass "$t"
else
  fail "$t" "run: python3 contract_schema.py --write"
fi

cat > "$TMP/bin/invariant.py" <<'PY'
"""The load-bearing contract invariant: an unmeasured query may not carry a numeric rate."""
import sys
sys.path.insert(0, sys.argv[1])
import contract

base = {
    "contract_version": contract.CONTRACT_VERSION, "kind": contract.KIND_TRIGGER,
    "status": "ok", "skill_name": "x", "description": "d", "runs_per_query": 3,
    "trigger_threshold": 0.5,
    "sessions": {"planned": 3, "run": 3, **{k: 0 for k in contract.OUTCOMES}},
    "summary": {"total": 1, "passed": 0, "failed": 0, "unmeasured": 1},
    "queries": [{
        "query": "q", "should_trigger": True, "measured": False,
        "trigger_rate": 0.0,                      # <- the defect: a zero that is not a measurement
        "usable_runs": 0,
        "outcomes": {k: 0 for k in contract.OUTCOMES}, "pass": None,
    }],
}
defects = contract.validate_trigger_report(base)
assert any("measured=false" in d for d in defects), f"invariant not enforced: {defects}"

base["queries"][0]["trigger_rate"] = None
assert contract.validate_trigger_report(base) == [], contract.validate_trigger_report(base)

# And the rate helper itself must return None, never 0.0, with nothing countable.
assert contract.trigger_rate({k: 0 for k in contract.OUTCOMES}) is None
assert contract.trigger_rate({contract.UNREACHABLE: 5}) is None
assert contract.trigger_rate({contract.TRIGGERED: 0, contract.NOT_TRIGGERED: 4}) == 0.0
print("ok")
PY

t="an unmeasured query carrying a 0.0 rate is a contract defect"
if out="$("$PY" "$TMP/bin/invariant.py" "$SELF_DIR" 2>&1)"; then
  pass "$t"
else
  fail "$t" "$out"
fi

# ================================================================ 2. DEFECT PLANT: schema drift
printf '\n2. defect plant: committed schema drifts from contract.py\n'

cp -R "$SELF_DIR" "$TMP/planted"
rm -rf "$TMP/planted/__pycache__"
# Add a required key to the contract without regenerating the committed schema.
"$PY" - "$TMP/planted/contract.py" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
before = 'TRIGGER_SUMMARY_REQUIRED = ("total", "passed", "failed", "unmeasured")'
assert before in src, "test fixture is stale: the anchor line moved"
open(p, "w").write(src.replace(before, before[:-1] + ', "planted_defect")'))
PY

t="the drift gate goes red when contract.py changes and schemas/ does not"
(cd "$TMP/planted" && "$PY" contract_schema.py >"$TMP/planted.out" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SCHEMA DRIFT" "$TMP/planted.out"; then
  pass "$t (exit $rc)"
else
  fail "$t" "expected non-zero + 'SCHEMA DRIFT', got exit $rc: $(cat "$TMP/planted.out")"
fi

t="the same gate is green on the unplanted tree"
if (cd "$SELF_DIR" && "$PY" contract_schema.py >/dev/null 2>&1); then
  pass "$t"
else
  fail "$t" "the gate is red before any defect was planted"
fi

# ================================================================ 3. unreachable is not zero
printf '\n3. cannot-reach-claude is distinguishable from a genuine zero\n'

NO_CLAUDE="$TMP/empty"
run_trigger "$NO_CLAUDE" "$TMP/absent.json"
ABSENT_RC=$?

DEAD_DIR="$(on_path claude-dead)"
run_trigger "$DEAD_DIR" "$TMP/dead.json"
DEAD_RC=$?

DECLINE_DIR="$(on_path claude-declines)"
run_trigger "$DECLINE_DIR" "$TMP/zero.json"
ZERO_RC=$?

FIRE_DIR="$(on_path claude-fires)"
run_trigger "$FIRE_DIR" "$TMP/fire.json"
FIRE_RC=$?

t="no claude on PATH exits 3 (EXIT_UNREACHABLE), not 0 or 1"
if [ "$ABSENT_RC" -eq 3 ]; then pass "$t"; else fail "$t" "exit $ABSENT_RC: $(cat "$TMP/absent.json.stderr")"; fi

t="no claude on PATH writes NO report at all"
if [ ! -s "$TMP/absent.json" ]; then pass "$t"; else fail "$t" "a report was written: $(cat "$TMP/absent.json")"; fi

t="no claude on PATH says so in plain words"
if grep -qi "not a 0% trigger rate" "$TMP/absent.json.stderr"; then
  pass "$t"
else
  fail "$t" "stderr never distinguishes it: $(cat "$TMP/absent.json.stderr")"
fi

t="a claude that exits non-zero with no output also exits 3"
if [ "$DEAD_RC" -eq 3 ]; then pass "$t"; else fail "$t" "exit $DEAD_RC"; fi

t="the dead-binary report is marked unusable, not a measurement"
if [ -s "$TMP/dead.json" ]; then
  status="$("$PY" "$TMP/bin/jget.py" "$TMP/dead.json" status)"
  rate="$("$PY" "$TMP/bin/jget.py" "$TMP/dead.json" queries.0.trigger_rate)"
  if [ "$status" = '"unusable"' ] && [ "$rate" = "null" ]; then
    pass "$t (status=$status, rate=$rate)"
  else
    fail "$t" "status=$status rate=$rate — a null rate is required here"
  fi
else
  pass "$t (no report emitted at all, which is stronger)"
fi

t="the dead binary's stderr is surfaced, not swallowed"
if grep -qi "Invalid API key" "$TMP/dead.json.stderr"; then
  pass "$t"
else
  fail "$t" "the child's stderr never reached the operator: $(head -c 400 "$TMP/dead.json.stderr")"
fi

t="a working claude that declines the skill exits 1 (a real measurement)"
if [ "$ZERO_RC" -eq 1 ]; then pass "$t"; else fail "$t" "exit $ZERO_RC: $(cat "$TMP/zero.json.stderr")"; fi

t="the genuine zero reports status=ok and a rate of 0.0, NOT null"
status="$("$PY" "$TMP/bin/jget.py" "$TMP/zero.json" status 2>&1)"
rate="$("$PY" "$TMP/bin/jget.py" "$TMP/zero.json" queries.0.trigger_rate 2>&1)"
if [ "$status" = '"ok"' ] && [ "$rate" = "0.0" ]; then
  pass "$t"
else
  fail "$t" "status=$status rate=$rate"
fi

t="the three outcomes are mutually distinguishable (3 / 3 / 1)"
if [ "$ABSENT_RC" -eq 3 ] && [ "$DEAD_RC" -eq 3 ] && [ "$ZERO_RC" -eq 1 ] && [ "$ABSENT_RC" -ne "$ZERO_RC" ]; then
  pass "$t (absent=$ABSENT_RC dead=$DEAD_RC genuine-zero=$ZERO_RC)"
else
  fail "$t" "absent=$ABSENT_RC dead=$DEAD_RC genuine-zero=$ZERO_RC"
fi

# ================================================================ 4. detection actually works
printf '\n4. the detector reads a real trigger out of the stream\n'

t="a Skill call carrying the probe name is detected across split JSON fragments"
if [ -s "$TMP/fire.json" ]; then
  rate="$("$PY" "$TMP/bin/jget.py" "$TMP/fire.json" queries.0.trigger_rate)"
  if [ "$rate" = "1.0" ]; then pass "$t"; else fail "$t" "rate=$rate, expected 1.0"; fi
else
  fail "$t" "no report: $(cat "$TMP/fire.json.stderr")"
fi

t="over-triggering is caught: the should-NOT-trigger queries fail"
if [ -s "$TMP/fire.json" ]; then
  failed="$("$PY" "$TMP/bin/jget.py" "$TMP/fire.json" summary.failed)"
  if [ "$failed" = "2" ]; then pass "$t"; else fail "$t" "summary.failed=$failed, expected 2"; fi
else
  fail "$t" "no report"
fi

t="always-fires and never-fires produce opposite reports"
if [ -s "$TMP/fire.json" ] && [ -s "$TMP/zero.json" ]; then
  a="$("$PY" "$TMP/bin/jget.py" "$TMP/fire.json" queries.0.trigger_rate)"
  b="$("$PY" "$TMP/bin/jget.py" "$TMP/zero.json" queries.0.trigger_rate)"
  if [ "$a" = "1.0" ] && [ "$b" = "0.0" ]; then pass "$t"; else fail "$t" "fire=$a decline=$b"; fi
else
  fail "$t" "a report is missing"
fi

t="the harness validates its own output against the contract"
if [ -s "$TMP/fire.json" ] && (cd "$SELF_DIR" && "$PY" contract_schema.py --validate "$TMP/fire.json" >/dev/null 2>&1); then
  pass "$t"
else
  fail "$t" "the emitted report does not honour its own contract"
fi

# ================================================================ 5. the holdout
printf '\n5. the holdout is actually held out\n'

cat > "$TMP/bin/holdout.py" <<'PY'
"""Split, blinding, and winner-selection properties — plus the planted overfitting defect."""
import sys
sys.path.insert(0, sys.argv[1])
import optimize_description as opt

EVALS = [{"query": f"pos-{i}", "should_trigger": True} for i in range(6)]
EVALS += [{"query": f"neg-{i}", "should_trigger": False} for i in range(4)]

train, test = opt.split_eval_set(EVALS, holdout=0.4)

tq = {q["query"] for q in train}
sq = {q["query"] for q in test}
assert tq and sq, "one side of the split is empty"
assert not (tq & sq), f"train and test overlap: {tq & sq}"
assert tq | sq == {e["query"] for e in EVALS}, "the split lost or invented queries"

for side, name in ((train, "train"), (test, "test")):
    assert any(q["should_trigger"] for q in side), f"{name} has no positive cases"
    assert any(not q["should_trigger"] for q in side), f"{name} has no negative cases"

again = opt.split_eval_set(EVALS, holdout=0.4)
assert again == (train, test), "the seeded split is not reproducible"
other = opt.split_eval_set(EVALS, holdout=0.4, seed=7)
assert other != (train, test), "the seed does nothing"

# Every class keeps at least one member in train, even at an extreme holdout.
t2, s2 = opt.split_eval_set(EVALS, holdout=0.99)
assert any(q["should_trigger"] for q in t2) and any(not q["should_trigger"] for q in t2), \
    "an extreme holdout emptied a class out of train"

# --- the improver must never see the holdout -------------------------------------------------
history = [{"iteration": 1, "description": "d1", "train_passed": 1, "train_total": 3,
            "test_passed": 3, "test_total": 4, "test_queries": [{"query": "pos-0"}]}]
blinded = opt.blind_history(history)
assert not any(k.startswith("test_") for h in blinded for k in h), f"test keys leaked: {blinded}"

train_report = {
    "runs_per_query": 3,
    "summary": {"total": len(train), "passed": 0, "failed": len(train)},
    "queries": [{"query": q["query"], "should_trigger": q["should_trigger"], "pass": False,
                 "usable_runs": 3, "outcomes": {"triggered": 0}} for q in train],
}
prompt = opt.build_improve_prompt("s", "body", "current", train_report, blinded)
leaked = [q["query"] for q in test if q["query"] in prompt]
assert not leaked, f"held-out queries appeared in the improver prompt: {leaked}"

# --- winner selection: BY TEST SCORE, never by train -------------------------------------------
# Iteration 1 aces train and fails test: the signature of a description fitted to its own eval set.
# Iteration 2 is worse on train and better on the holdout, and is the one worth shipping.
h = [
    {"iteration": 1, "description": "overfitted", "train_passed": 10, "train_total": 10,
     "test_passed": 1, "test_total": 5},
    {"iteration": 2, "description": "generalising", "train_passed": 4, "train_total": 10,
     "test_passed": 5, "test_total": 5},
]
best = opt.select_best(h)
assert best["iteration"] == 2, f"select_best chose iteration {best['iteration']} — it read train"
assert best["description"] == "generalising"

# THE PLANTED DEFECT: the train-selecting variant somebody would write by accident.
def select_best_by_train(history):
    return max(history, key=lambda x: x["train_passed"])

planted = select_best_by_train(h)
assert planted["iteration"] == 1, "fixture is degenerate — the two selectors agree"
assert planted["iteration"] != best["iteration"], \
    "this assertion cannot discriminate: train- and test-selection pick the same winner"

# With no holdout at all, train is the only thing left — and the caller is told so.
no_test = [{"iteration": 1, "description": "a", "train_passed": 2, "train_total": 3,
            "test_passed": None, "test_total": None},
           {"iteration": 2, "description": "b", "train_passed": 3, "train_total": 3,
            "test_passed": None, "test_total": None}]
assert opt.select_best(no_test)["iteration"] == 2

# An eval set too small to split is refused rather than silently run without a holdout.
assert opt.split_defects([{"query": "a", "should_trigger": True},
                          {"query": "b", "should_trigger": False}], 0.4), \
    "a 1-per-class eval set was accepted for a holdout"
assert opt.split_defects(EVALS, 0.4) == []
print("ok")
PY

t="split is disjoint, stratified, seeded, and keeps every class in train"
if out="$("$PY" "$TMP/bin/holdout.py" "$SELF_DIR" 2>&1)"; then
  pass "$t"
  pass "the improver prompt contains no held-out query"
  pass "select_best picks the held-out winner, not the train winner (defect plant discriminates)"
else
  fail "$t" "$out"
fi

t="a too-small eval set is refused before any session is spawned"
cat > "$TMP/fixtures/tiny.json" <<'JSON'
[{"query": "a", "should_trigger": true}, {"query": "b", "should_trigger": false}]
JSON
env PATH="$FIRE_DIR:$SAFEPATH" "$PY" "$SELF_DIR/optimize_description.py" \
  --skill "$TMP/fixtures/skill" --eval-set "$TMP/fixtures/tiny.json" \
  >"$TMP/tiny.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "$t (exit 2)"; else fail "$t" "exit $rc: $(cat "$TMP/tiny.out")"; fi

# ================================================================ 6. dry run spends nothing
printf '\n6. dry run spends nothing\n'

SENTINEL="$TMP/spawned.flag"
rm -f "$SENTINEL"
env PATH="$FIRE_DIR:$SAFEPATH" EVAL_TEST_SENTINEL="$SENTINEL" "$PY" \
  "$SELF_DIR/trigger_rate.py" --skill "$TMP/fixtures/skill" \
  --eval-set "$TMP/fixtures/evalset.json" --dry-run >"$TMP/dry.out" 2>&1
rc=$?

t="--dry-run exits 0"
if [ "$rc" -eq 0 ]; then pass "$t"; else fail "$t" "exit $rc: $(cat "$TMP/dry.out")"; fi

t="--dry-run spawns no session at all"
if [ ! -e "$SENTINEL" ]; then pass "$t"; else fail "$t" "a session was spawned during a dry run"; fi

t="--dry-run states the session count before anything could be spent"
if grep -q "CLAUDE SESSIONS  12" "$TMP/dry.out"; then
  pass "$t"
else
  fail "$t" "no session count in the plan: $(cat "$TMP/dry.out")"
fi

t="the optimiser's dry run prints the plan and the held-out queries"
rm -f "$SENTINEL"
env PATH="$FIRE_DIR:$SAFEPATH" EVAL_TEST_SENTINEL="$SENTINEL" "$PY" \
  "$SELF_DIR/optimize_description.py" --skill "$TMP/fixtures/skill" \
  --eval-set "$TMP/fixtures/evalset.json" --dry-run >"$TMP/dryopt.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$SENTINEL" ] && grep -q "held out" "$TMP/dryopt.out"; then
  pass "$t"
else
  fail "$t" "exit $rc, sentinel=$([ -e "$SENTINEL" ] && echo present || echo absent)"
fi

t="a dry run with no claude on PATH still exits 0 and says a real run would not"
env PATH="$NO_CLAUDE:$SAFEPATH" "$PY" "$SELF_DIR/trigger_rate.py" --skill "$TMP/fixtures/skill" \
  --eval-set "$TMP/fixtures/evalset.json" --dry-run >"$TMP/drync.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q "NOT FOUND" "$TMP/drync.out"; then
  pass "$t"
else
  fail "$t" "exit $rc: $(cat "$TMP/drync.out")"
fi

# ================================================================ 7. aggregation and the delta
printf '\n7. aggregation, sample stddev, and the baseline delta\n'

cat > "$TMP/fixtures/runs.json" <<'JSON'
[
  {"eval_id": 1, "arm": "with_skill",    "run_number": 1, "pass_rate": 0.9, "duration_seconds": 40, "tokens": 4000},
  {"eval_id": 1, "arm": "with_skill",    "run_number": 2, "pass_rate": 0.8, "duration_seconds": 50, "tokens": 4200},
  {"eval_id": 1, "arm": "with_skill",    "run_number": 3, "pass_rate": 1.0, "duration_seconds": 45, "tokens": 3800},
  {"eval_id": 1, "arm": "without_skill", "run_number": 1, "pass_rate": 0.4, "duration_seconds": 30, "tokens": 2000},
  {"eval_id": 1, "arm": "without_skill", "run_number": 2, "pass_rate": 0.3, "duration_seconds": 32, "tokens": 2100},
  {"eval_id": 1, "arm": "without_skill", "run_number": 3, "pass_rate": 0.5, "duration_seconds": 28, "tokens": 1900}
]
JSON

"$PY" "$SELF_DIR/aggregate.py" --runs "$TMP/fixtures/runs.json" --skill-name ledger-reconciliation \
  --out "$TMP/bench.json" --markdown "$TMP/bench.md" >"$TMP/bench.out" 2>&1
rc=$?

t="a benchmark with both arms aggregates and exits 0"
if [ "$rc" -eq 0 ]; then pass "$t"; else fail "$t" "exit $rc: $(cat "$TMP/bench.out")"; fi

t="the delta is with_skill minus without_skill"
d="$("$PY" "$TMP/bin/jget.py" "$TMP/bench.json" delta.pass_rate.display 2>&1)"
if [ "$d" = '"+0.50"' ]; then pass "$t ($d)"; else fail "$t" "delta=$d, expected \"+0.50\""; fi

t="stddev is the SAMPLE formula (n-1), not the population one"
s="$("$PY" "$TMP/bin/jget.py" "$TMP/bench.json" arms.with_skill.pass_rate.stddev 2>&1)"
# values 0.9/0.8/1.0: sample sd = 0.1 exactly; population sd would be 0.0816.
if [ "$s" = "0.1" ]; then pass "$t (stddev=$s)"; else fail "$t" "stddev=$s, expected 0.1"; fi

t="the benchmark report honours its own contract"
if (cd "$SELF_DIR" && "$PY" contract_schema.py --validate "$TMP/bench.json" >/dev/null 2>&1); then
  pass "$t"
else
  fail "$t" "emitted report violates the benchmark contract"
fi

t="a benchmark with no baseline arm is refused (exit 2), not reported as a win"
cat > "$TMP/fixtures/nobaseline.json" <<'JSON'
[{"eval_id": 1, "arm": "with_skill", "run_number": 1, "pass_rate": 0.9}]
JSON
"$PY" "$SELF_DIR/aggregate.py" --runs "$TMP/fixtures/nobaseline.json" \
  --skill-name ledger-reconciliation >"$TMP/nb.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q "does not show the skill did anything" "$TMP/nb.out"; then
  pass "$t"
else
  fail "$t" "exit $rc: $(cat "$TMP/nb.out")"
fi

t="a skill that does not beat its baseline exits 1"
cat > "$TMP/fixtures/nogain.json" <<'JSON'
[
  {"eval_id": 1, "arm": "with_skill",    "run_number": 1, "pass_rate": 0.9},
  {"eval_id": 1, "arm": "without_skill", "run_number": 1, "pass_rate": 0.9}
]
JSON
"$PY" "$SELF_DIR/aggregate.py" --runs "$TMP/fixtures/nogain.json" \
  --skill-name ledger-reconciliation --out "$TMP/nogain.json" >"$TMP/ng.out" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -qi "no demonstrated benefit" "$TMP/ng.out"; then
  pass "$t"
else
  fail "$t" "exit $rc: $(cat "$TMP/ng.out")"
fi

t="a Markdown summary is produced instead of an HTML viewer"
if [ -s "$TMP/bench.md" ] && grep -q "Without skill" "$TMP/bench.md"; then
  pass "$t"
else
  fail "$t" "no usable Markdown summary"
fi

# ================================================================ 8. input validation
printf '\n8. eval-set validation refuses to measure the unmeasurable\n'

t="an eval set with no negative cases is refused (exit 2)"
cat > "$TMP/fixtures/allpos.json" <<'JSON'
[{"query": "a", "should_trigger": true}, {"query": "b", "should_trigger": true}]
JSON
run_trigger "$FIRE_DIR" "$TMP/allpos.out.json" 2>/dev/null
env PATH="$FIRE_DIR:$SAFEPATH" "$PY" "$SELF_DIR/trigger_rate.py" \
  --skill "$TMP/fixtures/skill" --eval-set "$TMP/fixtures/allpos.json" \
  >"$TMP/allpos.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q "over-triggering" "$TMP/allpos.out"; then
  pass "$t"
else
  fail "$t" "exit $rc: $(cat "$TMP/allpos.out")"
fi

t="a SKILL.md with no frontmatter is refused (exit 2), not measured"
mkdir -p "$TMP/fixtures/broken"
printf '# no frontmatter here\n' > "$TMP/fixtures/broken/SKILL.md"
env PATH="$FIRE_DIR:$SAFEPATH" "$PY" "$SELF_DIR/trigger_rate.py" \
  --skill "$TMP/fixtures/broken" --eval-set "$TMP/fixtures/evalset.json" \
  >"$TMP/broken.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "$t"; else fail "$t" "exit $rc: $(cat "$TMP/broken.out")"; fi

t="a description over the character limit is refused, not silently truncated"
long="$("$PY" -c 'print("x" * 1100)')"
env PATH="$FIRE_DIR:$SAFEPATH" "$PY" "$SELF_DIR/trigger_rate.py" \
  --skill "$TMP/fixtures/skill" --eval-set "$TMP/fixtures/evalset.json" \
  --description "$long" >"$TMP/long.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q "truncates" "$TMP/long.out"; then
  pass "$t"
else
  fail "$t" "exit $rc: $(cat "$TMP/long.out")"
fi

# ================================================================
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
