"""contract.py — the ONE definition of the finding contract: what makes a finding USABLE, and
what makes a usable finding BLOCK.

Both halves live here on purpose. An earlier version of this module carried only the content half
and left the blocking predicate in `normalize.py`, which meant the file named "contract" held half
a contract while the half with the most duplicates stayed outside it. Consolidating them cut the
in-repo copy count from four to three: this module is the implementation, and the only remaining
copies are the two RESTATEMENTS that cannot import anything —
`agents/review-validator.md` (no `python3` grant, so there is no process to import into) and the
`agent-contracts` skill body in the standards plugin (injected as text). `review-scan.sh` used to
be a fourth copy and now imports instead.

No shebang: this module is imported, never executed.

WHY THIS LIVES BESIDE THE PIPELINE AND NOT IN THE STANDARDS PLUGIN. The dependency direction that
argument rests on is real — `agent-contracts` is the canonical CONTRACT and this pipeline is its
consumer, and the dependency is declared, so the move would not introduce undeclared coupling. It
is declined for a different, measured reason: a VENDORED layout separates the two trees with no
stable relative path between them. Vendored into a CI image, `normalize.py` lands at
`scripts/review/normalize.py` while `agent-contracts/SKILL.md` lands at
`.claude/skills/agent-contracts/SKILL.md` — a different relationship from the source tree's
`pipeline/` vs the standards plugin's `skills/agent-contracts/`. Any `sys.path` computation that
resolved in the repo would break in CI, and it would break at import time, mid-review. So the
executable sits beside the code that imports it, and `agent-contracts/SKILL.md` carries the
RESTATEMENT that keeps the canonical document self-contained. A predicate-parity check is what
stops those two drifting, which is the guarantee co-location would have bought.

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
`CONTRACT_REQUIRED` is the full ten-key contract. It is what the *authoring* gate enforces on
worked examples in agent prompts (`scripts/check-agent-json-contracts.sh`), because an example is
a template and a template should be complete.

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

import os
import re

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

# The full contract, per the `agent-contracts` skill ("interface Finding").
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
    # The message interpolates TITLE_MAX rather than spelling 300, which makes the constant itself
    # comparable: a restatement that hardcodes `[:300]` while this file's TITLE_MAX moves now emits a
    # different `repairs` string, so `check-predicate-parity.py` reports it. A numeric constant read by
    # two copies is otherwise invisible to a matrix whose axes are only the alias NAMES.
    if isinstance(out.get("title"), str) and len(out["title"]) > TITLE_MAX:
        out["title"] = out["title"][:TITLE_MAX]
        repairs.append(f"title truncated to {TITLE_MAX}")

    # Booleans arriving as JSON strings. A producer that serialised `"in_diff": "false"` means
    # false; leaving it a string makes it TRUTHY, which silently opts an out-of-diff finding into
    # blocking. Coerce the unambiguous spellings and record it; anything else stays a defect.
    # `sorted(_BOOLS)`, not bare set iteration. `_BOOLS` is a frozenset of strings, so its iteration
    # order depends on PYTHONHASHSEED and therefore differs BETWEEN PROCESSES — which made the
    # `repairs` list order for a finding carrying both booleans as strings non-deterministic, and made
    # it uncomparable to the restatement `check-predicate-parity.py` now executes in a child
    # interpreter. Sorting costs nothing and makes an audit trail reproducible.
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


def floor_diagnostics():
    """Resolve CODE_REVIEW_BLOCKING_FLOOR to (rank, note). `note` is None when nothing is odd.

    Two configured values are accepted-but-not-meaningful, and saying so is the point of this
    function existing rather than just returning a rank. `NIT` (and its deprecated spelling `INFO`)
    name the bottom tier, and the bottom tier is structurally non-blocking — the NIT short-circuit
    sits ABOVE the floor comparison, so no finding's rank ever reaches it. Setting either therefore
    behaves EXACTLY like the default MINOR, and a reader who set `NIT` expecting "block on
    everything" got "block on MINOR and above" with nothing said. An unrecognised value falls back
    to the strict default rather than the permissive one, and that is also worth a line: a typo in
    a gate's configuration must not silently widen it.
    """
    raw = str(os.environ.get("CODE_REVIEW_BLOCKING_FLOOR") or "").strip().upper()
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


def _in_scope_at_floor(f: dict) -> bool:
    """Shared body of blocks/escalates: contentful, in-diff, rankable, not a NIT, at/below floor.

    Split out so the two predicates cannot drift on the parts they must agree about — notably the
    NIT short-circuit sitting ABOVE the ux_impact disjunct, and the contract gate above everything.
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
    return SEVERITY_RANK[canon] <= blocking_floor_rank()


