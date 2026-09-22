"""contract.py — the ONE definition of what this harness emits and what its exit codes mean.

No shebang: this module is imported, never executed.

WHY A CONTRACT MODULE AND NOT A PROSE SCHEMA
--------------------------------------------
The precedent is `code-review-core/pipeline/contract.py`: the contract is executable rules, and
the committed JSON Schema under `schemas/` is a BUILD ARTIFACT of the generators below. There is
no hand-maintained copy that can drift, and `eval.test.sh` asserts that.

The donor design this harness was rewritten from carried its contract as nine interlocking JSON
examples in a reference document, with a warning that getting a key name wrong renders an empty
viewer "rather than an error". That is the failure this module exists to make unreachable: a
consumer validates against `schemas/*.schema.json`, and a producer that drifts fails a gate.

THE MEASUREMENT THIS CONTRACT DESCRIBES
---------------------------------------
Whether a skill fires is not a property of its prose. It is an empirical, STOCHASTIC property of
the description competing against the rest of the roster, and the only way to read it is to drive
real sessions and count. So every number here is a RATE over N runs, never a boolean, and every
rate carries the denominator that produced it.

THE THREE-WAY DISTINCTION THAT EVERY FIELD HERE PROTECTS
--------------------------------------------------------
A `0.0` can mean three unrelated things, and collapsing them is the silent-wrong-answer failure
this repo cares about most:

  TRIGGERED / NOT_TRIGGERED   the session ran and gave a verdict.  Countable.
  INDETERMINATE               the session ran but reached the time budget without deciding.
                              NOT countable — excluded from the denominator.
  UNREACHABLE                 the session never ran: `claude` is not on PATH, exited before
                              emitting anything, or died. NOT a measurement at all.

The donor collapsed all three into `False` (`except Exception: ...append(False)`), so a harness
that could not reach `claude` at all reported a confident 0% trigger rate for every query. That
is indistinguishable from a description nobody would ever load, and it is worse than an error,
because a 0% reads as a finding.

So: `trigger_rate` is `null` — never `0.0` — when no run was usable, `measured` records which
case you are in, and `EXIT_UNREACHABLE` is a distinct exit code from `EXIT_MEASURED_FAIL`.
"""

from __future__ import annotations

import math
import re

CONTRACT_VERSION = "1.0.0"

# ---------------------------------------------------------------- exit codes
#
# Exit codes are part of the contract because this harness is meant to run in CI, where the only
# thing a caller reliably sees is the number. Each one answers a different question and a caller
# must be able to act differently on each.

#: Everything ran and every query met its expectation.
EXIT_OK = 0

#: Everything ran; at least one query did not meet its expectation. A REAL result: the description
#: under test failed to trigger where it should, or triggered where it should not.
EXIT_MEASURED_FAIL = 1

#: The harness was asked to do something it cannot do: missing SKILL.md, malformed eval set, an
#: aggregation with no baseline arm. Nothing was measured and nothing was spent.
EXIT_MISCONFIGURED = 2

#: The harness could not obtain a measurement: `claude` is not on PATH, or too many sessions
#: failed to produce any usable signal. DISTINCT from EXIT_MEASURED_FAIL on purpose — see the
#: module docstring. Never report a rate on this path.
EXIT_UNREACHABLE = 3

EXIT_CODES = {
    EXIT_OK: "all queries met expectation",
    EXIT_MEASURED_FAIL: "measured, one or more queries failed expectation",
    EXIT_MISCONFIGURED: "bad inputs; nothing measured, nothing spent",
    EXIT_UNREACHABLE: "could not reach a usable claude session; NOT a zero trigger rate",
}

# ---------------------------------------------------------------- per-session outcomes
TRIGGERED = "triggered"
NOT_TRIGGERED = "not_triggered"
INDETERMINATE = "indeterminate"
UNREACHABLE = "unreachable"

OUTCOMES = (TRIGGERED, NOT_TRIGGERED, INDETERMINATE, UNREACHABLE)

#: The only two outcomes that belong in a rate's denominator. `INDETERMINATE` and `UNREACHABLE`
#: are excluded because neither is evidence about the description: one ran out of clock, the other
#: never ran. Counting either as a non-trigger biases every rate downward by exactly the harness's
#: own flakiness, which is the reading error this whole module exists to prevent.
COUNTABLE_OUTCOMES = (TRIGGERED, NOT_TRIGGERED)

