#!/usr/bin/env bash
# contract.test.sh — the SCHEMA DRIFT GUARD, plus the generator invariants it rests on.
#
#   bash pipeline/contract.test.sh
#   zsh  pipeline/contract.test.sh
#
# `schemas/agent-contract.schema.json` is a BUILD ARTIFACT of `contract.py`'s `contract_schema()`.
# Its own header says so — "GENERATED from contract.py's constants; do not hand-edit" — and the
# docstring promises "there is no cached or committed copy that can drift ... a gate asserts the two
# are identical". This file IS that gate. Without it the promise is prose: a committed schema is
# exactly a cached copy, and the only thing stopping it drifting from the constants it claims to
# describe is somebody remembering to regenerate it.
#
# The drift is not cosmetic. The schema is what a consumer outside this pipeline validates a
# contract document against — an agent's own artifact, a CI job reading VALIDATED.json, a second
# implementation. A stale copy either rejects documents the pipeline now emits (a new severity, a
# new required key) or accepts ones it now rejects. Both read as a bug in the producer.
#
# Everything below is pure computation over two files; nothing is written outside $TMP.
#
# Portable bash 3.2+ / zsh.

# Keep test runs from leaving __pycache__ inside the plugin tree.
export PYTHONDONTWRITEBYTECODE=1

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONTRACT="$SELF_DIR/contract.py"
SCHEMA="$SELF_DIR/schemas/agent-contract.schema.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/contract-schema-test.XXXXXX")"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skipt() { SKIP=$((SKIP + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

printf 'contract/schema tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

command -v python3 >/dev/null 2>&1 || {
  fail "python3 is available" "python3 not on PATH — this suite cannot run"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
}

# py <file> — run a python program from a FILE, never from an interpolated string. A `python3 -c`
# body in double quotes is still subject to bash expansion (backticks, `$`), which is how a comment
# inside one of these bodies once became a command substitution.
py() { python3 "$@"; }

# ---------------------------------------------------------------- the files exist at all
t="contract.py and the generated schema both exist"
if [ -f "$CONTRACT" ] && [ -f "$SCHEMA" ]; then
  pass "$t"
else
  fail "$t" "missing: $([ -f "$CONTRACT" ] || printf '%s ' "$CONTRACT")$([ -f "$SCHEMA" ] || printf '%s' "$SCHEMA")"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi

# ---------------------------------------------------------------- THE DRIFT GATE
cat > "$TMP/drift.py" <<'PY'
"""Compare the committed schema with the one contract_schema() generates right now."""
import importlib.util
import json
import sys

contract_path, schema_path = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location("contract_under_test", contract_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

generated = mod.contract_schema()
try:
    with open(schema_path) as fh:
        committed = json.load(fh)
except ValueError as exc:
    print(f"the committed schema is not valid JSON: {exc}")
    sys.exit(2)

if generated == committed:
    print("identical")
    sys.exit(0)


def walk(a, b, path=""):
    """Yield a human-readable line per difference, deepest-specific first."""
    if type(a) is not type(b):
        yield f"{path or '<root>'}: generated is {type(a).__name__}, committed is {type(b).__name__}"
        return
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            sub = f"{path}.{k}" if path else k
            if k not in b:
                yield f"{sub}: present in the generator, ABSENT from the committed schema"
            elif k not in a:
                yield f"{sub}: present in the committed schema, ABSENT from the generator"
            else:
                for line in walk(a[k], b[k], sub):
                    yield line
    elif isinstance(a, list):
        if a != b:
            yield f"{path or '<root>'}: generated {a!r} != committed {b!r}"
    elif a != b:
        yield f"{path or '<root>'}: generated {a!r} != committed {b!r}"


diffs = list(walk(generated, committed))
print("DRIFTED: " + "; ".join(diffs[:8]) + (" ..." if len(diffs) > 8 else ""))
sys.exit(1)
PY

t="the committed schema is byte-for-byte what contract_schema() generates"
out="$(py "$TMP/drift.py" "$CONTRACT" "$SCHEMA" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "$t"
else
  # The failure message carries the fix.
  fail "$t" "$out
     Regenerate with: python3 \"$CONTRACT\" schema --write"
fi

# ---------------------------------------------------------------- PROVE THE GATE CAN FAIL
# A drift gate that has only ever seen an in-sync pair proves nothing: a comparison that always
# returns "identical" (a `==` accidentally written over two copies of the same object, an exception
# swallowed into a pass) is indistinguishable from a repository that is in sync. Perturb a COPY of
# the committed schema and assert the gate rejects it.
t="the drift gate rejects a schema that has been edited by hand"
cat > "$TMP/perturb.py" <<'PY'
import json
import sys

src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(src))
if mode == "add-required":
    doc["required"] = list(doc.get("required") or []) + ["a_key_the_generator_never_emits"]