def finding_blocks(f: dict) -> bool:
    """True when a finding should BLOCK the merge, per the configured floor."""
    # `or "HIGH"` (not get's default) so an explicit null coalesces to HIGH, matching the validator
    # and the CI-side predicate. get's default fires only on an ABSENT key.
    if str(f.get("confidence") or "HIGH").upper() != "HIGH":
        return False   # -> ESCALATE, see finding_escalates()
    return _in_scope_at_floor(f)


def finding_escalates(f: dict) -> bool:
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
    return _in_scope_at_floor(f)


def rollup_verdict(findings) -> str:
    """REQUEST_CHANGES > INCOMPLETE > APPROVE, in that precedence."""
    if any(finding_blocks(f) for f in findings):
        return "REQUEST_CHANGES"
    if any(finding_escalates(f) for f in findings):
        return "INCOMPLETE"
    return "APPROVE"


# --- the completion trailer (R1) ---------------------------------------------------------------
#
# WHAT PROBLEM THIS SOLVES, AND WHY THE EXISTING POST-CONDITION IS NOT ENOUGH.
#
# run-review-phase.sh already asserts a completed phase's artifacts exist, are non-empty, parse,
# and are not stale (`reviewed_sha` == HEAD). That closes the keystone failure — an agent reporting
# "Verdict: REQUEST_CHANGES / Full findings: .code-review/VALIDATED.json" with every structured signal
# green (rc 0, is_error False, stop_reason end_turn, permission_denials []) and NO SUCH FILE.
#
# Three things it still cannot see, and each is a real failure mode:
#
#   1. WHETHER THE AGENT FINISHED. A run truncated mid-write leaves a file that exists, is
#      non-empty and parses. Existence cannot distinguish "done" from "stopped halfway".
#   2. WHETHER THE AGENT'S NARRATIVE MATCHES ITS ARTIFACT. This is the T2 write-path defect: the
#      report arrives and is FALSE. An agent that says "7 findings" over an artifact holding 2 has
#      satisfied every existence check while misreporting the outcome.
#   3. BLOCKED AS AN OUTCOME. An agent that legitimately cannot proceed has no way to say so that a
#      caller branches on, so silence reads as consent — which agent-sdk.md:112-118 already forbids
#      in prose ("Never record a NO VERDICT, a partial answer, or silence as a PASS").
#
# WHY THERE IS NO SHA256 IN THIS TRAILER, contrary to the plan.
#
# The plan specified `ARTIFACT: <path> SHA256: <hash>`. Four of the five gate agents CANNOT COMPUTE
# ONE. Measured from their frontmatter `tools:` lines:
#
#     review-semantic    Read, Write, Grep              no Bash at all
#     review-testing     Read, Write, Grep              no Bash at all
#     review-architect   Read, Write, Grep, Glob, Bash(git:*)     git only, no shasum
#     review-validator   Read, Write, Grep, Glob, Bash(git:*)     git only, no shasum
#     review-reporter           ... Bash(python3:*) ...         could, but writes no findings artifact
#
# So the three agents whose artifacts the gate depends on could not satisfy that grammar. Shipping
# it anyway is worse than shipping nothing: the agent tries to shell out, the permission layer
# denies it, and it parks at `stop_reason: tool_use` until the timeout kills it — which is the
# EXACT failure already paid for once at run-review-phase.sh:478-486 ($5.51 over 907s, no verdict).
# The alternative is that the model fabricates a plausible hash, which is worse still: a gate
# comparing a fabricated hash to a real one fails on honest runs and teaches people to disable it.
#
# The declared COUNTS do the same job better for the failure that actually happened. A hash proves
# "a file with this content exists"; a count cross-check proves "the agent's story matches its
# deliverable", which is defect 2 above and is what the keystone finding was. And every agent can
# produce it with the tools it already has, because it authored the findings array.
#
# The grammar (last non-blank lines of the agent's final message):
#
#     REVIEW-TRAILER v1
#     STATUS: COMPLETE
#     ARTIFACT: .code-review/VALIDATED.json
#     FINDINGS: 7
#     SEVERITIES: BLOCKER=0 MAJOR=2 MINOR=4 NIT=1
#
#   ...or, when the agent cannot do its job:
#
#     REVIEW-TRAILER v1
#     STATUS: BLOCKED
#     BLOCKED-REASON: CONTEXT.json absent — prepare-context.sh did not run
#
# Deliberately line-oriented and case-sensitive: it must be trivially greppable from a transcript
# by a shell caller, and a model reproduces a fixed line shape far more reliably than nested JSON.

