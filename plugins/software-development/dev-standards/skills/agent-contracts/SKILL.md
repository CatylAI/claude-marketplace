---
name: agent-contracts
license: MIT
description: The structured output contract for review agents — a JSON schema alongside the human report, three orthogonal finding axes (impact, scope, certainty), the blocking predicate that computes the verdict, and the completion trailer that proves the agent finished. Use when building or maintaining a multi-agent review pipeline, or when an agent's output has to be consumed programmatically rather than read.
---

# Agent Output Contract

An agent whose output a machine depends on must emit **two** things:

1. **A human report** — markdown, for a person to read.
2. **A machine contract** — JSON, for the pipeline to act on.

The aggregating pipeline reads the JSON, never the markdown. That separation is what lets
the prose stay readable while the gate stays reliable. A pipeline that parses prose has no
artifact requirement at all: the model can narrate a verdict it never computed.

## The contract

```typescript
interface AgentContract {
  // Identity
  agent: string;          // e.g. "review-security"
  category: string;       // "SECURITY" | "PERFORMANCE" | "RELIABILITY" | "TESTING"
                          // | "ARCHITECTURE" | "IMPACT" | "VALIDATED"
  source_branch: string;
  target_branch: string;

  findings: Finding[];

  // Rollup verdict. REQUIRED in the aggregated contract; OPTIONAL in a specialist's own.
  // Nothing reads a specialist's rollup — the aggregator recomputes it from the full
  // deduplicated finding set, because only it can see that set.
  //   APPROVE          nothing blocks and nothing is unresolved
  //   REQUEST_CHANGES  at least one finding blocks (see the predicate below)
  //   INCOMPLETE       nothing blocks, but at least one in-scope finding could not be
  //                    resolved to HIGH confidence. Not an assertion that a defect exists
  //                    — an assertion that a human must look. It must gate auto-merge and
  //                    must stay distinct from REQUEST_CHANGES.
  verdict: "APPROVE" | "REQUEST_CHANGES" | "INCOMPLETE";

  metrics: {
    total: number;
    blocker: number;
    major: number;
    minor: number;
    nit: number;
    coverage_pct: number | null;   // null when not measurable
    ux_impact_count: number;
  };

  // Aggregated contract only
  rejected_count?: number;
  blocking_reason_ids?: string[];  // ids of the findings that caused REQUEST_CHANGES
}

interface Finding {
  id: string;              // "SEC-BLOCKER-1". The severity token in the id MUST equal the
                           // `severity` field — some consumers route on the id prefix, so a
                           // disagreement sends the finding somewhere it does not belong.
  severity: "BLOCKER" | "MAJOR" | "MINOR" | "NIT";
  category: string;
  location: string;        // "path/to/file:42" — a verified line, not an approximate one
  title: string;           // one short sentence
  evidence: string;        // the actual code, raw, not markdown-fenced
  recommendation: string;  // a concrete fix, one paragraph at most
  ux_impact: boolean;      // true when this directly degrades the end-user experience
  in_diff: boolean;        // true when this change introduced or worsened the issue
  confidence: "HIGH" | "MEDIUM" | "LOW";
}
```

`severity`, `verdict` and `confidence` are **closed vocabularies**. Reject a near miss;
do not coerce it. Code that branches on `== "HIGH"` silently reclassifies `"High"`.

## The three axes are orthogonal

This is the whole design. Every recurring defect in a contract like this is one axis
folded into another.

| Field | Encodes | Never encodes |
| --- | --- | --- |
| `severity` | **impact** — what happens if this ships | how sure the reviewer is; whether the diff caused it |
| `in_diff` | **scope** — did this change introduce or worsen it | impact; certainty |
| `confidence` | **certainty** — how well the reviewer traced it | impact; scope |