elif mode == "drop-property":
    props = doc.get("properties") or {}
    for k in ("findings", "metrics", "verdict", "agent"):
        if k in props:
            del props[k]
            break
elif mode == "retitle":
    doc["title"] = "Hand-edited title"
elif mode == "narrow-enum":
    # The shape a stale copy really takes: a severity tier added to contract.py after the schema
    # was last written.
    sev = (((doc.get("properties") or {}).get("findings") or {}).get("items") or {})
    sev = ((sev.get("properties") or {}).get("severity") or {})
    if isinstance(sev.get("enum"), list) and sev["enum"]:
        sev["enum"] = sev["enum"][:-1]
json.dump(doc, open(dst, "w"), indent=2)
PY

caught=""
for mode in add-required drop-property retitle narrow-enum; do
  py "$TMP/perturb.py" "$SCHEMA" "$TMP/perturbed-$mode.json" "$mode" || { caught="$caught perturb-failed:$mode"; continue; }
  if py "$TMP/drift.py" "$CONTRACT" "$TMP/perturbed-$mode.json" >/dev/null 2>&1; then
    caught="$caught NOT-CAUGHT:$mode"
  fi
done
if [ -z "$caught" ]; then
  pass "$t (all four hand-edit shapes are rejected)"
else
  fail "$t" "the gate accepted a drifted schema:$caught"
fi

t="the drift gate refuses a schema file that is not valid JSON"
# The other way a gate goes quiet: an exception caught and reported as a pass. Exit 2, not 0.
printf '{ this is not json' > "$TMP/broken.json"
py "$TMP/drift.py" "$CONTRACT" "$TMP/broken.json" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then pass "$t"; else fail "$t" "a malformed schema was accepted as in-sync"; fi

# ---------------------------------------------------------------- the generator's own invariants
# The gate above only says the two agree. These say the thing they agree ON is still the contract
# the rest of the pipeline implements — a generator that dropped `findings` from `required` would
# keep this suite green after a regeneration, and the schema would validate documents with no
# findings key at all.
cat > "$TMP/invariants.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("contract_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
s = mod.contract_schema()

problems = []


def check(cond, msg):
    if not cond:
        problems.append(msg)


check(s.get("$schema"), "no $schema keyword — the document does not declare its dialect")
check(s.get("type") == "object", "the root type is not object")

# The schema DEFERS to the constants rather than restating them; that deferral is the whole reason
# it can be generated. Assert the tables actually reached the output.
check(list(s.get("required") or []) == list(mod.DOCUMENT_REQUIRED),
      "root `required` is not DOCUMENT_REQUIRED")

props = s.get("properties") or {}
check("findings" in props, "no `findings` property")
item = ((props.get("findings") or {}).get("items") or {})
check(list(item.get("required") or []) == list(mod.CONTRACT_REQUIRED),
      "finding `required` is not CONTRACT_REQUIRED")

sev = (item.get("properties") or {}).get("severity") or {}
check(list(sev.get("enum") or []) == list(mod.SEVERITY_RANK),
      f"severity enum {sev.get('enum')} is not the rank table {list(mod.SEVERITY_RANK)}")

conf = (item.get("properties") or {}).get("confidence") or {}
check(list(conf.get("enum") or []) == list(mod.CONFIDENCES),
      "confidence enum is not CONFIDENCES")

verdict = props.get("verdict") or {}
check(list(verdict.get("enum") or []) == list(mod.VERDICTS),
      "verdict enum is not VERDICTS")

title = (item.get("properties") or {}).get("title") or {}
check(title.get("maxLength") == mod.TITLE_MAX,
      f"title maxLength {title.get('maxLength')} is not TITLE_MAX {mod.TITLE_MAX}")

# Every boolean key the repair pass coerces must be declared, or a document carrying the string
# "false" would validate against a schema that never mentions the key.
for k in sorted(mod._BOOLS):
    check((item.get("properties") or {}).get(k, {}).get("type") == "boolean",
          f"_BOOLS member {k!r} is not declared boolean in the schema")