TRAILER_MAGIC = "REVIEW-TRAILER v1"
TRAILER_STATUSES = ("COMPLETE", "BLOCKED")

_TRAILER_SEV_RE = re.compile(r"\b(BLOCKER|MAJOR|MINOR|NIT|INFO)\s*=\s*(\d+)\b")


def parse_trailer(text):
    """Extract the LAST REVIEW-TRAILER block from `text`.

    Returns a dict with keys: status, artifact, findings, severities, blocked_reason, errors.
    `errors` is a list; a non-empty list means the trailer is unusable. A None return means no
    trailer was found at all, which the caller must treat as a failed phase — an agent that did not
    declare an outcome has not reported one, and reading that silence as success is the whole defect
    this trailer exists to close.

    The LAST block wins on purpose: an agent may quote the grammar while explaining itself, and the
    real declaration is the one it ends on.
    """
    if not text:
        return None
    idx = text.rfind(TRAILER_MAGIC)
    if idx < 0:
        return None

    out = {"status": None, "artifact": None, "findings": None,
           "severities": {}, "blocked_reason": None, "errors": []}

    for raw in text[idx + len(TRAILER_MAGIC):].splitlines():
        line = raw.strip().lstrip(">").strip()          # tolerate a quoted transcript
        if not line:
            continue
        key, _, value = line.partition(":")
        key, value = key.strip().upper(), value.strip()
        if key == "STATUS":
            out["status"] = value.upper()
        elif key == "ARTIFACT":
            out["artifact"] = value.strip("`'\" ")
        elif key == "FINDINGS":
            try:
                out["findings"] = int(value)
            except ValueError:
                out["errors"].append(f"FINDINGS is not an integer: {value!r}")
        elif key == "SEVERITIES":
            for sev, n in _TRAILER_SEV_RE.findall(value):
                # ACCUMULATE, never overwrite. `INFO` folds onto `NIT`, so a trailer written
                # `SEVERITIES: NIT=1 INFO=2` means three NITs — assignment silently reported two.
                canon = SEVERITY_ALIASES.get(sev, sev)
                out["severities"][canon] = out["severities"].get(canon, 0) + int(n)
        elif key == "BLOCKED-REASON":
            out["blocked_reason"] = value
        else:
            # An unknown key is not an error, and it is not a STOP either.
            #
            # This used to `break`, which made the parser order-dependent in a way nothing declared:
            # a single stray line between FINDINGS and SEVERITIES ("Note: see above") truncated
            # parsing before SEVERITIES was read, leaving severities={} — so the per-severity
            # cross-check silently verified nothing and the trailer still passed. A model that
            # interleaves one sentence is not a defect worth failing on, but it must not be able to
            # switch off half the check either.
            #
            # `continue` instead, and stop at a STRUCTURAL boundary: a second trailer magic line.
            # Prose after the trailer is skipped rather than trusted, which is what the original
            # comment was reaching for.
            if TRAILER_MAGIC in line:
                break
            continue

    if out["status"] not in TRAILER_STATUSES:
        out["errors"].append(
            f"STATUS must be one of {'/'.join(TRAILER_STATUSES)}, got {out['status']!r}")
    if out["status"] == "BLOCKED" and not out["blocked_reason"]:
        out["errors"].append("STATUS: BLOCKED with no BLOCKED-REASON — an unexplained block is "
                             "indistinguishable from a crash")
    if out["status"] == "COMPLETE":
        if not out["artifact"]:
            out["errors"].append("STATUS: COMPLETE with no ARTIFACT — the whole point of the "
                                 "trailer is naming the deliverable")
        if out["findings"] is None:
            out["errors"].append("STATUS: COMPLETE with no FINDINGS count — nothing to cross-check "
                                 "the artifact against")
    return out