**Uncertainty escalates; it never downgrades.** No agent, script or prompt may lower a
severity, relabel a finding to `NIT`, or drop it because the reviewer was unsure. A MAJOR
the reviewer could only partly trace is still a MAJOR: it reports `confidence: "MEDIUM"`
and drives the verdict to `INCOMPLETE`. A rule reading "if uncertain, downgrade" destroys
the impact axis in order to express something `confidence` already carries.

Scope works the same way. An out-of-diff MAJOR is `severity: "MAJOR", in_diff: false`.
Capping it to the bottom tier makes it indistinguishable from a cosmetic nit for every
downstream reader, including the next review of the same repository.

## The blocking predicate

State it once and reuse it. Where a copy is unavoidable, the standard is **identical
output over the whole input space** — check it by executing every copy over the cross
product of the axes, not by reading them side by side.

```python
import os

_RANK = {"BLOCKER": 0, "MAJOR": 1, "MINOR": 2, "NIT": 3}
_ALIASES = {"INFO": "NIT"}          # accepted on input, never emitted
DEFAULT_BLOCKING_FLOOR = "MINOR"

# The contract gate. Without these four keys a finding asserts nothing, so it can neither
# block nor escalate. Deliberately narrower than the full required-key list: a detector
# that supplies no fix text still emits a real, well-located finding, and gating on all
# ten keys would silence it.
_ACTIONABLE = ("id", "severity", "location", "title")
_BOOLS = {"ux_impact", "in_diff"}


def contract_defects(f, required=_ACTIONABLE):
    """Required keys that are missing, null, blank or the wrong type. [] means usable."""
    if not isinstance(f, dict):
        return ["not-an-object"]
    d = []
    for k in required:
        if k not in f:                                   d.append(f"missing:{k}")
        elif f[k] is None:                               d.append(f"null:{k}")
        elif k in _BOOLS and not isinstance(f[k], bool): d.append(f"not-a-boolean:{k}")
        elif isinstance(f[k], str) and not f[k].strip(): d.append(f"empty:{k}")
    return d


def _rank(value):
    """Rank of a severity, or None when it cannot be ranked. Folds the INFO alias."""
    s = str(value or "").strip().upper()
    return _RANK.get(_ALIASES.get(s, s))


def _floor_rank():
    """An unrecognised floor falls back to the STRICT default, never the permissive one."""
    r = _rank(os.environ.get("REVIEW_BLOCKING_FLOOR"))
    return _RANK[DEFAULT_BLOCKING_FLOOR] if r is None else r


def _in_scope(f):
    """Contentful, in-diff, rankable, not a NIT, at or below the floor."""
    if contract_defects(f):        return False   # no claim to act on
    if not f.get("in_diff", True): return False   # scope stops it, not severity
    r = _rank(f.get("severity"))
    if r is None:                  return False   # nothing to compare against
    if r == _RANK["NIT"]:          return False   # no true impact, by definition
    if f.get("ux_impact"):         return True    # this disjunct MUST survive
    return r <= _floor_rank()


def finding_blocks(f):
    if str(f.get("confidence") or "HIGH").upper() != "HIGH":
        return False                              # escalates instead; severity untouched
    return _in_scope(f)


def finding_escalates(f):
    if contract_defects(f):
        return False
    if str(f.get("confidence") or "HIGH").upper() == "HIGH":
        return False
    return _in_scope(f)
```

Then:

- `REQUEST_CHANGES` if any finding satisfies `finding_blocks`.
- Otherwise `INCOMPLETE` if any finding satisfies `finding_escalates` — in scope, not a
  NIT, and below HIGH confidence after research was actually attempted. The finding keeps
  its severity and a human is asked to look.
- `APPROVE` only when neither holds.

Do not re-derive either arm from prose. The two arms share `_in_scope` precisely so they
cannot drift on the terms they must agree about.

### Seven details, each of which has been a bug

1. **The `NIT` short-circuit sits above the `ux_impact` clause.** NIT means "no true
   impact", so a NIT with genuine UX impact is a contradiction — it was mis-tiered, and
   the fix is the tier, not a blocking exception. Below `ux_impact`, a UX-tagged NIT
   blocks at every floor.