# additionalProperties: true is a DECISION, stated in the generator's own comment ("an agent adding
# a field is not a defect worth failing a review over"). Flipping it would make every future field a
# breaking change to a contract several agents already implement, so it is pinned here rather than
# left to be quietly tightened.
check(s.get("additionalProperties") is True,
      "root additionalProperties is no longer true — every new field becomes a breaking change")
check(item.get("additionalProperties") is True,
      "finding additionalProperties is no longer true")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print("ok")
PY

t="the generated schema still defers to contract.py's constants rather than restating them"
out="$(py "$TMP/invariants.py" "$CONTRACT" 2>&1)"
if [ "$out" = "ok" ]; then pass "$t"; else fail "$t" "$out"; fi

t="contract_schema() is deterministic across calls"
# It is generated on every call from module state. If two calls in one process disagree, the gate
# above is comparing against a coin flip and a green run means nothing.
cat > "$TMP/determinism.py" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("contract_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
a = json.dumps(mod.contract_schema(), sort_keys=True)
b = json.dumps(mod.contract_schema(), sort_keys=True)
print("ok" if a == b else "two calls disagreed")
PY
out="$(py "$TMP/determinism.py" "$CONTRACT" 2>&1)"
if [ "$out" = "ok" ]; then pass "$t"; else fail "$t" "$out"; fi

# ---------------------------------------------------------------- normalize.py re-export parity
# normalize.py re-exports contract.py's names so the suites (and any consumer) can reach them
# without importing past it. A name removed from that list fails at import time only when the
# importing code runs — which for a helper used on one branch means "not in any test".
t="every contract name normalize.py re-exports still exists in contract.py"
cat > "$TMP/reexport.py" <<'PY'
import importlib.util
import re
import sys

norm_path, contract_path = sys.argv[1], sys.argv[2]
src = open(norm_path, encoding="utf-8", errors="replace").read()
m = re.search(r"from contract import \((.*?)\n\)", src, re.S)
if not m:
    sys.exit("no `from contract import (...)` block found in normalize.py")
names = []
for line in m.group(1).split("\n"):
    line = line.split("#", 1)[0].strip().rstrip(",")
    if line:
        names.append(line)
if not names:
    sys.exit("the import block parsed to zero names — this check would be vacuous")

spec = importlib.util.spec_from_file_location("contract_under_test", contract_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
missing = [n for n in names if not hasattr(mod, n)]
if missing:
    sys.exit(f"contract.py does not define: {missing}")
print(f"ok {len(names)}")
PY
out="$(py "$TMP/reexport.py" "$SELF_DIR/normalize.py" "$CONTRACT" 2>&1)"
case "$out" in
  ok\ *) pass "$t ($out)" ;;
  *) fail "$t" "$out" ;;
esac

t="the re-export check would notice a name that no longer exists"
# Same reasoning as the drift perturbation: prove the checker can say no. A copy of normalize.py
# with one extra name in the import block must be rejected.
cp "$SELF_DIR/normalize.py" "$TMP/normalize-broken.py"
py - "$TMP/normalize-broken.py" <<'PY'
import re
import sys

p = sys.argv[1]
src = open(p, encoding="utf-8").read()
src = src.replace("from contract import (  # noqa: F401",
                  "from contract import (  # noqa: F401\n    a_name_contract_py_does_not_define,", 1)
open(p, "w", encoding="utf-8").write(src)
PY
if py "$TMP/reexport.py" "$TMP/normalize-broken.py" "$CONTRACT" >/dev/null 2>&1; then
  fail "$t" "the checker accepted an import of a name contract.py does not define"
else
  pass "$t"
fi