def verify_trailer(text, artifact_findings=None, expected_artifact=None, artifact_root=None):
    """Cross-check a declared trailer against the artifact that was actually written.

    `artifact_findings` is the findings list parsed from the artifact on disk, or None when the
    caller could not read it. `expected_artifact` is the path the PHASE owes, so a write that landed
    somewhere else is caught. `artifact_root` is the directory `expected_artifact` is relative to;
    supply it whenever it is known, because without it the path check degrades to basename equality.

    Returns (ok: bool, problems: list[str]).
    """
    problems = []
    t = parse_trailer(text)
    if t is None:
        return False, [
            ("no REVIEW-TRAILER found in the agent's output. It did not declare an outcome, so "
             "there is nothing to believe: a run that ends without a trailer is truncated, hung, "
             "or ignored its contract. Absent is not APPROVE.")]
    problems.extend(t["errors"])

    if t["status"] == "BLOCKED":
        # A block is a FAILED phase with a named cause, never a pass. Reported as a problem on
        # purpose so the caller cannot accidentally treat it as a completed review.
        problems.append(f"agent reported STATUS: BLOCKED — {t['blocked_reason']}")
        return False, problems

    # The trailer must agree with ITSELF, checked before anything on disk is consulted. This is
    # deliberately outside the artifact block below: a trailer whose SEVERITIES sum to 5 over
    # `FINDINGS: 7` is already wrong, and gating that on whether the artifact happened to be
    # readable would mean the most basic inconsistency went unreported precisely when the caller had
    # least other information.
    if t["status"] == "COMPLETE" and t["severities"] and t["findings"] is not None:
        declared_sum = sum(t["severities"].values())
        if declared_sum != t["findings"]:
            problems.append(
                f"trailer's SEVERITIES sum to {declared_sum} but FINDINGS says {t['findings']} — "
                f"the trailer disagrees with itself")

    if expected_artifact and t["artifact"]:
        # Compared as RESOLVED ABSOLUTE paths against `artifact_root`, not by suffix.
        #
        # The suffix form was `got.endswith(want) or want.endswith(got)`, and it let through exactly
        # the shape it was written to catch: with want='.code-review/VALIDATED.json', the value
        # '/tmp/somewhere-else/.code-review/VALIDATED.json' satisfies got.endswith(want). The second
        # arm was looser still — 'ARTIFACT: json' satisfies want.endswith(got) — so a one-word
        # trailer passed a check whose entire purpose is detecting a misdirected write.
        #
        # `artifact_root` is where the caller expects the artifact to live. When it is not supplied
        # the comparison degrades to basename equality, which is weak but honest: without a root
        # there is no absolute answer, and claiming one would be the original bug in a new form.
        # `lstrip("./")` would be wrong here and was: it strips every leading character in the SET
        # {'.', '/'}, so ".code-review/VALIDATED.json" becomes "code-review/VALIDATED.json" and the
        # comparison is against a directory that does not exist. Strip the exact "./" prefix only.
        want_rel = expected_artifact.removeprefix("./")
        got_raw = t["artifact"]
        if artifact_root:
            want_abs = os.path.realpath(os.path.join(artifact_root, want_rel))
            got_abs = os.path.realpath(
                got_raw if os.path.isabs(got_raw) else os.path.join(artifact_root, got_raw))
            mismatch = want_abs != got_abs
            detail = f"resolved to {got_abs!r}, expected {want_abs!r}"
        else:
            mismatch = os.path.basename(got_raw) != os.path.basename(want_rel)
            detail = (f"no artifact_root supplied, so only the basename could be compared "
                      f"({os.path.basename(got_raw)!r} vs {os.path.basename(want_rel)!r})")
        if mismatch:
            problems.append(
                f"trailer names artifact {got_raw!r} but this phase owes {expected_artifact!r} "
                f"({detail}). A different path usually means the agent wrote to the wrong working "
                f"directory, which an existence check on the RIGHT path reports as a missing "
                f"artifact rather than as a misdirected one.")

    if artifact_findings is not None and t["findings"] is not None:
        actual = len(artifact_findings)
        if actual != t["findings"]:
            problems.append(
                f"trailer declares {t['findings']} finding(s) but the artifact holds {actual}. "
                f"The agent's report disagrees with its own deliverable — this is the write-path "
                f"defect, and the report is the half that is wrong.")

        if t["severities"]:
            actual_sev = {}
            for f in artifact_findings:
                canon = canon_severity(f.get("severity"))
                if canon:
                    actual_sev[canon] = actual_sev.get(canon, 0) + 1

            # Iterate the UNION, not just what the trailer declared.
            #
            # This loop used to run over `t["severities"]` alone, which made an OMISSION invisible:
            # an agent could declare `FINDINGS: 7` matching the artifact's true total — the one check
            # that was enforced — while writing `SEVERITIES: MAJOR=2 MINOR=3` and simply leaving out
            # a `NIT=2` category the artifact holds. Every declared key matched, so nothing fired,
            # and the breakdown a caller reads off the trailer was silently wrong.
            for sev in sorted(set(t["severities"]) | set(actual_sev)):
                declared = t["severities"].get(sev, 0)
                actual = actual_sev.get(sev, 0)
                if declared == actual:
                    continue
                if sev not in t["severities"]:
                    problems.append(
                        f"trailer OMITS {sev} entirely, but the artifact holds {actual} — an "
                        f"omitted category is not the same as zero")
                else:
                    problems.append(
                        f"trailer declares {declared} {sev} finding(s), artifact holds {actual}")


    return not problems, problems


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
# this module, so it cannot become a second opinion about the same contract; `scripts/check-contract-
# schema.sh` asserts the committed copy still matches what this function produces.
#
# THE DIVISION OF LABOUR IS DELIBERATE, and it is what keeps this from being a duplicate predicate:
#
#   contract_defects()      owns a FINDING's keys. Still the only per-finding predicate, still the
#                           one `check-predicate-parity.py` polices. Not reimplemented here.
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
#: bucket, which is what happened when `info` became `nit` in code-review 3.0.0 and the contract had to
#: be edited in three places.
METRICS_COUNT_KEYS = ("total",) + tuple(s.lower() for s in SEVERITY_RANK) + ("ux_impact_count",)
METRICS_NULLABLE_KEYS = ("coverage_pct",)