# ---------------------------------------------------------------- benchmark arms
#
# Canonical, and enforced. A trigger rate on its own says nothing about value: a skill that fires
# 90% of the time on queries the model would have answered correctly anyway has not been shown to
# help. The without-skill arm is what turns a number into a claim, so its name is part of the
# contract rather than a convention a producer can spell differently.
ARM_WITH = "with_skill"
ARM_WITHOUT = "without_skill"
ARMS = (ARM_WITH, ARM_WITHOUT)

# ---------------------------------------------------------------- document shapes
KIND_TRIGGER = "trigger_report"
KIND_BENCHMARK = "benchmark_report"
KINDS = (KIND_TRIGGER, KIND_BENCHMARK)

TRIGGER_REPORT_REQUIRED = (
    "contract_version", "kind", "status", "skill_name", "description",
    "runs_per_query", "trigger_threshold", "sessions", "queries", "summary",
)

TRIGGER_QUERY_REQUIRED = (
    "query", "should_trigger", "measured", "trigger_rate",
    "usable_runs", "outcomes", "pass",
)

TRIGGER_SESSIONS_REQUIRED = ("planned", "run") + OUTCOMES

TRIGGER_SUMMARY_REQUIRED = ("total", "passed", "failed", "unmeasured")

BENCHMARK_REPORT_REQUIRED = (
    "contract_version", "kind", "skill_name", "generated_at", "arms", "delta", "runs", "warnings",
)

BENCHMARK_RUN_REQUIRED = ("eval_id", "arm", "run_number", "result")

#: Per-run metrics that get mean/stddev/min/max treatment. Adding one here adds it everywhere:
#: the stats, the delta, the Markdown table, and the generated schema.
BENCHMARK_METRICS = ("pass_rate", "duration_seconds", "tokens")

#: How each metric is rendered in a signed delta string. The donor hardcoded three format strings
#: at the one call site; naming them here is what keeps the table and the JSON agreeing.
DELTA_FORMATS = {"pass_rate": "{:+.2f}", "duration_seconds": "{:+.1f}", "tokens": "{:+.0f}"}

#: Claude Code truncates a description at this many characters. An optimiser that proposes a
#: longer one is proposing something the model will never see in full.
DESCRIPTION_MAX_CHARS = 1024

#: Default fraction of the eval set withheld from the optimiser. See optimize_description.py for
#: why this is not zero and must not be.
DEFAULT_HOLDOUT = 0.4

#: Fixed so a split is reproducible: two people tuning the same skill must be scored against the
#: same holdout, or their numbers are not comparable.
SPLIT_SEED = 42

#: A query passes when its rate lands on the right side of this. Not 1.0, because triggering is
#: stochastic; not 0.0, because then nothing fails.
DEFAULT_TRIGGER_THRESHOLD = 0.5

#: Runs per query. Three is the smallest N that can show a rate is not 0 or 1, and this harness
#: spawns a real session per run, so the default is the floor and not a target.
DEFAULT_RUNS_PER_QUERY = 3

#: Fraction of sessions allowed to come back INDETERMINATE or UNREACHABLE before the whole
#: measurement is declared unusable. Above this, the report is noise wearing a number.
DEFAULT_MAX_UNUSABLE = 0.2

_NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


# ---------------------------------------------------------------- statistics
def stats(values) -> dict:
    """mean / SAMPLE stddev / min / max, rounded to 4 places.

    SAMPLE, not population: n-1 in the denominator. These runs are a sample of a stochastic
    process, not the whole population of possible sessions, and the population formula understates
    the spread on the small N this harness can afford. With n < 2 there is no spread to report and
    the value is 0.0, which is honest only because `n` is emitted alongside it.
    """
    values = [float(v) for v in values]
    if not values:
        return {"n": 0, "mean": None, "stddev": None, "min": None, "max": None}
    n = len(values)
    mean = sum(values) / n
    if n > 1:
        stddev = math.sqrt(sum((x - mean) ** 2 for x in values) / (n - 1))
    else:
        stddev = 0.0
    return {
        "n": n,
        "mean": round(mean, 4),
        "stddev": round(stddev, 4),
        "min": round(min(values), 4),
        "max": round(max(values), 4),
    }


