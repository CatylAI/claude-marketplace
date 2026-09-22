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
  # The failure message carries the fix, because the docstring's suggested regeneration command is a
  # repo-level script that a vendored copy of this pipeline does not have.
  fail "$t" "$out
     Regenerate with:
       python3 -c \"import importlib.util,json;s=importlib.util.spec_from_file_location('c','$CONTRACT');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);json.dump(m.contract_schema(),open('$SCHEMA','w'),indent=2)\""
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

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