# ---------------------------------------------------------------- the decisions schema
# Same drift rule as the contract schema: the committed file is generated by decisions_schema(), and
# the enums the validator prompt is told to use must be the ones finalize enforces.
DECISIONS_SCHEMA="$SELF_DIR/schemas/validator-decisions.schema.json"
cat > "$TMP/decisions-drift.py" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("contract_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    committed = json.load(open(sys.argv[2]))
except (OSError, ValueError) as exc:
    sys.exit(f"cannot read the committed decisions schema: {exc}")
if committed != mod.decisions_schema():
    sys.exit("DRIFTED: regenerate with python3 pipeline/contract.py schema --write")
item = committed["properties"]["decisions"]["items"]["properties"]
problems = []
for key, const in (("source", "DECISION_SOURCES"), ("action", "DECISION_ACTIONS"),
                   ("reason", "REJECT_REASONS")):
    if item[key]["enum"] != list(getattr(mod, const)):
        problems.append(f"{key} enum is not {const}")
if "OUT_OF_DIFF" in mod.REJECT_REASONS:
    problems.append("OUT_OF_DIFF is a rejection reason; out-of-diff findings are kept, not removed")
print("; ".join(problems) if problems else "ok")
PY
t="the committed decisions schema matches decisions_schema() and its enums are the constants"
out="$(py "$TMP/decisions-drift.py" "$CONTRACT" "$DECISIONS_SCHEMA" 2>&1)"
if [ "$out" = "ok" ]; then pass "$t"; else fail "$t" "$out"; fi

# ---------------------------------------------------------------- finalize
# Each case builds a fresh .code-review directory, runs `contract.py finalize` as a real process
# (the way the review skill runs it), and asserts on the files it wrote. One driver, one line of
# output per case, so a failure names the case and the reason.
cat > "$TMP/finalize-cases.py" <<'PY'
import json
import os
import subprocess
import sys
import tempfile

CONTRACT = sys.argv[1]
SCHEMA = json.load(open(sys.argv[2]))
WORK = sys.argv[3]   # the suite's $TMP, so its EXIT trap cleans every case up


def finding(fid, sev="MAJOR", loc="src/app.py:10", in_diff=True, conf="HIGH", **extra):
    f = {"id": fid, "severity": sev, "category": "LOGIC", "location": loc, "title": f"title {fid}",
         "evidence": "e", "recommendation": "r", "ux_impact": False, "in_diff": in_diff,
         "confidence": conf}
    f.update(extra)
    return f


def doc(agent, category, findings):
    return {"agent": agent, "category": category, "findings": findings}


CTX = {"source_branch": "feat", "target_branch": "main",
       "worktree": {"matches_reviewed_ref": True}, "diff": {},
       "testing": {"spawn": False}, "architect": {"spawn": False}, "claude_config": {"spawn": False}}


def run(files, args=(), env=None):
    """Write `files` (name -> object, or str for raw text, or None to omit) and run finalize."""
    d = tempfile.mkdtemp(prefix="finalize-", dir=WORK)
    base = {"CONTEXT.json": CTX, "SCAN.json": doc("review-scan", "SCAN", []),
            "SEMANTIC.json": doc("review-semantic", "SEMANTIC", []),
            "VALIDATOR-DECISIONS.json": {"agent": "review-validator", "decisions": []}}
    base.update(files)
    for name, body in base.items():
        if body is None:
            continue
        with open(os.path.join(d, name), "w") as fh:
            fh.write(body if isinstance(body, str) else json.dumps(body))
    e = dict(os.environ)
    e.pop("CODE_REVIEW_BLOCKING_FLOOR", None)
    e.update(env or {})
    p = subprocess.run([sys.executable, CONTRACT, "finalize", "--dir", d, *args],
                       capture_output=True, text=True, env=e)
    out = json.load(open(os.path.join(d, "VALIDATED.json")))
    return p.returncode, out, d


def conforms(v):
    """The schema checks finalize's output must pass, without needing the jsonschema package."""
    req = SCHEMA["properties"]["findings"]["items"]["required"]
    props = SCHEMA["properties"]["findings"]["items"]["properties"]
    for k in SCHEMA["required"] + ["verdict", "metrics"]:
        assert k in v, f"envelope missing {k}"
    assert v["verdict"] in SCHEMA["properties"]["verdict"]["enum"], v["verdict"]
    for f in v["findings"]:
        for k in req:
            assert k in f, f"{f.get('id')} missing {k}"
        assert f["severity"] in props["severity"]["enum"], f["severity"]
        assert f["confidence"] in props["confidence"]["enum"], f["confidence"]
        assert isinstance(f["in_diff"], bool) and isinstance(f["ux_impact"], bool)
        assert len(f["title"]) <= props["title"]["maxLength"]


def decide(*ds):
    return {"agent": "review-validator", "decisions": list(ds)}


def keep(src, sid, **fields):
    d = {"source": src, "source_id": sid, "action": "keep", "detail": "read it"}
    if fields:
        d["finding"] = fields
    return d


cases = []


def case(fn):
    cases.append(fn)
    return fn


@case
def approve_when_clean():
    rc, v, d = run({})
    assert rc == 0 and v["verdict"] == "APPROVE", (rc, v["verdict"])
    assert v["blocking_reason_ids"] == [] and v["incomplete_inputs"] == []
    assert "contract_health" not in v and not os.path.exists(os.path.join(d, "CONTRACT-DEFECTS.md"))
    assert os.path.getsize(os.path.join(d, "VALIDATED.md")) > 0
    conforms(v)


@case
def request_changes_on_a_confirmed_major():
    rc, v, _ = run({"SEMANTIC.json": doc("review-semantic", "SEMANTIC", [finding("SEM-MAJOR-1")]),
                    "VALIDATOR-DECISIONS.json": decide(keep("SEMANTIC", "SEM-MAJOR-1"))})
    assert rc == 0 and v["verdict"] == "REQUEST_CHANGES", v["verdict"]
    assert v["blocking_reason_ids"] == ["VALIDATED-MAJOR-1"], v["blocking_reason_ids"]
    assert v["findings"][0]["source_ids"] == ["SEM-MAJOR-1"]
    conforms(v)


@case
def incomplete_when_semantic_is_missing():
    # A clean scan with the judgement pass missing must never read as APPROVE.
    rc, v, _ = run({"SEMANTIC.json": None})
    assert rc == 2, rc
    assert v["verdict"] == "INCOMPLETE", v["verdict"]
    assert [p["input"] for p in v["incomplete_inputs"]] == ["SEMANTIC.json"], v["incomplete_inputs"]
    conforms(v)


@case
def incomplete_when_a_spawned_gate_left_no_file():
    ctx = dict(CTX, testing={"spawn": True})
    rc, v, _ = run({"CONTEXT.json": ctx})
    assert rc == 2 and v["verdict"] == "INCOMPLETE"
    assert v["incomplete_inputs"][0]["input"] == "TESTING.json", v["incomplete_inputs"]


@case
def architecture_json_is_an_ordinary_source():
    ctx = dict(CTX, architect={"spawn": True})
    arch = doc("review-architect", "ARCHITECTURE", [finding("ARCH-CRITICAL-1", sev="CRITICAL")])
    rc, v, _ = run({"CONTEXT.json": ctx, "ARCHITECTURE.json": arch,
                    "VALIDATOR-DECISIONS.json": decide(keep("ARCHITECTURE", "ARCH-CRITICAL-1"))})
    assert rc == 0, (rc, v["incomplete_inputs"])
    # The architect's intrinsic vocabulary maps 1:1: CRITICAL is BLOCKER.
    assert v["findings"][0]["severity"] == "BLOCKER", v["findings"][0]["severity"]
    assert v["verdict"] == "REQUEST_CHANGES"


@case
def floor_flag_env_and_precedence():
    files = {"SEMANTIC.json": doc("review-semantic", "SEMANTIC", [finding("SEM-MINOR-1", sev="MINOR")]),
             "VALIDATOR-DECISIONS.json": decide(keep("SEMANTIC", "SEM-MINOR-1"))}
    _, v, _ = run(files)
    assert v["verdict"] == "REQUEST_CHANGES" and v["blocking_floor"] == "MINOR", v["verdict"]
    _, v, _ = run(files, args=("--floor", "MAJOR"))
    assert v["verdict"] == "APPROVE" and v["blocking_floor"] == "MAJOR", (v["verdict"], v["blocking_floor"])
    _, v, _ = run(files, env={"CODE_REVIEW_BLOCKING_FLOOR": "MAJOR"})
    assert v["verdict"] == "APPROVE" and v["blocking_floor"] == "MAJOR"
    _, v, _ = run(files, args=("--floor", "MINOR"), env={"CODE_REVIEW_BLOCKING_FLOOR": "BLOCKER"})
    assert v["verdict"] == "REQUEST_CHANGES" and v["blocking_floor"] == "MINOR", "--floor must beat env"
    _, v, _ = run(files, args=("--floor", "typo"))
    assert v["blocking_floor"] == "MINOR" and any("typo" in n.lower() for n in v["coverage_notes"])


@case
def severity_is_normalised_in_findings_and_counts():
    sem = doc("review-semantic", "SEMANTIC", [
        finding("SEM-A", sev="major"), finding("SEM-B", sev="INFO", loc="x.py:2"),
        finding("SEM-C", sev=" Minor ", loc="y.py:3")])
    rc, v, _ = run({"SEMANTIC.json": sem, "VALIDATOR-DECISIONS.json": decide(
        keep("SEMANTIC", "SEM-A"), keep("SEMANTIC", "SEM-B"), keep("SEMANTIC", "SEM-C"))})
    m = v["metrics"]
    assert (m["major"], m["minor"], m["nit"], m["total"]) == (1, 1, 1, 3), m
    assert sorted(f["severity"] for f in v["findings"]) == ["MAJOR", "MINOR", "NIT"]
    assert v["verdict"] == "REQUEST_CHANGES"
    assert v["contract_health"]["repaired"] == 3, v.get("contract_health")
    conforms(v)


@case
def unparseable_decisions_file_is_incomplete():
    rc, v, _ = run({"VALIDATOR-DECISIONS.json": "{ not json"})
    assert rc == 2 and v["verdict"] == "INCOMPLETE"
    assert v["incomplete_inputs"][0]["input"] == "VALIDATOR-DECISIONS.json", v["incomplete_inputs"]


@case
def a_malformed_decision_never_deletes_a_finding():
    sem = doc("review-semantic", "SEMANTIC", [finding("SEM-MAJOR-1")])
    bad = {"source": "SEMANTIC", "source_id": "SEM-MAJOR-1", "action": "reject",
           "reason": "OUT_OF_DIFF"}
    rc, v, _ = run({"SEMANTIC.json": sem, "VALIDATOR-DECISIONS.json": decide(bad, "junk")})
    assert rc == 0, rc
    assert len(v["decision_errors"]) == 2, v["decision_errors"]
    assert v["rejected_count"] == 0 and v["metrics"]["total"] == 1
    # Undecided model judgement: kept, certainty capped, so the review escalates.
    assert v["findings"][0]["confidence"] == "MEDIUM" and v["verdict"] == "INCOMPLETE", v["verdict"]

    # A KEEP whose correction is malformed must not delete the finding either. Each bad correction
    # used to push a confirmed MAJOR into contract_health as unusable, and the verdict became APPROVE.
    for bad_fix in ({"severity": "MAJ"}, {"title": ""}, {"location": ["a.py:1", "b.py:2"]},
                    {"in_diff": "yes"}):
        fix = dict(bad_fix, confidence="HIGH")   # the good correction beside it still applies
        rc, v, _ = run({"SEMANTIC.json": sem,
                        "VALIDATOR-DECISIONS.json": decide(keep("SEMANTIC", "SEM-MAJOR-1", **fix))})
        assert v["metrics"]["total"] == 1 and v["verdict"] == "REQUEST_CHANGES", (bad_fix, v["verdict"])
        k = next(iter(bad_fix))
        assert any(f"correction {k}=" in e["error"] for e in v["decision_errors"]), \
            (bad_fix, v["decision_errors"])
        assert "contract_health" not in v or not v["contract_health"]["defects"], bad_fix


@case
def an_undecided_scan_finding_passes_through_unchanged():
    scan = doc("review-scan", "SCAN", [finding("SCAN-MINOR-1", sev="MINOR", tool="ruff", rule="F401")])
    _, v, _ = run({"SCAN.json": scan})
    f = v["findings"][0]
    assert f["confidence"] == "HIGH" and f["tool"] == "ruff" and v["verdict"] == "REQUEST_CHANGES"


@case
def out_of_diff_blocker_never_blocks():
    # in_diff is not relaxable, at any severity. The old prompt said an out-of-diff CRITICAL blocks;
    # the code never did, and this pins the code's behaviour.
    sem = doc("review-semantic", "SEMANTIC", [finding("SEM-BLOCKER-1", sev="BLOCKER", in_diff=False)])
    _, v, _ = run({"SEMANTIC.json": sem,
                   "VALIDATOR-DECISIONS.json": decide(keep("SEMANTIC", "SEM-BLOCKER-1"))})
    assert v["verdict"] == "APPROVE" and v["metrics"]["blocker"] == 1, v["verdict"]


@case
def rejected_count_comes_from_the_decisions():
    sem = doc("review-semantic", "SEMANTIC", [finding("SEM-1"), finding("SEM-2", loc="b.py:1")])
    ds = decide({"source": "SEMANTIC", "source_id": "SEM-1", "action": "reject",
                 "reason": "INVALID_LOCATION", "detail": "line 10 is blank"},
                {"source": "SEMANTIC", "source_id": "SEM-2", "action": "reject",
                 "reason": "FALSE_POSITIVE", "detail": "guarded at b.py:0"})
    _, v, _ = run({"SEMANTIC.json": sem, "VALIDATOR-DECISIONS.json": ds})
    assert v["rejected_count"] == 2 and v["metrics"]["total"] == 0 and v["verdict"] == "APPROVE"
    assert [a["reason"] for a in v["audit_log"]] == ["INVALID_LOCATION", "FALSE_POSITIVE"]


@case
def merge_keeps_the_higher_severity_and_every_location():
    sem = doc("review-semantic", "SEMANTIC", [finding("SEM-1", sev="MINOR"),
                                              finding("SEM-2", sev="MAJOR", loc="b.py:4")])
    ds = decide(keep("SEMANTIC", "SEM-1"),
                {"source": "SEMANTIC", "source_id": "SEM-2", "action": "merge", "merged_into": "SEM-1"})
    _, v, _ = run({"SEMANTIC.json": sem, "VALIDATOR-DECISIONS.json": ds})
    f = v["findings"][0]
    assert len(v["findings"]) == 1 and f["severity"] == "MAJOR", v["findings"]
    assert f["related_locations"] == ["b.py:4"] and f["source_ids"] == ["SEM-1", "SEM-2"]
    assert v["merged_count"] == 1


@case
def a_contentless_finding_goes_to_the_tooling_owner():
    sem = doc("review-semantic", "SEMANTIC", [{"id": "SEM-X", "severity": "MAJOR", "in_diff": True}])
    _, v, d = run({"SEMANTIC.json": sem, "VALIDATOR-DECISIONS.json": decide(keep("SEMANTIC", "SEM-X"))})
    assert v["metrics"]["total"] == 0 and v["verdict"] == "APPROVE", v["verdict"]
    assert v["contract_health"]["rejected"] == 1
    assert "SEM-X" in open(os.path.join(d, "CONTRACT-DEFECTS.md")).read()


@case
def the_contract_health_key_matches_the_schema():
    props = SCHEMA["properties"]
    for k in ("contract_health", "blocking_floor", "incomplete_inputs", "rejected_count",
              "blocking_reason_ids"):
        assert k in props, f"{k} is not declared in agent-contract.schema.json"


@case
def contract_health_output_has_the_schema_shape():
    # The key being declared is not the same as finalize writing that shape. Produce one repair and
    # one drop, then check the written object against the schema's own description of it.
    sem = doc("review-semantic", "SEMANTIC", [
        finding("SEM-R", sev="major"),                          # repaired: severity case
        {"id": "SEM-X", "severity": "MAJOR", "in_diff": True}])  # dropped: no location, no title
    _, v, _ = run({"SEMANTIC.json": sem, "VALIDATOR-DECISIONS.json": decide(
        keep("SEMANTIC", "SEM-R"), keep("SEMANTIC", "SEM-X"))})
    h, spec = v["contract_health"], SCHEMA["properties"]["contract_health"]
    for k in spec["required"]:
        assert k in h, f"contract_health missing {k}"
    for k, s in spec["properties"].items():
        want = {"integer": int, "array": list}[s["type"]]
        assert isinstance(h[k], want) and not isinstance(h[k], bool), (k, h[k])
        assert h[k] >= s.get("minimum", 0) if want is int else True, (k, h[k])
    assert (h["repaired"], h["rejected"]) == (len(h["repairs"]), len(h["defects"])) == (1, 1), h
    assert h["repairs"][0]["source_id"] == "SEM-R" and h["repairs"][0]["repairs"], h["repairs"]
    d0 = h["defects"][0]
    assert d0["source_id"] == "SEM-X" and d0["defects"] and d0["raw"]["id"] == "SEM-X", d0


@case
def a_dedupe_keeps_the_in_diff_and_higher_confidence_claim():
    # Same location and title from two producers is one finding. The survivor used to be whichever
    # came first, so an out-of-diff or LOW copy absorbed an in-diff HIGH one and the change APPROVED.
    ctx = dict(CTX, testing={"spawn": True})
    for sem_fix, want in (({"in_diff": False}, "REQUEST_CHANGES"),
                          ({"confidence": "LOW"}, "REQUEST_CHANGES")):
        sem = doc("review-semantic", "SEMANTIC", [finding("SEM-1", title="same claim")])
        tst = doc("review-testing", "TESTING", [finding("TEST-1", title="same claim")])
        _, v, _ = run({"CONTEXT.json": ctx, "SEMANTIC.json": sem, "TESTING.json": tst,
                       "VALIDATOR-DECISIONS.json": decide(keep("SEMANTIC", "SEM-1", **sem_fix),
                                                          keep("TESTING", "TEST-1"))})
        assert len(v["findings"]) == 1 and v["verdict"] == want, (sem_fix, v["verdict"], v["findings"])
        f = v["findings"][0]
        assert f["in_diff"] is True and f["confidence"] == "HIGH", (sem_fix, f)
        assert f["source_ids"] == ["SEM-1", "TEST-1"], f["source_ids"]


@case
def a_merge_maps_the_architect_scale_before_folding():
    # `CRITICAL` is the architect's BLOCKER. Folded raw, it read as no severity at all, so a BLOCKER
    # merged into a MINOR stayed MINOR and approved at a MAJOR floor.
    ctx = dict(CTX, architect={"spawn": True})
    arch = doc("review-architect", "ARCHITECTURE",
               [finding("ARCH-1", sev="CRITICAL", loc="src/app.py:12", title="layering")])
    sem = doc("review-semantic", "SEMANTIC", [finding("SEM-MINOR-1", sev="MINOR")])
    ds = decide(keep("SEMANTIC", "SEM-MINOR-1"),
                {"source": "ARCHITECTURE", "source_id": "ARCH-1", "action": "merge",
                 "merged_into": "SEM-MINOR-1"})
    _, v, _ = run({"CONTEXT.json": ctx, "ARCHITECTURE.json": arch, "SEMANTIC.json": sem,
                   "VALIDATOR-DECISIONS.json": ds}, args=("--floor", "MAJOR"))
    assert [f["severity"] for f in v["findings"]] == ["BLOCKER"], v["findings"]
    assert v["verdict"] == "REQUEST_CHANGES", v["verdict"]


@case
def an_id_two_sources_share_is_still_addressable():
    # SEMANTIC and TESTING both emit X-1. Keyed by id alone, TESTING's became `TESTING#0`, which no
    # decision can name, so the reject below was refused and the finding escalated.
    ctx = dict(CTX, testing={"spawn": True})
    sem = doc("review-semantic", "SEMANTIC", [finding("X-1")])
    tst = doc("review-testing", "TESTING", [finding("X-1", loc="src/b.py:3")])
    _, v, _ = run({"CONTEXT.json": ctx, "SEMANTIC.json": sem, "TESTING.json": tst,
                   "VALIDATOR-DECISIONS.json": decide(
                       keep("SEMANTIC", "X-1"),
                       {"source": "TESTING", "source_id": "X-1", "action": "reject",
                        "reason": "FALSE_POSITIVE"})})
    assert v["decision_errors"] == [] and v["rejected_count"] == 1, v["decision_errors"]
    assert v["verdict"] == "REQUEST_CHANGES" and v["findings"][0]["source_ids"] == ["SEMANTIC:X-1"]
    # A bare merged_into naming the shared id is ambiguous: refused, and nothing is deleted.
    sem2 = doc("review-semantic", "SEMANTIC", [finding("X-1"), finding("S-2", loc="src/c.py:1")])
    _, v, _ = run({"CONTEXT.json": ctx, "SEMANTIC.json": sem2, "TESTING.json": tst,
                   "VALIDATOR-DECISIONS.json": decide(
                       keep("SEMANTIC", "X-1"), keep("TESTING", "X-1"),
                       {"source": "SEMANTIC", "source_id": "S-2", "action": "merge",
                        "merged_into": "X-1"})})
    assert v["metrics"]["total"] == 3 and "ambiguous" in v["decision_errors"][0]["error"], v


@case
def string_notes_are_one_note_not_one_per_character():
    ds = dict(decide(), notes="ran out of turns", positive_observations="clear naming")
    _, v, _ = run({"VALIDATOR-DECISIONS.json": ds})
    assert "ran out of turns" in v["coverage_notes"] and "r" not in v["coverage_notes"], \
        v["coverage_notes"]
    assert v["positive_observations"] == ["clear naming"], v["positive_observations"]


failed = 0
for fn in cases:
    try:
        fn()
        print(f"ok {fn.__name__}")
    except Exception as exc:  # report every case, not just the first failure
        failed += 1
        print(f"FAIL {fn.__name__}: {exc!r}")
sys.exit(1 if failed else 0)
PY

while IFS= read -r line; do
  case "$line" in
    ok\ *)   pass "finalize: ${line#ok }" ;;
    FAIL\ *) rest="${line#FAIL }"; fail "finalize: ${rest%%:*}" "${rest#*: }" ;;
    *)       [ -n "$line" ] && fail "finalize driver output" "$line" ;;
  esac
done <<EOF
$(py "$TMP/finalize-cases.py" "$CONTRACT" "$SCHEMA" "$TMP" 2>&1)
EOF

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
