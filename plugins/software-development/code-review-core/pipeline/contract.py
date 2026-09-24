"""contract.py — the ONE definition of the finding contract: what makes a finding USABLE, and
what makes a usable finding BLOCK.

Both halves live here on purpose, and this module is the only implementation of either. No prose
copy of the blocking predicate is maintained anywhere: the `dev-standards:agent-contracts` skill
documents the finding keys for the agents that fill them, gives a one-line summary of the verdict,
and points to `finding_blocks`, `finding_escalates` and `rollup_verdict` here as the definition.
`review-scan.sh` and `normalize.py` import this module, and `agents/review-validator.md` only
records judgements in VALIDATOR-DECISIONS.json, from which `finalize` (below) computes everything
else.

Imported by the pipeline, and also runnable for one subcommand:

    python3 contract.py finalize --dir .code-review [--floor MAJOR]

`finalize` is the deterministic last step of a review. It reads the agent artifacts plus the
validator's decisions and writes VALIDATED.json, VALIDATED.md and (only when there are contract
defects) CONTRACT-DEFECTS.md. Exit 0 when written; exit 2 when a required input is missing or
unparseable, in which case it still writes an INCOMPLETE VALIDATED.json naming that input.

WHY THIS LIVES BESIDE THE PIPELINE AND NOT IN THE STANDARDS PLUGIN. A vendored layout separates
the two trees with no stable relative path between them: vendored into a CI image, `normalize.py`
lands in one directory and the standards skills in another, so any `sys.path` computation that
resolved in the repo would break at import time, mid-review. The executable therefore sits beside
the code that imports it, and the skill defers to it rather than copying it.

Why this file exists. Nine real `VALIDATED.json` artifacts were recovered from job disk and ONE
satisfied the ten-key `required` array in `agent-contracts`. That array is prose handed to a
model; nothing ever executed it. Two independent defects shared that one enabler:

  RENDERING  a `Summary` column filled from `title` while 8 of 9 producers wrote the prose under
             `summary`/`short_summary`/`detail` and the position under `file`+`line`.
  BLOCKING   a predicate that fails OPEN on two of three gates — `f.get("in_diff", True)`
             defaults to blocking, and `str(f.get("confidence") or "HIGH")` coalesces absent AND
             empty to HIGH — with no content gate at all. So `{"id": "x", "severity": "MINOR"}`
             blocked a merge while carrying no location, no title, no evidence: nothing an author
             could act on, and nothing they could clear.

`normalize_finding` runs FIRST and is LOSSLESS. 8 of the 9 artifacts are RECOVERABLE — they carry
the same information under different key names — so this repairs rather than rejects, and records
every fold so the inference is auditable instead of invisible. Order is load-bearing: gating
before repairing would silence 8 of the 9.

`contract_defects` runs after the repair and reports what is still missing.

TWO TIERS, AND THE SPLIT IS DELIBERATE
--------------------------------------
`CONTRACT_REQUIRED` is the full ten-key contract. It is the standard for worked examples in agent
prompts, because an example is a template and a template should be complete.

`ACTIONABLE_REQUIRED` is the four keys without which a finding cannot be acted on at all, and it
is what the *blocking* predicate gates on. The two differ on purpose, and the reason is measured:
`normalize.py`'s own `mk()` emits `"recommendation": ""` whenever a detector supplies no fix text
(ruff and mypy routinely do), and several detectors emit `category` values but no remediation.
Gating `finding_blocks` on all ten would therefore silence real, well-located scanner findings —
turning a fail-open bug into a fail-closed one, which is worse, because a dropped BLOCKER is
invisible while a spurious one is merely annoying.

So: a finding missing `recommendation` is incomplete and is REPORTED as such; a finding missing
`location` asserts nothing and is dropped. `contract_defects` tells you which case you are in.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys

BLOCKER, MAJOR, MINOR, NIT = "BLOCKER", "MAJOR", "MINOR", "NIT"

# `INFO` was the bottom tier before code-review 3.0.0. It is still ACCEPTED on input — an archived
# SCAN.json/VALIDATED.json from an earlier run, or a hand-written fixture, still says INFO — but it
# is never EMITTED. Reading it as NIT is not cosmetic: without the alias an INFO finding falls out
# of every severity bucket while staying in `findings`, so the counts and the verdict disagree with
# the list a human reads. That silent-drop fail-open is exactly what this map closes.
SEVERITY_ALIASES = {"INFO": NIT}

# ONE rank table. There used to be two byte-identical ones in normalize.py — this and a `SEV_ORDER`
# used for dedup and sorting via BARE SUBSCRIPT. Two tables meant ordering could drift from
# blocking with nothing to catch it, and the subscript form was invisible to the parity gate
# (which harvests the blocking predicate, not the sort key) while also being the one form that
# raises on an unrankable value. Use `canon_severity()` to look up, never a subscript.
SEVERITY_RANK = {BLOCKER: 0, MAJOR: 1, MINOR: 2, NIT: 3}

# Sort position for a severity that cannot be ranked at all: AFTER every known tier. An unrankable
# finding is reported and counted (see normalize.py's `unknown_sev`), never dropped, so it needs a
# defined position rather than a KeyError.
UNRANKABLE_SORT_POSITION = len(SEVERITY_RANK)

# 3.0.0: was INFO, i.e. "every tier blocks". NIT is defined as "no true impact", so a floor of NIT
# would mean the bottom tier means nothing. MINOR ("works but violates standards, should fail the
# job so it gets refactored") is the lowest tier that can honestly block.
DEFAULT_BLOCKING_FLOOR = MINOR

# The full contract. `dev-standards:agent-contracts` describes these keys for the agents that fill them.
CONTRACT_REQUIRED = (
    "id", "severity", "category", "location", "title",
    "evidence", "recommendation", "ux_impact", "in_diff", "confidence",
)

# The subset a finding cannot be acted on without. See "TWO TIERS" above for why this is not the
# full ten. `severity` is here because the predicate has no rank to compare without it; `id`
# because `blocking_reason_ids` and the inline-note router both address findings by id.
ACTIONABLE_REQUIRED = ("id", "severity", "location", "title")

_BOOLS = frozenset({"ux_impact", "in_diff"})

# Where prose lands when a producer does not call it `title`, most-specific first. Measured
# against the nine recovered artifacts; `comment` is the shape `review-reporter`'s inline-note
# few-shot taught, which is why it is in the list rather than being treated as unrecoverable.
_TITLE_ALIASES = ("title", "summary", "short_summary", "detail", "comment", "message", "description")

# Where position lands when a producer does not call it `location`.
_PATH_ALIASES = ("file", "path", "filename", "filepath")
_LINE_ALIASES = ("line", "line_number", "lineno", "start_line")

TITLE_MAX = 300


#: How many nested one-element wrappers `_scalar` will peel. Bounded rather than recursive-until-done
#: because the input is a foreign artifact: an unbounded unwrap over a self-referential structure is a
#: hang inside a gate, and a gate that hangs is read as a gate that is slow.
_SCALAR_UNWRAP_LIMIT = 4


def _blank(v) -> bool:
    """True when a value carries no information. `False` and `0` are information, not blanks."""
    if v is None:
        return True
    if isinstance(v, str):
        return not v.strip()
    return False


def _scalar(v):
    """Unwrap a ONE-element sequence onto its element. Returns None when `v` is still a container.

    WHY THIS EXISTS. `normalize_finding` used to build the location anchor with a bare
    `str(out[k]).strip()`, so a producer emitting `"file": ["datadog.tf"]` — a real shape; several
    tools report positions as arrays — produced `location: "['datadog.tf']:996"`.
    `contract_defects` then returned `[]`, because the key is present and the string is non-blank, so
    the finding PASSED and blocked the merge while carrying an anchor no consumer can parse. That is
    fail-closed in the worst direction: the gate holds the merge on a finding nobody can act on and
    nobody can clear.

    The two cases are not the same and are not treated the same:

      ["datadog.tf"]            ONE claim, wrapped. Unwrapping is lossless RECOVERY, which is what
                                the rest of this module does for every other misshapen key.
      ["a.tf", "b.tf"]          TWO claims. There is no non-arbitrary way to pick one, so this is a
                                DEFECT: not a scalar, treated as absent, and the resulting
                                `missing:location` is what `contract_defects` reports. The raw object
                                rides along in `contract_health`, so the tooling owner still sees
                                exactly what the producer emitted.

    No new `contract_defects` token was added for this, deliberately. That vocabulary is a closed set
    (`not-an-object`, `missing:`, `null:`, `not-a-boolean:`, `empty:`) asserted by name in several
    suites and restated in two agent prompts; `missing:location` is already the true and actionable
    statement about a finding whose position could not be recovered, so a sixth token would widen a
    published vocabulary to say something the existing one already says.
    """
    # `LIMIT + 1` iterations to peel LIMIT wrappers, because each pass either PEELS or RETURNS —
    # never both. With `range(LIMIT)` a value nested exactly LIMIT deep was unwrapped on the final
    # iteration and then fell out of the loop to `return None`, discarding the scalar it had just
    # recovered: LIMIT=4 recovered 3 wrappers, not 4, contradicting this constant's own docstring.
    # The extra iteration is the one that returns the peeled value.
    for _ in range(_SCALAR_UNWRAP_LIMIT + 1):
        if isinstance(v, (list, tuple)):
            if len(v) != 1:
                return None
            v = v[0]
            continue
        if isinstance(v, (dict, set, frozenset)):
            return None
        return v
    return None


def _first_scalar(f, keys):
    """First key in `keys` carrying a usable SCALAR value, unwrapped. None when none of them does.

    A non-scalar candidate is SKIPPED rather than aborting the search. The alias tuples are ordered
    most-specific-first, and a value carrying no single claim is precisely what "this alias is not
    usable" means, so the next alias gets its turn. `{"file": ["a.tf", "b.tf"], "path": "real.tf"}`
    therefore recovers `real.tf` instead of dropping the finding — recovery is this function's whole
    job, and the multi-element list is still never stringified into the anchor.
    """
    for k in keys:
        if _blank(f.get(k)):
            continue
        v = _scalar(f[k])
        if v is not None and not _blank(v):
            return v
    return None


def normalize_finding(f, index=None):
    """Repair a finding onto the canonical key names. Returns (repaired_copy, repairs).

    LOSSLESS for every key that carries a CLAIM: never drops or overwrites a populated canonical
    key, and never invents an assertion that was not already in the object under another name.
    `repairs` is a list of human-readable strings naming each fold, so `contract_health` can show
    what was inferred rather than leaving the reader to guess why a finding looks different from
    what its producer emitted.

    `index` is the finding's position in its source list. Supplying it lets a missing `id` be
    SYNTHESISED rather than treated as a defect, which matters because `id` is the one required
    key that is pure bookkeeping: it is a handle the router and `blocking_reason_ids` address the
    finding by, not a statement about the code. Dropping a well-located, well-titled MAJOR because
    its producer forgot to number it would be the fail-closed mirror of the bug this gate exists
    to fix.

    SHAPE, not just key names. A value under a recovery alias must be a SCALAR before it can become
    part of the anchor — see `_scalar` for the measured defect where a list-valued `file` stringified
    into `location` and passed every gate.
    """
    if not isinstance(f, dict):
        return f, []

    out, repairs = dict(f), []

    # SHAPE on the CANONICAL keys, before any alias recovery below. This runs FIRST on purpose: a
    # container under `location` has to become absent before the `file`/`path` recovery can fire.
    #
    # WHY THIS IS NOT ONLY THE ALIAS LOOPS. The first cut of this guard routed the two location
    # alias loops through `_first_scalar` and stopped there, which left the canonical keys open and
    # made three statements false in three places:
    #
    #   {"location": ["datadog.tf:996"], ...}   `_blank` returns False for every container, so the
    #                                           repair below was SKIPPED, `contract_defects` returned
    #                                           [] and the finding BLOCKED with a list in the anchor.
    #                                           D1 exactly, reached through the canonical key.
    #   {"location": ["x.tf:1"], "file": "a.tf"} worse: the container SUPPRESSED recovery, so a usable
    #                                           `file` sat unread while the merge was held.
    #   {"severity": ["MAJOR"], ...}            the mirror direction — `canon_severity` returned "",
    #                                           defects were [] and a real MAJOR stopped blocking.
    #   {"title": ["a", "b"], ...}              `str(...)[:TITLE_MAX]` runs only on the alias path, so
    #                                           a list reached the artifact as `title`, against the
    #                                           `"type": "string"` this module's own schema declares.
    #
    # ADR-007 decision 2a is titled "Recovery is by key name AND by shape" and agent-contracts tells
    # every agent "SHAPE MATTERS AS WELL AS THE KEY NAME". Neither is bounded to the alias path, so
    # guarding only the alias path left the general claim untrue. The keys are `ACTIONABLE_REQUIRED`
    # rather than a hand-written list, so a key added to that tuple is guarded the moment it is added.
    for k in ACTIONABLE_REQUIRED:
        if k not in out:
            continue
        v = out[k]
        if not isinstance(v, (list, tuple, dict, set, frozenset)):
            continue
        s = _scalar(v)
        if s is None:
            # Two or more claims, or a mapping. No non-arbitrary pick, so treat it as ABSENT and let
            # the recovery below and `contract_defects` report the shortfall. The raw object still
            # rides along in `contract_health`, so the tooling owner sees what the producer emitted.
            del out[k]
            repairs.append(f"{k} dropped <- non-scalar {type(v).__name__}")
        else:
            out[k] = s
            repairs.append(f"{k} <- unwrapped {type(v).__name__}")

    # location <- file/path [+ line]
    #
    # Both halves route through `_first_scalar`, which is the scalar CHECK the bare
    # `str(out[k]).strip()` this replaced did not have. See `_scalar` for the measured defect: a
    # one-element list is unwrapped, a multi-element one is treated as absent so the shortfall is
    # reported rather than stringified into the anchor.
    if _blank(out.get("location")):
        raw_path = _first_scalar(out, _PATH_ALIASES)
        path = str(raw_path).strip() if raw_path is not None else ""
        if path:
            line = _first_scalar(out, _LINE_ALIASES)
            try:
                line = int(line) if line is not None else 0
            except (TypeError, ValueError):
                line = 0
            out["location"] = f"{path}:{line}" if line else path
            repairs.append(f"location <- {path}" + (f"+line {line}" if line else " (no line)"))

    # title <- summary/short_summary/detail/comment/...
    #
    # Routed through `_scalar`, like both location loops. It was a bare `str(out[k]).strip()`, which
    # made this the ONE surviving path where a container still stringified into the artifact:
    # `{"summary": ["a", "b"]}` produced the literal title `"['a', 'b']"` with `contract_defects == []`,
    # and `{"summary": ["solo"]}` produced `"['solo']"` — a one-element wrapper that every other
    # recovery in this module unwraps. The earlier reasoning for leaving it ("a title is prose, so a
    # stringified list is ugly but legible") stopped holding once the canonical keys were guarded and
    # ADR-007 2a was restated as "recovery is by key name AND by shape": a rule with one unexplained
    # exception is not the rule it claims to be. An unusable alias is SKIPPED so the next one gets its
    # turn, matching `_first_scalar`.
    if _blank(out.get("title")):
        for k in _TITLE_ALIASES[1:]:
            if _blank(out.get(k)):
                continue
            cand = _scalar(out[k])
            if cand is None or _blank(cand):
                continue
            out["title"] = str(cand).strip()[:TITLE_MAX]
            repairs.append(f"title <- {k}")
            break

    # TITLE_MAX applies to the canonical key too. It did not before: the `[:TITLE_MAX]` above runs
    # ONLY on the alias path, so a producer that spelled the key `title` correctly and wrote 400
    # characters reached the artifact untruncated — against the `"maxLength": TITLE_MAX` this module's
    # own `finding_schema()` declares, so contract.py published a bound it did not enforce.
    #
    # The message interpolates TITLE_MAX rather than spelling 300, so the `repairs` string and the
    # schema's `maxLength` both follow the constant when it moves.
    if isinstance(out.get("title"), str) and len(out["title"]) > TITLE_MAX:
        out["title"] = out["title"][:TITLE_MAX]
        repairs.append(f"title truncated to {TITLE_MAX}")

    # Booleans arriving as JSON strings. A producer that serialised `"in_diff": "false"` means
    # false; leaving it a string makes it TRUTHY, which silently opts an out-of-diff finding into
    # blocking. Coerce the unambiguous spellings and record it; anything else stays a defect.
    # `sorted(_BOOLS)`, not bare set iteration. `_BOOLS` is a frozenset of strings, so its iteration
    # order depends on PYTHONHASHSEED and therefore differs BETWEEN PROCESSES — which made the
    # `repairs` list order for a finding carrying both booleans as strings non-deterministic between
    # runs. Sorting costs nothing and makes an audit trail reproducible.
    for k in sorted(_BOOLS):
        v = out.get(k)
        if isinstance(v, str):
            s = v.strip().lower()
            if s in ("true", "false"):
                out[k] = (s == "true")
                repairs.append(f"{k} <- string {v!r}")

    # id, last, and only when there is a claim worth addressing. Synthesised from the severity so
    # the token in the id agrees with the field — several consumers route on the id PREFIX rather
    # than on `severity`, so `F-3` would be routed nowhere while `SCAN-MAJOR-3` routes correctly.
    if index is not None and _blank(out.get("id")):
        sev = str(out.get("severity") or "").strip().upper() or "UNKNOWN"
        out["id"] = f"REPAIRED-{sev}-{index}"
        repairs.append(f"id <- synthesised {out['id']}")

    return out, repairs


def contract_defects(f, required=ACTIONABLE_REQUIRED):
    """Which `required` keys are missing, null, blank, or the wrong type. [] = usable.

    Defaults to `ACTIONABLE_REQUIRED` because the blocking predicate is the caller that matters
    most and must not fail closed on an incomplete-but-actionable finding. Pass
    `CONTRACT_REQUIRED` to check full conformance — that is what the authoring gate does.

    Run `normalize_finding()` FIRST. Repair, then reject only the residue.
    """
    if not isinstance(f, dict):
        return ["not-an-object"]
    defects = []
    for k in required:
        if k not in f:
            defects.append(f"missing:{k}")
        elif f[k] is None:
            defects.append(f"null:{k}")
        elif k in _BOOLS and not isinstance(f[k], bool):
            defects.append(f"not-a-boolean:{k}")
        elif _blank(f[k]):
            defects.append(f"empty:{k}")
    return defects


def contract_gaps(f):
    """Full-contract shortfall: what `contract_defects` tolerates but the contract does not.

    Reported, never used to drop a finding. This is how "incomplete but actionable" stays visible
    instead of being either silently accepted or silently dropped.
    """
    actionable = set(ACTIONABLE_REQUIRED)
    return [d for d in contract_defects(f, CONTRACT_REQUIRED)
            if d.split(":", 1)[-1] not in actionable]


# --- the three axes (reworked in 3.0.0) --------------------------------------------
# severity   = IMPACT only     BLOCKER | MAJOR | MINOR | NIT
# in_diff    = SCOPE           did this change introduce or worsen it
# confidence = CERTAINTY       how well the reviewer traced it
#
# Nothing folds one axis into another. An uncertain finding keeps its severity and ESCALATES
# (verdict INCOMPLETE); it is never downgraded, relabelled NIT, or dropped. An out-of-diff finding
# keeps its severity too — scope is what stops it blocking, not a relabel.
#
# What the floor deliberately does NOT relax:
#   - in_diff — a finding this change did not introduce never blocks it. Without this, lowering
#     the floor would make every change in a legacy repo unmergeable, which disables the gate
#     rather than tightening it.
#   - confidence == HIGH — the certainty gate, now with the third state it was missing. A below-HIGH
#     finding does not BLOCK, but it does ESCALATE to INCOMPLETE, so it can no longer pass unnoticed.


def canon_severity(value) -> str:
    """Upper-case a severity and fold the deprecated INFO input onto NIT.

    Returns "" for anything unrecognised, which callers must surface rather than swallow.
    """
    s = str(value or "").strip().upper()
    s = SEVERITY_ALIASES.get(s, s)
    return s if s in SEVERITY_RANK else ""


def sort_rank(value) -> int:
    """Rank for ORDERING, with a defined position for the unrankable. Never raises."""
    canon = canon_severity(value)
    return SEVERITY_RANK[canon] if canon else UNRANKABLE_SORT_POSITION


def floor_diagnostics(raw=None):
    """Resolve the blocking floor to (rank, note). `note` is None when nothing is odd.

    `raw` is an explicit floor (finalize's `--floor`). When it is None the value comes from
    CODE_REVIEW_BLOCKING_FLOOR, so every existing caller that passes nothing behaves as before.

    Two configured values are accepted-but-not-meaningful, and saying so is the point of this
    function existing rather than just returning a rank. `NIT` (and its deprecated spelling `INFO`)
    name the bottom tier, and the bottom tier is structurally non-blocking — the NIT short-circuit
    sits ABOVE the floor comparison, so no finding's rank ever reaches it. Setting either therefore
    behaves EXACTLY like the default MINOR, and a reader who set `NIT` expecting "block on
    everything" got "block on MINOR and above" with nothing said. An unrecognised value falls back
    to the strict default rather than the permissive one, and that is also worth a line: a typo in
    a gate's configuration must not silently widen it.
    """
    if raw is None:
        raw = os.environ.get("CODE_REVIEW_BLOCKING_FLOOR")
    raw = str(raw or "").strip().upper()
    if not raw:
        return SEVERITY_RANK[DEFAULT_BLOCKING_FLOOR], None
    canon = canon_severity(raw)
    if not canon:
        return (SEVERITY_RANK[DEFAULT_BLOCKING_FLOOR],
                (f"CODE_REVIEW_BLOCKING_FLOOR={raw!r} is not a severity; using the strict default "
                 f"{DEFAULT_BLOCKING_FLOOR} rather than widening the gate."))
    if canon == NIT:
        return (SEVERITY_RANK[DEFAULT_BLOCKING_FLOOR],
                (f"CODE_REVIEW_BLOCKING_FLOOR={raw!r} resolves to the bottom tier, which is "
                 f"structurally non-blocking, so it behaves identically to "
                 f"{DEFAULT_BLOCKING_FLOOR}. No finding blocks at a NIT floor that would not "
                 f"block at MINOR."))
    return SEVERITY_RANK[canon], None


def blocking_floor_rank() -> int:
    """Rank of the configured floor. Unknown/empty values fall back to the strict default."""
    return floor_diagnostics()[0]


def _in_scope_at_floor(f: dict, floor_rank=None) -> bool:
    """Shared body of blocks/escalates: contentful, in-diff, rankable, not a NIT, at/below floor.

    Split out so the two predicates cannot drift on the parts they must agree about — notably the
    NIT short-circuit sitting ABOVE the ux_impact disjunct, and the contract gate above everything.
    `floor_rank` overrides the environment's floor (finalize passes its resolved `--floor`).
    """
    if contract_defects(f):
        # CONTENTLESS -> blocks nothing and escalates nothing. Not a silent pass:
        # normalize_finding() has already tried to repair it, whatever is left is recorded in
        # `contract_health`, and the residue escalates to the TOOLING OWNER. A finding that asserts
        # nothing has no claim to preserve, which is what distinguishes it from an UNCERTAIN
        # finding — that one keeps its severity and drives INCOMPLETE.
        #
        # Above every other clause for the same reason the rankability guard sits above ux_impact:
        # an object carrying a single truthy key must not reach a disjunct that returns True on
        # that key alone. Measured before this gate existed: `{"id": "x", "severity": "MINOR"}`
        # blocked a merge, and at MEDIUM confidence the same object produced INCOMPLETE, a gate the
        # author had no way to clear.
        return False
    if not f.get("in_diff", True):
        return False
    canon = canon_severity(f.get("severity"))
    if not canon:
        # An unrankable severity is not silently non-blocking: the caller reports it as an
        # unknown-severity count. Treated as out of scope HERE only because there is no rank to
        # compare against — and this guard sits ABOVE ux_impact deliberately, or an object carrying
        # `{"ux_impact": true}` and no severity would block at every floor.
        return False
    if SEVERITY_RANK[canon] == SEVERITY_RANK[NIT]:
        # No true impact, by definition — and above the ux_impact clause on purpose. A NIT with
        # real UX impact is a mis-tiered finding, not a blocking NIT.
        return False
    if f.get("ux_impact"):
        return True
    if floor_rank is None:
        floor_rank = blocking_floor_rank()
    return SEVERITY_RANK[canon] <= floor_rank


def finding_blocks(f: dict, floor_rank=None) -> bool:
    """True when a finding should BLOCK the merge, per the configured floor."""
    # `or "HIGH"` (not get's default) so an explicit null coalesces to HIGH, matching the CI-side
    # predicate. get's default fires only on an ABSENT key.
    if str(f.get("confidence") or "HIGH").upper() != "HIGH":
        return False   # -> ESCALATE, see finding_escalates()
    return _in_scope_at_floor(f, floor_rank)


def finding_escalates(f: dict, floor_rank=None) -> bool:
    """True when a finding cannot block only because certainty is missing.

    Drives `verdict: "INCOMPLETE"` — not an assertion that a defect exists, an assertion that a
    human must look. Without this arm, `finding_blocks`' confidence return-False would make an
    uncertain MAJOR vanish, which is the defect the 3.0.0 rework exists to remove.
    """
    # Restated even though `_in_scope_at_floor` gates it too, because THIS is the arm readers copy
    # alone. A contentless finding reaching ESCALATE is worse than one reaching BLOCK: the author
    # can satisfy REQUEST_CHANGES by fixing something, but INCOMPLETE asks a human to look at a
    # claim that does not exist, so nothing clears it.
    if contract_defects(f):
        return False
    if str(f.get("confidence") or "HIGH").upper() == "HIGH":
        return False
    return _in_scope_at_floor(f, floor_rank)


def rollup_verdict(findings, floor_rank=None) -> str:
    """REQUEST_CHANGES > INCOMPLETE > APPROVE, in that precedence."""
    if any(finding_blocks(f, floor_rank) for f in findings):
        return "REQUEST_CHANGES"
    if any(finding_escalates(f, floor_rank) for f in findings):
        return "INCOMPLETE"
    return "APPROVE"


# --- the DOCUMENT envelope (R1) -----------------------------------------------------------------
#
# WHAT THIS ADDS THAT NOTHING ELSE CHECKS. Everything above this line validates a single FINDING.
# Nothing validated the document those findings arrive in, and the document has load-bearing fields:
# The submission gate reads `verdict` and `metrics` to decide whether the review was clean, and
# `metrics.total` is printed to the operator as the count of findings. An artifact with a correct
# `findings` array and a missing `verdict` therefore reads to the gate as... whatever `.get()`
# returns, which is `None`, which is not `REQUEST_CHANGES`, which is indistinguishable from clean.
#
# WHY A SCHEMA AND NOT MORE PYTHON. `agent-contracts/SKILL.md` carried this shape as 500 lines of
# prose and a TypeScript `interface` block — handed to a model, enforced by nobody. That is the exact
# arrangement that produced the contentless-findings defect the top of this file describes: a schema
# in prose loses to a worked example every time. The schema below is generated FROM the constants in
# this module, so it cannot become a second opinion about the same contract; `contract.test.sh`
# asserts the committed copy still matches what this function produces, and
# `python3 contract.py schema --write` regenerates it.
#
# THE DIVISION OF LABOUR IS DELIBERATE, and it is what keeps this from being a duplicate predicate:
#
#   contract_defects()      owns a FINDING's keys. Still the only per-finding predicate. Not
#                           reimplemented here.
#   contract_schema()       owns the ENVELOPE — agent, category, branches, verdict, metrics, and the
#                           fact that `findings` is an array of objects. New ground.
#
# `findings[].required` in the schema is generated from CONTRACT_REQUIRED rather than restated, so
# the two halves agree by construction rather than by review.

#: Rollup verdicts. Derived from `rollup_verdict` above being the only writer of the field — every
#: branch of it returns one of these three, and a fourth value would have to come from an agent
#: inventing one, which is precisely what the enum exists to reject.
VERDICTS = ("APPROVE", "REQUEST_CHANGES", "INCOMPLETE")

#: Per-finding certainty. `finding_blocks`/`finding_escalates` branch on `== "HIGH"`, so anything
#: outside this set silently reads as not-HIGH and escalates. Enumerated so a typo fails loudly
#: instead of quietly turning a blocking finding into an INCOMPLETE one.
CONFIDENCES = ("HIGH", "MEDIUM", "LOW")

#: `metrics` keys, and which may be null. The severity buckets are the lowercased severity names, so
#: they follow SEVERITY_RANK rather than being spelled a second time: renaming a tier renames its
#: bucket, so a renamed tier cannot leave a stale bucket behind.
METRICS_COUNT_KEYS = ("total",) + tuple(s.lower() for s in SEVERITY_RANK) + ("ux_impact_count",)
METRICS_NULLABLE_KEYS = ("coverage_pct",)

#: Envelope keys every agent contract carries.
DOCUMENT_REQUIRED = ("agent", "category", "findings")

#: Envelope keys only the validator's VALIDATED.json carries. Optional everywhere, and listed so the
#: schema can permit them without opening the document to arbitrary extra keys. Their shapes are in
#: `_VALIDATED_ONLY_SCHEMA` below.
VALIDATED_ONLY_KEYS = ("rejected_count", "blocking_reason_ids", "blocking_floor",
                       "incomplete_inputs", "contract_health")

# `contract_health` is the TOOLING-OWNER channel: findings that were repaired onto the contract, and
# findings dropped because nothing actionable was left. It is omitted when both counts are zero.
# `incomplete_inputs` names each required input finalize could not read; it is non-empty exactly when
# the verdict was forced to INCOMPLETE by a missing artifact rather than by an uncertain finding.
_VALIDATED_ONLY_SCHEMA = {
    "rejected_count": {"type": "integer", "minimum": 0},
    "blocking_reason_ids": {"type": "array", "items": {"type": "string"}},
    "blocking_floor": {"enum": list(SEVERITY_RANK)},
    "incomplete_inputs": {
        "type": "array",
        "items": {
            "type": "object",
            "required": ["input", "problem"],
            "properties": {"input": {"type": "string"}, "problem": {"type": "string"}},
        },
    },
    "contract_health": {
        "type": "object",
        "required": ["repaired", "rejected", "repairs", "defects"],
        "properties": {
            "repaired": {"type": "integer", "minimum": 0},
            "rejected": {"type": "integer", "minimum": 0},
            "repairs": {"type": "array"},
            "defects": {"type": "array"},
        },
    },
}


def contract_schema():
    """Return the JSON Schema (draft 2020-12) for an agent contract document, as a dict.

    Generated from this module's constants on every call. There is no cached or committed copy that
    can drift — `schemas/agent-contract.schema.json` is a build artifact of this function, and a gate
    asserts the two are identical.
    """
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://github.com/CatylAI/claude-marketplace/schemas/agent-contract.schema.json",
        "title": "Agent contract document",
        "description": (
            "The .code-review/{CATEGORY}.json contract a gate agent writes. GENERATED from "
            "contract.py's constants by contract_schema(); do not hand-edit. Regenerate with "
            "python3 pipeline/contract.py schema --write."
        ),
        "type": "object",
        "required": list(DOCUMENT_REQUIRED),
        "properties": {
            "agent": {"type": "string", "minLength": 1},
            "category": {"type": "string", "minLength": 1},
            "source_branch": {"type": "string"},
            "target_branch": {"type": "string"},
            # Optional in a specialist's own contract, required in VALIDATED.json. The schema cannot
            # express "required only in one category" without a conditional the generator would have
            # to hardcode a category name into, so it is permitted-but-enumerated here and the
            # per-artifact requirement is asserted by the caller that knows which artifact it holds.
            "verdict": {"enum": list(VERDICTS)},
            "metrics": {
                "type": "object",
                "properties": {
                    **{k: {"type": "integer", "minimum": 0} for k in METRICS_COUNT_KEYS},
                    **{k: {"type": ["number", "null"]} for k in METRICS_NULLABLE_KEYS},
                },
                "additionalProperties": True,
            },
            "findings": {
                "type": "array",
                "items": {
                    "type": "object",
                    # Generated from CONTRACT_REQUIRED, never restated. This is the one place the
                    # envelope schema touches per-finding keys, and it defers rather than deciding.
                    "required": list(CONTRACT_REQUIRED),
                    "properties": {
                        "id": {"type": "string", "minLength": 1},
                        "severity": {"enum": list(SEVERITY_RANK)},
                        "category": {"type": "string", "minLength": 1},
                        "location": {"type": "string", "minLength": 1},
                        "title": {"type": "string", "minLength": 1, "maxLength": TITLE_MAX},
                        "evidence": {"type": "string"},
                        "recommendation": {"type": "string"},
                        **{k: {"type": "boolean"} for k in sorted(_BOOLS)},
                        "confidence": {"enum": list(CONFIDENCES)},
                    },
                    "additionalProperties": True,
                },
            },
            "scan_triage": {"type": "array"},
            **{k: _VALIDATED_ONLY_SCHEMA[k] for k in VALIDATED_ONLY_KEYS},
        },
        # TRUE, deliberately. An agent adding a field is not a defect worth failing a review over,
        # and `additionalProperties: false` would make every future field a breaking change to a
        # contract four agents and two orchestrators already implement. The keys that MATTER are
        # covered by `required` and by the enums; an unknown key is inert.
        "additionalProperties": True,
    }


# --- the validator's decisions ------------------------------------------------------------------
#
# The validator agent reads code and makes judgement calls: is this finding real, is it where it says,
# did the diff cause it, is it the same as that other one. Everything after those calls is arithmetic
# — severity mapping, dedup of identical findings, the blocking predicate, counts, ids, the verdict —
# and arithmetic done by a model from a prose restatement is how the prompt and this module drifted
# apart. So the agent writes only its judgements, in VALIDATOR-DECISIONS.json, and `finalize` below
# does the arithmetic.

DECISIONS_FILE = "VALIDATOR-DECISIONS.json"

#: Where a decided finding came from: one agent contract artifact each, all read by finalize itself.
#: SCAN and SEMANTIC are always required; the other three only when CONTEXT.json spawned them.
DECISION_SOURCES = ("SCAN", "SEMANTIC", "TESTING", "ARCHITECTURE", "CLAUDE_CONFIG")
_SOURCE_FILES = {
    "SCAN": "SCAN.json",
    "SEMANTIC": "SEMANTIC.json",
    "TESTING": "TESTING.json",
    "ARCHITECTURE": "ARCHITECTURE.json",
    "CLAUDE_CONFIG": "CLAUDE_CONFIG.json",
}
#: The CONTEXT.json gate that decides whether a conditional source was spawned.
_SOURCE_GATES = {"TESTING": "testing", "ARCHITECTURE": "architect", "CLAUDE_CONFIG": "claude_config"}

#: What the validator decided. `keep` may also correct fields; `merge` folds a duplicate into another
#: finding; `reject` removes a finding and must carry one of REJECT_REASONS.
DECISION_ACTIONS = ("keep", "reject", "merge")

#: The closed set of reasons a finding may be removed. "Out of diff" is deliberately NOT here: an
#: out-of-diff finding is kept with `in_diff: false` and its severity unchanged. Being unsure is not
#: here either; uncertainty is `confidence`, and it escalates rather than deletes.
REJECT_REASONS = ("INVALID_LOCATION", "ALREADY_ADDRESSED", "FALSE_POSITIVE", "TRIAGE_DROP")

#: Finding keys a decision may set or correct. `id` is not one: finalize numbers the output itself.
DECISION_FINDING_KEYS = tuple(k for k in CONTRACT_REQUIRED if k != "id")

#: The intrinsic-severity vocabulary `review-architect` writes, mapped 1:1 onto the contract tiers.
#: Impact only: scope is `in_diff` and certainty is `confidence`, so neither appears here.
INTRINSIC_SEVERITY = {"CRITICAL": BLOCKER, "HIGH": MAJOR, "MEDIUM": MINOR, "LOW": NIT}


def decisions_schema():
    """JSON Schema for VALIDATOR-DECISIONS.json, generated from the constants above.

    Committed as `schemas/validator-decisions.schema.json`; contract.test.sh fails if the two differ.
    finalize does not need a schema library: `_decision_error` enforces the same rules, one decision
    at a time, so a single bad entry is reported instead of discarding the whole file.
    """
    finding_props = contract_schema()["properties"]["findings"]["items"]["properties"]
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://github.com/CatylAI/claude-marketplace/schemas/validator-decisions.schema.json",
        "title": "Validator decisions",
        "description": (
            "The .code-review/VALIDATOR-DECISIONS.json file review-validator writes. GENERATED from "
            "contract.py by decisions_schema(); do not hand-edit. Regenerate with "
            "python3 pipeline/contract.py schema --write."
        ),
        "type": "object",
        "required": ["agent", "decisions"],
        "properties": {
            "agent": {"const": "review-validator"},
            "decisions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["source", "source_id", "action"],
                    "properties": {
                        "source": {"enum": list(DECISION_SOURCES)},
                        "source_id": {"type": "string", "minLength": 1},
                        "action": {"enum": list(DECISION_ACTIONS)},
                        "reason": {"enum": list(REJECT_REASONS)},
                        "merged_into": {"type": "string", "minLength": 1},
                        "detail": {"type": "string"},
                        "finding": {
                            "type": "object",
                            "properties": {k: finding_props[k] for k in DECISION_FINDING_KEYS},
                            "additionalProperties": True,
                        },
                    },
                    "allOf": [
                        {"if": {"properties": {"action": {"const": "reject"}}},
                         "then": {"required": ["reason"]}},
                        {"if": {"properties": {"action": {"const": "merge"}}},
                         "then": {"required": ["merged_into"]}},
                    ],
                    "additionalProperties": True,
                },
            },
            "notes": {"type": "array", "items": {"type": "string"}},
            "positive_observations": {"type": "array", "items": {"type": "string"}},
        },
        "additionalProperties": True,
    }


def _decision_error(d, addr, resolve_target):
    """Check decision `d`. Returns (error, key, target_key); `error` is None when it can be applied.

    `addr` maps (source, source_id) to the finding's key. `resolve_target` turns a `merged_into`
    value into a key, or returns (None, error). A rejected decision is not fatal. The finding it
    named is treated as undecided, which keeps it (see `finalize`), so a malformed entry can never
    delete a finding.
    """
    if not isinstance(d, dict):
        return "not an object", None, None
    source, sid, action = d.get("source"), d.get("source_id"), d.get("action")
    if source not in DECISION_SOURCES:
        return f"source {source!r} is not one of {list(DECISION_SOURCES)}", None, None
    if not isinstance(sid, str) or not sid.strip():
        return "source_id is missing or blank", None, None
    if action not in DECISION_ACTIONS:
        return f"action {action!r} is not one of {list(DECISION_ACTIONS)}", None, None
    if "finding" in d and not isinstance(d["finding"], dict):
        return "finding is not an object", None, None
    key = addr.get((source, sid))
    if key is None:
        return f"source_id {sid!r} does not match any finding in {_SOURCE_FILES[source]}", None, None
    if action == "reject" and d.get("reason") not in REJECT_REASONS:
        return f"reject reason {d.get('reason')!r} is not one of {list(REJECT_REASONS)}", key, None
    target = None
    if action == "merge":
        target, err = resolve_target(d.get("merged_into"))
        if err is not None:
            return err, key, None
        if target == key:
            return "merged_into names the finding itself", key, None
    return None, key, target


# --- finalize -----------------------------------------------------------------------------------

def _read_json(path):
    """(document, problem). Exactly one is None."""
    if not os.path.isfile(path):
        return None, "missing"
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh), None
    except (OSError, ValueError) as exc:
        return None, f"not parseable JSON ({exc.__class__.__name__}: {exc})"


def _load_artifact(out_dir, name, problems):
    """Load an agent contract artifact. Records a problem and returns None when it is unusable."""
    doc, problem = _read_json(os.path.join(out_dir, name))
    if problem is None and not (isinstance(doc, dict) and isinstance(doc.get("findings"), list)):
        problem = "has no findings array"
    if problem is not None:
        problems.append({"input": name, "problem": problem})
        return None
    return doc


def _canon_confidence(v):
    """(value, repair or None). Absent means HIGH, matching the predicate; unknown means LOW."""
    if _blank(v):
        return "HIGH", "confidence <- HIGH (absent)"
    s = str(v).strip().upper()
    if s in CONFIDENCES:
        return s, (None if s == v else f"confidence <- {s} (from {v!r})")
    return "LOW", f"confidence <- LOW (unrecognised {v!r})"


def _shape_finding(f, source):
    """Normalise one kept finding onto the full contract. Returns (finding, repairs, defects).

    Repairs are what finalize changed; defects are what it could not fix. A finding with defects is
    dropped from `findings` and reported in `contract_health` with its raw object.
    """
    raw = f
    f, repairs = normalize_finding(f)
    if not isinstance(f, dict):
        return raw, repairs, ["not-an-object"]
    repairs = list(repairs)

    sev_raw = f.get("severity")
    sev_key = str(sev_raw or "").strip().upper()
    if sev_key in INTRINSIC_SEVERITY:
        f["severity"] = INTRINSIC_SEVERITY[sev_key]
        repairs.append(f"severity <- {f['severity']} (intrinsic {sev_raw!r})")
    else:
        canon = canon_severity(sev_raw)
        if canon and canon != sev_raw:
            f["severity"] = canon
            repairs.append(f"severity <- {canon} (from {sev_raw!r})")

    conf, note = _canon_confidence(f.get("confidence"))
    f["confidence"] = conf
    if note:
        repairs.append(note)

    # Scope defaults to in-diff, the same default the predicate applies, and it is recorded because
    # it can decide whether the finding blocks.
    if "in_diff" not in f or f["in_diff"] is None:
        f["in_diff"] = True
        repairs.append("in_diff <- true (absent)")
    if "ux_impact" not in f or f["ux_impact"] is None:
        f["ux_impact"] = False
    for k in ("evidence", "recommendation"):
        f[k] = "" if f.get(k) is None else str(f[k])
    if _blank(f.get("category")):
        f["category"] = source

    defects = contract_defects(f)
    if not canon_severity(f.get("severity")) and not any(d.endswith(":severity") for d in defects):
        defects.append("unrankable:severity")
    for k in sorted(_BOOLS):
        if not isinstance(f.get(k), bool):
            defects.append(f"not-a-boolean:{k}")
    return f, repairs, defects


def _apply_corrections(f, corr, source):
    """Apply a `keep` decision's field corrections to finding `f`. Returns (finding, refused).

    Each corrected key is tried on its own, and one that would give the finding a contract defect it
    did not already have is refused and reported instead of applied. Without this, a keep whose
    correction was malformed (`"severity": "MAJ"`, a blank title, a list of locations) sent a real,
    confirmed finding to `contract_health` as unusable, so a keep deleted it. `refused` is a list of
    (key, defects) pairs.
    """
    before = set(_shape_finding(f, source)[2])
    out, refused = dict(f), []
    for k in DECISION_FINDING_KEYS:
        if k not in corr:
            continue
        trial = dict(out)
        trial[k] = corr[k]
        added = [x for x in _shape_finding(trial, source)[2] if x not in before]
        if added:
            refused.append((k, ", ".join(added)))
        else:
            out = trial
    return out, refused


def _str_list(v):
    """The string items of `v` when it is a list. A lone string is one item, never its characters."""
    if isinstance(v, str):
        return [v] if v.strip() else []
    return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []


#: Certainty order for folding duplicates: the lower number is the stronger claim.
_CONFIDENCE_RANK = {c: i for i, c in enumerate(CONFIDENCES)}


def _atomic_write(path, text):
    """Write via a temp file in the same directory, then rename, so a reader never sees half a file."""
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def finalize(out_dir, floor=None):
    """Build VALIDATED.json/.md (and CONTRACT-DEFECTS.md when needed) in `out_dir`.

    Returns the exit code: 0 when every required input was usable, 2 when one was missing or
    unparseable. VALIDATED.json is written in both cases; on 2 its verdict is INCOMPLETE and
    `incomplete_inputs` names what was missing.
    """
    os.makedirs(out_dir, exist_ok=True)
    incomplete = []

    # ---- inputs. CONTEXT.json is not a contract document, so it is loaded without the findings check.
    ctx, problem = _read_json(os.path.join(out_dir, "CONTEXT.json"))
    if problem is None and not isinstance(ctx, dict):
        problem = "is not a JSON object"
    if problem is not None:
        incomplete.append({"input": "CONTEXT.json", "problem": problem})
        ctx = {}

    # Gated agents are required only when prepare-context.sh spawned them. Each writes its file even
    # when it finds nothing, so a spawned agent with no file died; that is not a clean pass.
    docs = {}
    for source, name in _SOURCE_FILES.items():
        gate = _SOURCE_GATES.get(source)
        if gate is None or (ctx.get(gate) or {}).get("spawn") is True:
            docs[source] = _load_artifact(out_dir, name, incomplete)

    ddoc, problem = _read_json(os.path.join(out_dir, DECISIONS_FILE))
    if problem is None and not (isinstance(ddoc, dict) and isinstance(ddoc.get("decisions"), list)):
        problem = "has no decisions array"
    if problem is not None:
        incomplete.append({"input": DECISIONS_FILE, "problem": problem})
        ddoc = {"decisions": []}

    # ---- every input finding. `key` is its handle in `source_ids` and the audit log: the producer's
    # id when no other source uses that id, `SOURCE:id` when two sources do, and `SOURCE#index` when
    # it has no id or repeats one inside its own file. Decisions name a finding by (source,
    # source_id), and `addr` maps that pair onto the key. Keying on the id alone meant that when
    # SEMANTIC and TESTING both emitted `X-1`, TESTING's finding became `TESTING#0`, which no
    # decision could name, so it was always capped to MEDIUM and escalated.
    raw_inputs, id_sources = [], {}
    for source in DECISION_SOURCES:
        doc = docs.get(source)
        if not doc:
            continue
        for i, f in enumerate(doc["findings"]):
            fid = f.get("id") if isinstance(f, dict) else None
            fid = fid if isinstance(fid, str) and fid.strip() else None
            raw_inputs.append((source, i, fid, f))
            if fid:
                id_sources.setdefault(fid, set()).add(source)
    inputs = []          # [(key, source, finding)] in a stable order
    known, addr = {}, {}
    for source, i, fid, f in raw_inputs:
        if fid is None or (source, fid) in addr:
            key = f"{source}#{i}"
        else:
            key = fid if len(id_sources[fid]) == 1 else f"{source}:{fid}"
            addr[(source, fid)] = key
        known[key] = source
        inputs.append((key, source, f))

    def resolve_target(target):
        """`merged_into` -> (key, None), or (None, error). A bare id must name exactly one finding."""
        if not isinstance(target, str) or not target.strip():
            return None, f"merged_into {target!r} does not match any finding"
        hits = [k for (_, sid), k in addr.items() if sid == target]
        if len(hits) == 1:
            return hits[0], None
        if len(hits) > 1:
            return None, (f"merged_into {target!r} is ambiguous: "
                          + ", ".join(sorted(known[k] for k in hits))
                          + " all have it; name it as SOURCE:id")
        if target in known:
            return target, None
        return None, f"merged_into {target!r} does not match any finding"

    # ---- decisions. The first valid decision per finding wins; later ones are reported.
    decisions, decision_errors = {}, []   # key -> (decision, merge-target key)
    for i, d in enumerate(ddoc.get("decisions") or []):
        err, key, target = _decision_error(d, addr, resolve_target)
        if err is None and key in decisions:
            err = "a second decision for the same source_id"
        if err is not None:
            decision_errors.append({"index": i, "source_id": (d.get("source_id") if isinstance(d, dict)
                                                             else None), "error": err})
            continue
        decisions[key] = (d, target)

    # A merge into a finding that is itself rejected or merged would make the duplicate vanish with
    # its target. That is a deletion nobody decided, so such a merge is refused and the finding kept.
    for key, (d, target) in list(decisions.items()):
        if d["action"] == "merge" and decisions.get(target, ({}, None))[0].get("action") in (
                "reject", "merge"):
            decision_errors.append({"index": None, "source_id": key,
                                    "error": "merged_into names a finding that is itself rejected "
                                             "or merged"})
            del decisions[key]

    # ---- apply.
    kept, merges, audit = {}, [], []
    rejected_count = 0
    for key, source, f in inputs:
        d, target = decisions.get(key, (None, None))
        if d is None:
            base = dict(f) if isinstance(f, dict) else f
            if source != "SCAN" and isinstance(base, dict):
                # A model judgement nobody re-read is a proposal, not a result. It is kept (never
                # deleted for lack of a decision) and its certainty is capped, so it escalates.
                if str(base.get("confidence") or "HIGH").strip().upper() == "HIGH":
                    base["confidence"] = "MEDIUM"
                audit.append({"source_id": key, "source": source, "action": "unreviewed",
                              "reason": None, "detail": "no validator decision; kept, confidence "
                                                        "capped at MEDIUM"})
            kept[key] = (source, base)
            continue
        audit.append({"source_id": key, "source": source, "action": d["action"],
                      "reason": d.get("reason"), "detail": str(d.get("detail") or "")})
        if d["action"] == "reject":
            rejected_count += 1
            continue
        if d["action"] == "merge":
            merges.append((key, target, f))
            continue
        base = dict(f) if isinstance(f, dict) else f
        if isinstance(base, dict) and d.get("finding"):
            base, refused = _apply_corrections(base, d["finding"], source)
            for k, why in refused:
                decision_errors.append({"index": None, "source_id": key,
                                        "error": f"correction {k}={d['finding'][k]!r} ignored: it "
                                                 f"would make the finding unusable ({why})"})
        kept[key] = (source, base)

    # ---- shape every kept finding onto the contract.
    findings, repairs_log, defects_log = {}, [], []
    for key, (source, f) in kept.items():
        shaped, repairs, defects = _shape_finding(f, source)
        if defects:
            defects_log.append({"source_id": key, "defects": defects, "raw": f})
            continue
        if repairs:
            repairs_log.append({"source_id": key, "repairs": repairs})
        shaped["source_ids"] = [key]
        shaped["related_locations"] = []
        findings[key] = shaped

    def fold(target, dup_key, dup):
        """Fold a SHAPED duplicate into `target`, keeping the stronger claim on every axis.

        Higher severity, and every location, as before. Also in-diff over out-of-diff, the higher
        confidence and ux_impact: two findings folded into one are one claim, and the survivor must
        not be weaker than either input. Folding only severity let an out-of-diff copy absorb an
        in-diff HIGH one and turned REQUEST_CHANGES into APPROVE.
        """
        target["source_ids"].append(dup_key)
        if not isinstance(dup, dict):
            return
        loc = dup.get("location")
        if isinstance(loc, str) and loc.strip() and loc != target["location"] \
                and loc not in target["related_locations"]:
            target["related_locations"].append(loc)
        dsev = canon_severity(dup.get("severity"))
        if dsev and SEVERITY_RANK[dsev] < SEVERITY_RANK[target["severity"]]:
            target["severity"] = dsev
        for k in ("in_diff", "ux_impact"):
            if dup.get(k) is True:
                target[k] = True
        dconf = dup.get("confidence")
        if dconf in _CONFIDENCE_RANK and \
                _CONFIDENCE_RANK[dconf] < _CONFIDENCE_RANK[target["confidence"]]:
            target["confidence"] = dconf

    merged_count = 0
    for dup_key, target_key, dup in merges:
        if target_key in findings:
            # Shaped first, so the architect's intrinsic scale (CRITICAL/HIGH/...) and every other
            # repair apply to the duplicate too. The raw object's `CRITICAL` read as no severity at
            # all, so a BLOCKER merged into a MINOR finding stayed MINOR.
            fold(findings[target_key], dup_key, _shape_finding(dup, known[dup_key])[0])
            merged_count += 1
        else:
            # The target was dropped as contentless. Keep the duplicate rather than lose both.
            shaped, repairs, defects = _shape_finding(dup, known[dup_key])
            if defects:
                defects_log.append({"source_id": dup_key, "defects": defects, "raw": dup})
            else:
                shaped["source_ids"], shaped["related_locations"] = [dup_key], []
                findings[dup_key] = shaped

    # Identical claims from two producers (same location, same title) are one finding.
    seen = {}
    for key in list(findings):
        f = findings[key]
        sig = (f["location"].strip(), str(f["title"]).strip().lower())
        if sig in seen:
            fold(findings[seen[sig]], key, f)
            findings[seen[sig]]["source_ids"].extend(f["source_ids"][1:])
            del findings[key]
            merged_count += 1
        else:
            seen[sig] = key

    # ---- number, count, decide.
    ordered = sorted(findings.values(),
                     key=lambda f: (sort_rank(f["severity"]), f["location"], f["source_ids"][0]))
    per_sev = {s: 0 for s in SEVERITY_RANK}
    for f in ordered:
        per_sev[f["severity"]] += 1
        f["id"] = f"VALIDATED-{f['severity']}-{per_sev[f['severity']]}"
        if not f["related_locations"]:
            del f["related_locations"]

    floor_rank, floor_note = floor_diagnostics(floor)
    floor_name = next(s for s, r in SEVERITY_RANK.items() if r == floor_rank)
    blocking = [f["id"] for f in ordered if finding_blocks(f, floor_rank)]
    escalated = [f["id"] for f in ordered if finding_escalates(f, floor_rank)]
    if incomplete:
        verdict, reason_ids = "INCOMPLETE", blocking + escalated
    else:
        verdict = rollup_verdict(ordered, floor_rank)
        reason_ids = blocking if verdict == "REQUEST_CHANGES" else \
            escalated if verdict == "INCOMPLETE" else []

    scan = docs.get("SCAN") or {}
    cov = (scan.get("metrics") or {}).get("coverage_pct")
    coverage_pct = cov if isinstance(cov, (int, float)) and not isinstance(cov, bool) else None

    notes = []
    if floor_note:
        notes.append(floor_note)
    if (ctx.get("worktree") or {}).get("matches_reviewed_ref") is False:
        notes.append("The working tree is not the reviewed commit; locations were checked against "
                     "DIFF.md.")
    diff = ctx.get("diff") or {}
    if diff.get("lines_byte_truncated"):
        notes.append("Some diff lines were byte-truncated in DIFF.md; those regions were not fully "
                     "read.")
    if diff.get("files_omitted"):
        notes.append(f"{len(diff['files_omitted'])} changed file(s) were omitted from DIFF.md by the "
                     "line budget and were not reviewed.")
    skipped = [s.get("tool") for s in ((scan.get("scan_meta") or {}).get("tools_skipped") or [])
               if isinstance(s, dict)]
    if skipped:
        notes.append("Scanner tools skipped: " + ", ".join(str(t) for t in skipped) + ".")
    # Each judge records what it could not check; a gap one agent admitted must reach the reader.
    for source, doc in docs.items():
        cov_block = (doc or {}).get("coverage")
        gaps = cov_block.get("gaps_not_covered") if isinstance(cov_block, dict) else None
        for g in gaps if isinstance(gaps, list) else []:
            notes.append(f"{source}: not covered: {g}")
    # A list is required: a bare string would otherwise iterate one character per note.
    notes.extend(n for n in _str_list(ddoc.get("notes")))

    contract = {
        "agent": "review-validator",
        "category": "VALIDATED",
        "source_branch": str(ctx.get("source_branch") or (docs.get("SEMANTIC") or {}).get(
            "source_branch") or ""),
        "target_branch": str(ctx.get("target_branch") or (docs.get("SEMANTIC") or {}).get(
            "target_branch") or ""),
        "findings": ordered,
        "verdict": verdict,
        "metrics": {
            "total": len(ordered),
            **{s.lower(): per_sev[s] for s in SEVERITY_RANK},
            "coverage_pct": coverage_pct,
            "ux_impact_count": sum(1 for f in ordered if f["ux_impact"] and f["in_diff"]),
        },
        "rejected_count": rejected_count,
        "merged_count": merged_count,
        "blocking_reason_ids": reason_ids,
        "blocking_floor": floor_name,
        "incomplete_inputs": incomplete,
        "decision_errors": decision_errors,
        "audit_log": audit,
        "coverage_notes": notes,
        "positive_observations": _str_list(ddoc.get("positive_observations")),
    }
    if repairs_log or defects_log:
        contract["contract_health"] = {"repaired": len(repairs_log), "rejected": len(defects_log),
                                       "repairs": repairs_log, "defects": defects_log}

    _atomic_write(os.path.join(out_dir, "VALIDATED.json"), json.dumps(contract, indent=2) + "\n")
    _atomic_write(os.path.join(out_dir, "VALIDATED.md"),
                  _render_validated_md(contract, escalated, skipped))
    defects_md = os.path.join(out_dir, "CONTRACT-DEFECTS.md")
    if "contract_health" in contract:
        _atomic_write(defects_md, _render_defects_md(contract["contract_health"]))
    elif os.path.exists(defects_md):
        os.remove(defects_md)   # a stale banner from an earlier run would describe the wrong review
    return 2 if incomplete else 0


def _one_line(v, limit=200):
    s = " ".join(str(v or "").split())
    return s if len(s) <= limit else s[: limit - 1] + "…"


def _render_validated_md(c, escalated, skipped):
    """The human-readable companion. Everything in it comes from the contract dict `c`."""
    m = c["metrics"]
    out = [
        "# Validated Review Findings", "",
        f"**Source:** {c['source_branch'] or '(unknown)'}  ",
        f"**Target:** {c['target_branch'] or '(unknown)'}  ",
        f"**Validated at:** {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%dT%H:%M:%SZ}  ",
        f"**Verdict:** {c['verdict']}  ",
        f"**Blocking floor:** {c['blocking_floor']}", "",
    ]
    if c["incomplete_inputs"]:
        out += ["## Incomplete inputs", "",
                "The review did not finish, so the verdict is INCOMPLETE whatever the findings say.", ""]
        out += [f"- `{p['input']}`: {p['problem']}" for p in c["incomplete_inputs"]] + [""]

    actions = {}
    for a in c["audit_log"]:
        k = a["action"] if a["action"] != "reject" else f"reject:{a['reason']}"
        actions[k] = actions.get(k, 0) + 1
    out += ["## Summary", "", "| Status | Count |", "|---|---|"]
    out += [f"| {s} | {m[s.lower()]} |" for s in SEVERITY_RANK]
    out += [f"| Escalated (in-diff, below HIGH confidence) | {len(escalated)} |",
            f"| Reported only (out of diff) | {sum(1 for f in c['findings'] if not f['in_diff'])} |"]
    out += [f"| Rejected ({r}) | {actions.get('reject:' + r, 0)} |" for r in REJECT_REASONS]
    out += [f"| Merged (duplicate) | {c['merged_count']} |",
            f"| Unreviewed by the validator | {actions.get('unreviewed', 0)} |", ""]

    if "coverage" in skipped or m["coverage_pct"] is None:
        cov = "UNABLE TO MEASURE"
    elif any(f.get("tool") == "coverage" for f in c["findings"]):
        cov = f"BELOW THE PROJECT GATE ({m['coverage_pct']}%)"
    else:
        cov = f"MEETS THE PROJECT GATE ({m['coverage_pct']}%)"
    out += ["## Test coverage", "", f"**Status:** {cov}", ""]

    def block(f):
        lines = [f"#### [{f['id']}] {_one_line(f['title'])}", "",
                 f"**Category:** {f['category']} · **Confidence:** {f['confidence']} · "
                 f"**Scope:** {'in-diff' if f['in_diff'] else 'out-of-diff'} · "
                 f"**From:** {', '.join(f['source_ids'])}  ",
                 f"**Location:** `{f['location']}`"
                 + ("".join(f", `{loc}`" for loc in f.get("related_locations", []))), ""]
        if f["evidence"]:
            lines += [f["evidence"], ""]
        if f["recommendation"]:
            lines += [f"**Remediation:** {f['recommendation']}", ""]
        return lines

    in_diff = [f for f in c["findings"] if f["in_diff"]]
    out += ["## Findings", ""]
    if not c["findings"]:
        out += ["No findings.", ""]
    for s in SEVERITY_RANK:
        group = [f for f in in_diff if f["severity"] == s]
        if group:
            out += [f"### {s}", ""]
            for f in group:
                out += block(f)
    esc = [f for f in c["findings"] if f["id"] in escalated]
    if esc:
        out += ["### Escalated (a human must look)", "",
                "Listed above at their own severity; they drive INCOMPLETE because the validator "
                "could not confirm them to HIGH confidence.", ""]
        out += [f"- `{f['id']}` {_one_line(f['title'])}" for f in esc] + [""]
    out_diff = [f for f in c["findings"] if not f["in_diff"]]
    if out_diff:
        out += ["### Reported only (out of diff)", "",
                "Severity unchanged. This change did not introduce these, so they do not block it.",
                ""]
        for f in out_diff:
            out += block(f)

    out += ["## Audit log", "", "| Source id | Source | Action | Reason | Detail |", "|---|---|---|---|---|"]
    out += [f"| {a['source_id']} | {a['source']} | {a['action']} | {a['reason'] or ''} | "
            f"{_one_line(a['detail'], 160).replace('|', '/')} |" for a in c["audit_log"]]
    out.append("")
    if c["decision_errors"]:
        out += ["## Decisions that could not be applied", ""]
        out += [f"- `{e['source_id']}`: {e['error']}" for e in c["decision_errors"]] + [""]
    if c["coverage_notes"]:
        out += ["## Notes", ""] + [f"- {n}" for n in c["coverage_notes"]] + [""]
    if c["positive_observations"]:
        out += ["## Positive observations", ""] + [f"- {p}" for p in c["positive_observations"]] + [""]
    if "contract_health" in c:
        out += ["See `CONTRACT-DEFECTS.md` for findings the contract step repaired or dropped.", ""]
    return "\n".join(out)


def _render_defects_md(h):
    """The tooling-owner banner. The raw object is included so a dropped finding stays recoverable."""
    out = ["# Contract defects", "",
           "For the TOOLING OWNER, not the change author: these are defects in what the review agents "
           "emitted, not in the change under review.", "",
           f"- Repaired: {h['repaired']}", f"- Dropped (nothing actionable left): {h['rejected']}", ""]
    if h["repairs"]:
        out += ["## Repairs", ""]
        out += [f"- `{r['source_id']}`: {'; '.join(r['repairs'])}" for r in h["repairs"]] + [""]
    if h["defects"]:
        out += ["## Dropped", ""]
        out += [f"- `{d['source_id']}`: {', '.join(d['defects'])} — raw: "
                f"`{_one_line(json.dumps(d['raw'], default=str), 400)}`" for d in h["defects"]] + [""]
    return "\n".join(out)


# --- command line -------------------------------------------------------------------------------

_SCHEMA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schemas")
_SCHEMAS = {"agent-contract.schema.json": contract_schema,
            "validator-decisions.schema.json": decisions_schema}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="contract.py", description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    fin = sub.add_parser("finalize", help="write VALIDATED.json/.md from the agent artifacts")
    fin.add_argument("--dir", default=".code-review", help="artifact directory (default .code-review)")
    fin.add_argument("--floor", default=None,
                     help="blocking floor BLOCKER|MAJOR|MINOR; default $CODE_REVIEW_BLOCKING_FLOOR, "
                          "else MINOR")
    sch = sub.add_parser("schema", help="print or regenerate the committed JSON schemas")
    sch.add_argument("--write", action="store_true", help="rewrite the files under schemas/")
    args = ap.parse_args(argv)

    if args.cmd == "schema":
        for name, gen in _SCHEMAS.items():
            text = json.dumps(gen(), indent=2) + "\n"
            if args.write:
                _atomic_write(os.path.join(_SCHEMA_DIR, name), text)
                print(f"wrote schemas/{name}")
            else:
                print(f"--- {name}\n{text}")
        return 0

    rc = finalize(args.dir, args.floor)
    with open(os.path.join(args.dir, "VALIDATED.json"), encoding="utf-8") as fh:
        doc = json.load(fh)
    for p in doc["incomplete_inputs"]:
        print(f"finalize: {p['input']}: {p['problem']}", file=sys.stderr)
    for e in doc["decision_errors"]:
        print(f"finalize: decision for {e['source_id']!r} ignored: {e['error']}", file=sys.stderr)
    print(f"{doc['verdict']}: {doc['metrics']['total']} finding(s), floor {doc['blocking_floor']}, "
          f"wrote {os.path.join(args.dir, 'VALIDATED.json')}")
    return rc


if __name__ == "__main__":
    sys.exit(main())