def trigger_rate(outcomes: dict):
    """Rate over COUNTABLE outcomes only, or None when nothing countable happened.

    Returning None rather than 0.0 is the entire point. See the module docstring.
    """
    usable = sum(int(outcomes.get(k, 0)) for k in COUNTABLE_OUTCOMES)
    if usable == 0:
        return None
    return round(int(outcomes.get(TRIGGERED, 0)) / usable, 4)


def query_passes(should_trigger: bool, rate, threshold: float):
    """Verdict for one query, or None when the query was never measured.

    An unmeasured query is neither a pass nor a fail. Scoring it as a fail would let a broken
    harness look like a bad description; scoring it as a pass would let one look like a good one.
    """
    if rate is None:
        return None
    return rate >= threshold if should_trigger else rate < threshold


# ---------------------------------------------------------------- validation
def _missing(doc, keys) -> list:
    return [k for k in keys if k not in doc]


def validate_eval_set(eval_set) -> list:
    """Defects in an eval set. Empty list means usable.

    An eval set is a list of `{"query": str, "should_trigger": bool}`. Both classes must be
    present: a set with no should-not-trigger cases cannot detect over-triggering, which is the
    failure authors most often ship and least often diagnose.
    """
    defects = []
    if not isinstance(eval_set, list) or not eval_set:
        return ["eval set must be a non-empty JSON array"]
    seen = set()
    for i, item in enumerate(eval_set):
        where = f"eval_set[{i}]"
        if not isinstance(item, dict):
            defects.append(f"{where}: not an object")
            continue
        q = item.get("query")
        if not isinstance(q, str) or not q.strip():
            defects.append(f"{where}: 'query' must be a non-empty string")
        elif q in seen:
            defects.append(f"{where}: duplicate query {q!r} — rates are keyed by query text")
        else:
            seen.add(q)
        if not isinstance(item.get("should_trigger"), bool):
            defects.append(f"{where}: 'should_trigger' must be true or false")
    positives = sum(1 for e in eval_set if isinstance(e, dict) and e.get("should_trigger") is True)
    negatives = sum(1 for e in eval_set if isinstance(e, dict) and e.get("should_trigger") is False)
    if positives == 0:
        defects.append("eval set has no should_trigger:true cases — nothing measures recall")
    if negatives == 0:
        defects.append(
            "eval set has no should_trigger:false cases — nothing measures over-triggering, "
            "which is the failure authors ship most often"
        )
    return defects


def validate_trigger_report(doc) -> list:
    """Defects in a trigger report. Empty list means the document honours the contract."""
    if not isinstance(doc, dict):
        return ["trigger report is not a JSON object"]
    defects = [f"missing key: {k}" for k in _missing(doc, TRIGGER_REPORT_REQUIRED)]
    if doc.get("kind") != KIND_TRIGGER:
        defects.append(f"kind must be {KIND_TRIGGER!r}")
    if doc.get("contract_version") != CONTRACT_VERSION:
        defects.append(f"contract_version must be {CONTRACT_VERSION!r}")
    if doc.get("status") not in ("ok", "unusable"):
        defects.append("status must be 'ok' or 'unusable'")

    sessions = doc.get("sessions")
    if isinstance(sessions, dict):
        defects += [f"sessions: missing key: {k}" for k in _missing(sessions, TRIGGER_SESSIONS_REQUIRED)]
    else:
        defects.append("sessions must be an object")

    summary = doc.get("summary")
    if isinstance(summary, dict):
        defects += [f"summary: missing key: {k}" for k in _missing(summary, TRIGGER_SUMMARY_REQUIRED)]
    else:
        defects.append("summary must be an object")

    queries = doc.get("queries")
    if not isinstance(queries, list):
        defects.append("queries must be an array")
        return defects
    for i, q in enumerate(queries):
        if not isinstance(q, dict):
            defects.append(f"queries[{i}]: not an object")
            continue
        defects += [f"queries[{i}]: missing key: {k}" for k in _missing(q, TRIGGER_QUERY_REQUIRED)]
        rate, measured = q.get("trigger_rate"), q.get("measured")
        # The load-bearing invariant. An unmeasured query MUST carry a null rate, because a 0.0
        # here is read as "the skill never fired" by every consumer downstream.
        if measured is False and rate is not None:
            defects.append(
                f"queries[{i}]: measured=false with a non-null trigger_rate — an unmeasured query "
                "must report null, never a number"
            )
        if measured is True and not isinstance(rate, (int, float)):
            defects.append(f"queries[{i}]: measured=true with a null trigger_rate")
        outcomes = q.get("outcomes")
        if isinstance(outcomes, dict):
            unknown = sorted(set(outcomes) - set(OUTCOMES))
            if unknown:
                defects.append(f"queries[{i}]: unknown outcome keys: {unknown}")
        else:
            defects.append(f"queries[{i}]: outcomes must be an object")
    return defects