2. **The `ux_impact` disjunct survives.** A UX-impacting MINOR blocks even when the floor
   is raised above MINOR. This is the term that silently vanishes when someone rewrites
   the predicate from memory.
3. **Below-HIGH confidence routes to escalate, not to silence.** Returning `False` from
   `finding_blocks` is only safe because `finding_escalates` catches the same finding.
   Copying one arm without the other is a half-gate, and an uncertain MAJOR then passes
   unnoticed — worse than blocking on it.
4. **The floor is the only knob.** Never `in_diff`, never `confidence`. Those two are not
   tunable; loosening them turns the gate off rather than tightening it.
5. **`in_diff` defaults to `True` when absent**, and is false only when present and false.
   `f.get("in_diff", True)`, not `f["in_diff"]`. A specialist that cannot cheaply compute
   diff scope should omit the key and let the aggregator decide; subscripting turns that
   documented omission into a `KeyError` mid-review.
6. **`confidence` coalesces absent, null *or empty* to `HIGH`** via
   `str(f.get("confidence") or "HIGH")` — which is not what `f.get("confidence", "HIGH")`
   does. An explicit JSON `null` must still block.
7. **An unrankable severity returns `None`, and that guard sits above `ux_impact`.**
   Otherwise an object carrying `{"ux_impact": true}` and no usable severity blocks
   unconditionally. Under a permissive floor the inversion is invisible on ordinary
   findings and fires only on malformed ones, which is why reading the code never catches
   it — test unrankable, absent, null and empty severities, not only the four valid names.

### A contentless finding is not an uncertain one

They escalate to different people.

- **Below-HIGH confidence** means a claim exists and could not be fully traced. It keeps
  its severity, drives `verdict: "INCOMPLETE"`, and escalates to the **human reviewer**.
- **A finding failing `contract_defects`** asserts nothing at all. There is no claim to
  preserve, so drop it from the author-facing list, **count** it in a top-level
  `contract_health` block (`{repaired, rejected, repairs[], defects[]}` — keep the raw
  object, never delete it), and escalate it to the **tooling owner**.

`contract_health` must not touch `verdict`. The enum stays three-valued, because the
author of the change cannot fix a defect in the review tooling and must not be blocked by
one. Without that separation, `{"id": "x", "severity": "MINOR"}` produces REQUEST_CHANGES
and the same object at MEDIUM confidence produces INCOMPLETE — a gate nobody can clear.

### Normalize before you judge

Run a repair pass before the gate: fold `file` + `line` onto `location`, and
`summary`/`short_summary`/`detail`/`comment` onto `title`. Repair first, then reject the
residue.

Shape matters as much as the key name. A value under a recovery alias must be a **scalar**
before it can become the anchor: `"file": ["a.tf"]` is one claim wrapped in a list of one
and can be unwrapped; `["a.tf", "b.tf"]` is two claims with no non-arbitrary way to pick
one, so treat it as absent and report `missing:location`. Skip that check and the list
stringifies straight through as `"['a.tf']:996"` — present, non-blank, therefore accepted
— and blocks a merge on an anchor no consumer can parse.

## Schema: generate it, do not hand-maintain it

Derive the JSON Schema from the same constants the runtime uses, and treat the generated
file as a build artifact that fails CI if hand-edited. Two schemas for one contract is not
redundancy, it is two answers, and the wrong one stays invisible until something depends
on it. A hand-written copy drifts fast — typically by demanding fields from every agent
that the contract explicitly makes optional for specialists, which then rejects four
honest agents for obeying the spec.

## Enforcing the contract

| Pipeline shape | Use | Why |
| --- | --- | --- |
| Multi-agent fan-out that aggregates programmatically | A workflow runner with a declared output `schema` | Schema validation plus automatic retry on malformed output; results are usable without parsing |
| A single ad-hoc conversational review | A plain agent call with a defensive JSON parse | The workflow overhead is not justified |