#: Envelope keys every agent contract carries.
DOCUMENT_REQUIRED = ("agent", "category", "findings")

#: Envelope keys only the validator's VALIDATED.json carries. Optional everywhere, and listed so the
#: schema can permit them without opening the document to arbitrary extra keys.
VALIDATED_ONLY_KEYS = ("rejected_count", "blocking_reason_ids")

#: Envelope keys the ROLLUP artifact must carry, where a specialist's own contract need not.
#:
#: This distinction is the reason `document_defects` takes a flag instead of validating one shape for
#: everything. The submission gate reads `verdict` and `metrics` out of the rollup to decide whether
#: the review was clean; a rollup missing `verdict` yields `None` from `.get()`, and `None` is not
#: `"REQUEST_CHANGES"`, so it is indistinguishable from APPROVE at the one place that decides whether
#: a change may merge. A SPECIALIST missing `verdict` is harmless by contrast — the contract says so
#: as many words ("nothing reads a specialist's `verdict` or `metrics`"), and requiring it there would
#: fail four honest agents to protect a field nobody reads.
ROLLUP_REQUIRED = ("verdict", "metrics")

#: Artifacts a phase owes that are NOT agent contracts, and so must not be validated as one.
#:
#: DECLARED rather than inferred, and the default is deliberately the other way round: an artifact not
#: named here IS validated. So adding a new contract artifact needs no edit and cannot slip through
#: unvalidated, while excusing one requires writing down why. That is the fail-closed direction.
#:
#: `CONTEXT.json` is the case, and it is the whole reason this set exists. It is the pre-built bounded
#: context written by `prepare-context.sh` — an INPUT to the review, not an agent's report — so it has
#: no `agent`, no `category` and no `findings`, and validating it against the contract produced three
#: defects on a perfectly correct file. Found by the bench suite reporting spurious warnings on a good
#: run, which is exactly what that assertion is for.
#:
#: Note what is NOT here: `SCAN.json`. It is written by `review-scan.sh` rather than by an agent, but
#: it genuinely IS a contract document — it carries `agent`, `category` and `findings`, and
#: `review-scan.sh` already runs `contract_defects` over its findings. Being machine-generated is not
#: the criterion; carrying findings someone downstream will act on is.
NON_CONTRACT_ARTIFACTS = frozenset({"CONTEXT.json"})