def validate_benchmark_report(doc) -> list:
    """Defects in a benchmark report. Empty list means the document honours the contract."""
    if not isinstance(doc, dict):
        return ["benchmark report is not a JSON object"]
    defects = [f"missing key: {k}" for k in _missing(doc, BENCHMARK_REPORT_REQUIRED)]
    if doc.get("kind") != KIND_BENCHMARK:
        defects.append(f"kind must be {KIND_BENCHMARK!r}")
    if doc.get("contract_version") != CONTRACT_VERSION:
        defects.append(f"contract_version must be {CONTRACT_VERSION!r}")

    arms = doc.get("arms")
    if isinstance(arms, dict):
        unknown = sorted(set(arms) - set(ARMS))
        if unknown:
            defects.append(f"arms: unknown arm name(s) {unknown}; must be one of {list(ARMS)}")
    else:
        defects.append("arms must be an object")

    runs = doc.get("runs")
    if isinstance(runs, list):
        for i, r in enumerate(runs):
            if not isinstance(r, dict):
                defects.append(f"runs[{i}]: not an object")
                continue
            defects += [f"runs[{i}]: missing key: {k}" for k in _missing(r, BENCHMARK_RUN_REQUIRED)]
            if r.get("arm") not in ARMS:
                defects.append(f"runs[{i}]: arm must be one of {list(ARMS)}")
            # `pass_rate` nested under `result`, never at run top level. The donor's own reference
            # warned that getting this wrong produced an empty render instead of an error.
            if not isinstance(r.get("result"), dict):
                defects.append(f"runs[{i}]: 'result' must be an object holding the metrics")
    else:
        defects.append("runs must be an array")
    return defects


def validate_skill_name(name) -> list:
    if not isinstance(name, str) or not _NAME_RE.match(name):
        return [f"skill name {name!r} must be lowercase kebab-case"]
    return []


# ---------------------------------------------------------------- schema generators
#
# Every schema below is generated from the constants above on every call. `schemas/*.schema.json`
# are build artifacts of these functions; `eval.test.sh` fails if a committed copy drifts.

_STAT = {
    "type": "object",
    "required": ["n", "mean", "stddev", "min", "max"],
    "properties": {
        "n": {"type": "integer", "minimum": 0},
        "mean": {"type": ["number", "null"]},
        "stddev": {"type": ["number", "null"]},
        "min": {"type": ["number", "null"]},
        "max": {"type": ["number", "null"]},
    },
    "additionalProperties": False,
}

_GENERATED_NOTE = (
    "GENERATED from contract.py's constants; do not hand-edit. "
    "Regenerate with `python3 contract_schema.py --write` from the eval directory."
)