Any pipeline that fans out N agents and then aggregates must use schema-validated output.
A plain agent call has no schema enforcement.

Defensive parse, for the ad-hoc case:

```python
import json, re

raw = "<agent output string>"
m = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', raw, re.DOTALL)  # strip markdown fences
if m:
    raw = m.group(1)
try:
    contract = json.loads(raw)
    verdict = contract.get("verdict", "REQUEST_CHANGES")
    findings = contract.get("findings", [])
except json.JSONDecodeError:
    verdict, findings = "REQUEST_CHANGES", []   # fail closed
```

## The aggregated contract

The validator writes one file with `category: "VALIDATED"` after deduplicating every
specialist contract. It is the single source of truth for the verdict, and it adds:

```json
{
  "...": "(all AgentContract fields)",
  "category": "VALIDATED",
  "rejected_count": 4,
  "blocking_reason_ids": ["SEC-BLOCKER-1", "TEST-MAJOR-2"]
}
```

**There is no prose fallback for the verdict.** If the aggregated JSON is absent, the
phase failed — do not fall back to parsing the markdown. Text parsing survives only as a
display aid for rendering an archived report, and must never set the verdict.

## The completion trailer

Write the artifact **first**, then end the final message with a trailer. Enforce both
halves in code: a missing artifact fails the phase, and so does a trailer that is absent
or disagrees with the artifact.

```
REVIEW-TRAILER v1
STATUS: COMPLETE
ARTIFACT: .code-review/VALIDATED.json
FINDINGS: 7
SEVERITIES: BLOCKER=0 MAJOR=2 MINOR=4 NIT=1
```

If the job could not be done at all, say so. Never return an empty finding set, which is
indistinguishable from "I looked and found nothing":

```
REVIEW-TRAILER v1
STATUS: BLOCKED
BLOCKED-REASON: context file absent — the prepare step did not run
```

Rules:

- The trailer goes **last**, after any prose. The last trailer in the message wins, so
  quoting the grammar while explaining yourself is safe.
- `FINDINGS` and `SEVERITIES` must be derived from the artifact you wrote, not recalled.
- `STATUS: BLOCKED` requires a `BLOCKED-REASON`. An unexplained block is indistinguishable
  from a crash.
- Accept `INFO` when reading an archived artifact; emit `NIT`.

### Why a trailer, when the artifact is already checked

Three failures survive an artifact-existence check:

1. **Truncation.** A run killed mid-message leaves an artifact that exists, is non-empty
   and parses. No existence check distinguishes that from a finished run. A terminal
   trailer does, because a truncated message does not have one.
2. **A report that outruns its artifact.** An agent narrating "Verdict: REQUEST_CHANGES,
   0 blocker, 2 major, 5 minor — full findings in `VALIDATED.json`" with every structured
   signal green and no such file anywhere. Existence catches that case; it does not catch
   the same claim made over an artifact holding two findings.
3. **A blocked agent.** With no declared status, an agent that could not run looks exactly
   like one that found nothing, and silence gets read as consent. Never record no-verdict,
   a partial answer, or silence as a pass.

### Why there is no checksum in it

The obvious design is `ARTIFACT: <path> SHA256: <hash>`. Most gate agents cannot compute
one — their tool allowlists have no general shell access, by design, because a reviewer
should not be running arbitrary commands. Asking anyway produces one of two failures: the
agent shells out, the permission layer denies it, and the run parks until timeout; or the
model invents a plausible hash, and a gate comparing a fabricated hash to a real one fails
on honest runs and gets switched off.

Be exact about what the counts do prove. A hash proves "a file with this content exists".
Counts derived from the artifact by the emitter cannot disagree with it — that is a
consistency check, not the truth check failure 2 needs. Catching failure 2 requires a gate
that reads the closing prose.