def is_contract_artifact(path) -> bool:
    """True when `path` names an artifact that must satisfy the agent-contract schema."""
    if not path:
        return False
    base = os.path.basename(str(path))
    return base.endswith(".json") and base not in NON_CONTRACT_ARTIFACTS


#: The rollup artifact's filename. Spelled here ONCE so a caller can ask "am I holding the rollup?"
#: without every caller carrying its own literal — which is how `code-review` ended up hardcoded in ten
#: places. The phase→artifact map in run-review-phase.sh remains the authority on which phase OWES
#: it; this constant only answers what it is called.
ROLLUP_ARTIFACT_BASENAME = "VALIDATED.json"


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
            "scripts/check-contract-schema.sh --write."
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
            **{k: ({"type": "integer", "minimum": 0} if k == "rejected_count"
                   else {"type": "array", "items": {"type": "string"}})
               for k in VALIDATED_ONLY_KEYS},
        },
        # TRUE, deliberately. An agent adding a field is not a defect worth failing a review over,
        # and `additionalProperties: false` would make every future field a breaking change to a
        # contract four agents and two orchestrators already implement. The keys that MATTER are
        # covered by `required` and by the enums; an unknown key is inert.
        "additionalProperties": True,
    }


def is_rollup_artifact(path) -> bool:
    """True when `path` names the rollup artifact, however it is spelled or prefixed.

    Compares the BASENAME, so `.code-review/VALIDATED.json`, a bare `VALIDATED.json` and an absolute
    path all answer the same. Case-insensitive because the caller's value comes from a trailer line an
    agent typed.
    """
    if not path:
        return False
    return os.path.basename(str(path)).lower() == ROLLUP_ARTIFACT_BASENAME.lower()


def document_defects(doc, require_rollup=False):
    """Return a list of human-readable envelope defects in `doc`, or [] when it conforms.

    Validated with `jsonschema` against `contract_schema()`. A missing library is a HARD FAILURE,
    raised rather than returned, for the same reason `catalog.parse_frontmatter` refuses to fall back
    to grepping: a validator that degrades to a weaker check on an import error reports a clean
    document it never actually validated, and the degradation is invisible at the call site.

    `require_rollup` additionally demands ROLLUP_REQUIRED. It is a parameter and not a property of the
    schema because the requirement is per-ARTIFACT, not per-document-shape, and JSON Schema can only
    express that by branching on a category literal the generator would then have to hardcode. The
    caller knows which artifact it is holding; `is_rollup_artifact` turns a path into this flag.

    Per-FINDING defects are reported here only at the shape level the schema covers. Callers that
    need the authoritative per-finding verdict must still use `contract_defects` — this function does
    not replace it and does not restate it.
    """
    try:
        import jsonschema                                   # noqa: PLC0415
    except ImportError as exc:                              # pragma: no cover
        raise RuntimeError(
            "jsonschema is required to validate an agent contract document (pip install "
            "jsonschema). This is raised rather than skipped: a boundary that silently stops "
            "validating is how an unvalidated artifact reads as a clean one."
        ) from exc

    validator = jsonschema.Draft202012Validator(contract_schema())
    out = []
    for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path)):
        where = "/".join(str(p) for p in err.absolute_path) or "(document root)"
        out.append(f"{where}: {err.message}")

    if require_rollup and isinstance(doc, dict):
        for key in ROLLUP_REQUIRED:
            if key not in doc:
                out.append(
                    f"(document root): the rollup artifact is missing {key!r}. The submission gate "
                    f"reads it to decide whether the review was clean, and an absent key yields None "
                    f"— which is not 'REQUEST_CHANGES', so it reads as APPROVE at the one place that "
                    f"gates a merge.")
    return out