def trigger_report_schema() -> dict:
    """JSON Schema (draft 2020-12) for a trigger report, as a dict."""
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://github.com/CatylAI/claude-marketplace/schemas/trigger-report.schema.json",
        "title": "Skill trigger report",
        "description": (
            "Output of trigger_rate.py: the measured rate at which a description caused its skill "
            "to be invoked, over N real sessions per query. " + _GENERATED_NOTE
        ),
        "type": "object",
        "required": list(TRIGGER_REPORT_REQUIRED),
        "properties": {
            "contract_version": {"const": CONTRACT_VERSION},
            "kind": {"const": KIND_TRIGGER},
            "status": {
                "enum": ["ok", "unusable"],
                "description": (
                    "'unusable' means too few sessions produced a verdict for any rate here to be "
                    "read as a measurement. It is NOT a zero trigger rate."
                ),
            },
            "skill_name": {"type": "string", "minLength": 1},
            "description": {"type": "string", "maxLength": DESCRIPTION_MAX_CHARS},
            "model": {
                "type": ["string", "null"],
                "description": "null means the session's configured default was inherited.",
            },
            "runs_per_query": {"type": "integer", "minimum": 1},
            "trigger_threshold": {"type": "number", "minimum": 0, "maximum": 1},
            "sessions": {
                "type": "object",
                "required": list(TRIGGER_SESSIONS_REQUIRED),
                "properties": {
                    "planned": {"type": "integer", "minimum": 0},
                    "run": {"type": "integer", "minimum": 0},
                    **{k: {"type": "integer", "minimum": 0} for k in OUTCOMES},
                },
                "additionalProperties": False,
            },
            "queries": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": list(TRIGGER_QUERY_REQUIRED),
                    "properties": {
                        "query": {"type": "string", "minLength": 1},
                        "should_trigger": {"type": "boolean"},
                        "measured": {"type": "boolean"},
                        "trigger_rate": {
                            "type": ["number", "null"],
                            "minimum": 0,
                            "maximum": 1,
                            "description": (
                                "null when no session produced a verdict. NEVER 0.0 in that case: "
                                "0.0 means the skill demonstrably did not fire."
                            ),
                        },
                        "usable_runs": {"type": "integer", "minimum": 0},
                        "outcomes": {
                            "type": "object",
                            "properties": {k: {"type": "integer", "minimum": 0} for k in OUTCOMES},
                            "additionalProperties": False,
                        },
                        "pass": {"type": ["boolean", "null"]},
                    },
                    "additionalProperties": True,
                },
            },
            "summary": {
                "type": "object",
                "required": list(TRIGGER_SUMMARY_REQUIRED),
                "properties": {k: {"type": "integer", "minimum": 0} for k in TRIGGER_SUMMARY_REQUIRED},
                "additionalProperties": False,
            },
        },
        "additionalProperties": True,
    }


def benchmark_report_schema() -> dict:
    """JSON Schema (draft 2020-12) for a benchmark report, as a dict."""
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://github.com/CatylAI/claude-marketplace/schemas/benchmark-report.schema.json",
        "title": "Skill benchmark report",
        "description": (
            "Output of aggregate.py: mean and sample stddev per arm, plus the with-skill minus "
            "without-skill delta that turns a pass rate into a claim. " + _GENERATED_NOTE
        ),
        "type": "object",
        "required": list(BENCHMARK_REPORT_REQUIRED),
        "properties": {
            "contract_version": {"const": CONTRACT_VERSION},
            "kind": {"const": KIND_BENCHMARK},
            "skill_name": {"type": "string", "minLength": 1},
            "generated_at": {"type": "string", "minLength": 1},
            "arms": {
                "type": "object",
                "propertyNames": {"enum": list(ARMS)},
                "additionalProperties": {
                    "type": "object",
                    "required": list(BENCHMARK_METRICS),
                    "properties": {m: dict(_STAT) for m in BENCHMARK_METRICS},
                    "additionalProperties": True,
                },
            },
            "delta": {
                "type": "object",
                "description": (
                    "with_skill minus without_skill, per metric. Absent when the without-skill arm "
                    "was not supplied — a pass rate with no baseline is not evidence the skill did "
                    "anything."
                ),
                "additionalProperties": {
                    "type": "object",
                    "required": ["value", "display"],
                    "properties": {
                        "value": {"type": ["number", "null"]},
                        "display": {"type": "string"},
                    },
                    "additionalProperties": False,
                },
            },
            "runs": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": list(BENCHMARK_RUN_REQUIRED),
                    "properties": {
                        "eval_id": {"type": ["integer", "string"]},
                        "arm": {"enum": list(ARMS)},
                        "run_number": {"type": "integer", "minimum": 1},
                        "result": {
                            "type": "object",
                            "description": "Metrics nested HERE, never at run top level.",
                            "properties": {m: {"type": ["number", "null"]} for m in BENCHMARK_METRICS},
                            "additionalProperties": True,
                        },
                    },
                    "additionalProperties": True,
                },
            },
            "warnings": {"type": "array", "items": {"type": "string"}},
        },
        "additionalProperties": True,
    }


SCHEMAS = {
    "trigger-report.schema.json": trigger_report_schema,
    "benchmark-report.schema.json": benchmark_report_schema,
}
