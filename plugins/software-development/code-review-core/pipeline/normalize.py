#!/usr/bin/env python3
"""normalize.py — fold raw static-analysis output into one AgentContract.

Reads `<raw>/‹tool›.json` files written by `detectors/*.sh` and emits a single `AgentContract`
(the `agent-contracts` skill) with `agent: "review-scan"` and
`category: "SCAN"`. The output is the zero-token detection half of the CI-first review: Claude
triages this instead of hand-grepping for the same patterns.

Every shape below was verified against the installed binaries, not inferred from docs:

    ruff        list[{code, filename(abs), location:{row,column}, message, severity, url, fix}]
    bandit      {results: [{filename, line_number, test_id, issue_severity, issue_confidence,
                            issue_text, more_info, code}]}
    mypy        JSONL — one {file, line, column, message, hint, code, severity} per line
    pylint      {messages: [{type, symbol, message, messageId, confidence, line, path, ...}]}
    shellcheck  {comments: [{file, line, endLine, column, level, code, message}]}
    gitleaks    list[{RuleID, Description, StartLine, EndLine, File, Secret, Match}]
    checkov     {results: {failed_checks: [{check_id, check_name, file_abs_path,
                           file_line_range:[a,b], severity, guideline, resource}]}}  (or a list)
    tflint      {issues: [{rule:{name, severity, link}, message, range:{filename, start:{line}}}]}
    tfsec       {results: [{rule_id, description, severity, links, resource,
                            location:{filename(abs), start_line, end_line}}]}
    trivy       {Results: [{Target, Class, Secrets:[{RuleID, Severity, Title, StartLine}]}]}
    impact      our own — {findings: [{path, line, symbol, consumers:[...]}]}
    deps        our own — {findings: [{path, line, rule, severity, category, title,
                                       recommendation}]}  (severity decided by the detector)
    comments    our own — same shape as deps
    coverage    coverage.py --format=json — {totals:{percent_covered}, files:{...}}
    pytest      our own summary — {failed: [{nodeid, file, line, message}], rc: int}

Three decisions worth knowing about:

1.  **Secrets never carry their own evidence.** For every other tool `evidence` is the cited source
    line read off disk. For a secret finding the cited line *is* the secret, so reading it would
    copy a live credential into `SCAN.json` — a file Claude reads and may quote into a review note.
    Secret findings get a fixed redaction notice instead. The detectors also pass `--redact` where
    the tool supports it, so `raw/` is clean too. This is deliberate and load-bearing; do not
    "improve" it by adding the line.

2.  **Range findings are emitted as enumerated lines, capped.** checkov and tfsec report a resource
    *block* (`file_line_range: [4, 11]`). The downstream diff filter
    (`pipeline/filter-carried-findings.py`) used to extract every integer from the location and
    keep a finding if ANY cited line was in a hunk — it did not expand `4-11`, it saw only
    {4, 11}. A diff that changed line 8 would therefore drop a finding that is genuinely in the
    diff. So spans of <= RANGE_ENUM_CAP lines are written `path:4,5,6,...,11`. The filter has
    since learned to test `start-end` as an interval, so longer spans written that way are matched
    correctly too; the short-span enumeration is kept only so existing output does not change shape.

3.  **pylint `convention` and `refactor` are dropped.** They are ~90% of pylint's default output
    ("Missing module docstring" on line 1 of every new file), they survive diff-scoping because new
    files are entirely in the diff, and ruff already covers the style ground. Only
    `fatal`/`error`/`warning` are kept. Recorded in scan_meta so the omission is visible.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# IMPORTED, not restated. contract.py is the only definition of what makes a finding usable and
# what makes it block. No prose copy of the predicate is maintained: the
# `dev-standards:agent-contracts` skill gives a one-line summary and points to contract.py, and
# `agents/review-validator.md` only records judgements.
#
# SELF-LOCATING, and it has to be. `python3 normalize.py` puts this directory on sys.path, but two
# other loaders do not: review-scan.test.sh loads this file through
# `importlib.util.spec_from_file_location`, and review-scan.sh's heredoc runs `python3 -` with the
# REVIEWED repo as cwd. A bare `from contract import ...` resolves under the first and raises
# ModuleNotFoundError under the other two, which is a mid-scan crash rather than a test failure.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# pylint: disable=unused-import  # every name here is a deliberate RE-EXPORT: review-scan.sh's
# heredoc and the test suites import them from this module rather than reaching past it.
from contract import (  # noqa: F401 — re-exported for this module's consumers
    # The four key-recovery tables. Underscore-private in contract.py and re-exported here for the
    # same reason as everything else in this list — the test suites import from this module rather
    # than reaching past it. They are re-exported specifically so the suites can ITERATE them
    # instead of naming one member each: the recovery loops are first-match-then-break, so a suite
    # that hardcodes `summary` and `file`+`line` cannot see a bug that only breaks the members after
    # the first, and cannot notice a member ADDED to a tuple later going untested. Iterating the real
    # table is what makes that coverage self-maintaining.
    _BOOLS,
    _LINE_ALIASES,
    _PATH_ALIASES,
    # NOT one of the four tables above — a NUMERIC constant, and it sits here only because isort
    # orders `_`-prefixed names together. See TITLE_MAX below for why both numbers are re-exported;
    # the two belong to one purpose and are separated purely by the sort.
    _SCALAR_UNWRAP_LIMIT,
    _TITLE_ALIASES,
    ACTIONABLE_REQUIRED,
    BLOCKER,
    CONTRACT_REQUIRED,
    DEFAULT_BLOCKING_FLOOR,
    MAJOR,
    MINOR,
    NIT,
    SEVERITY_ALIASES,
    SEVERITY_RANK,
    # The second of the two NUMERIC constants the repair pass reads (`_SCALAR_UNWRAP_LIMIT` is the
    # other, sorted up among the `_` names above). Re-exported so a test can DERIVE its shape cases
    # from them instead of spelling 300 and 4 in a second place, and so mk() below caps titles with
    # the same number the repair pass uses.
    TITLE_MAX,
    # The shape guard both alias loops run every candidate through, re-exported for the same reason as
    # the tables above: a suite that can only reach it through `normalize_finding` can assert the
    # OUTCOME but not the rule.
    _first_scalar,
    _scalar,
    blocking_floor_rank,
    canon_severity,
    contract_defects,
    contract_gaps,
    finding_blocks,
    finding_escalates,
    floor_diagnostics,
    normalize_finding,
    rollup_verdict,
    sort_rank,
)
# The one definition of "is this a test file", shared with prepare-context.sh. Same self-locating
# sys.path entry as the contract import above.
from testpaths import is_test_path  # noqa: E402

# The vocabulary, the rank table, the floor and the blocking predicate all live in contract.py and
# are re-exported above. They were defined HERE until the objective review pointed out that a module
# named "contract" held only the CONTENT half of the contract while the blocking half — the half
# with the most duplicates — stayed outside it. `SEV_ORDER`, a second byte-identical rank table read
# by bare subscript for dedup and sorting, went with them: two tables meant ordering could drift
# from blocking with nothing to catch it, and the subscript form both bypassed the parity gate and
# raised on an unrankable value. Use `sort_rank()` for ordering and `canon_severity()` to look up.

# Spans longer than this fall back to `start-end`; see decision 2 in the module docstring. 30 keeps a
# location string short enough to read at a glance (about 120 characters of line numbers).
RANGE_ENUM_CAP = 30
# Per-field caps for scanner findings. One source line of evidence is all a triager needs to
# recognise the finding, and 200 characters is a long code line; the recommendation cap leaves room
# for a sentence of why plus a doc URL. TITLE_MAX comes from contract.py so the scanner and the
# repair pass agree on the title cap.
EVIDENCE_MAX = 200
RECOMMENDATION_MAX = 600

SECRET_EVIDENCE = (
    "[redacted] a secret-scanning rule matched on this line. The value is deliberately not "
    "reproduced here — open the file locally to confirm, then rotate the credential before "
    "removing it from history."
)


def load_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def load_jsonl(path):
    """mypy --output=json emits one object per line, which json.load cannot read."""
    out = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return out


class Ctx:
    """Path relativisation plus a memoised source-line reader for `evidence`."""

    def __init__(self, repo_root):
        self.root = os.path.abspath(repo_root)
        self._files = {}

    def rel(self, path):
        """Repo-relative, forward-slashed. Tools disagree: ruff/tfsec give absolute paths,
        bandit gives `./x.py`, checkov gives `/x.tf` (relative to ITS scan root, not the fs root).
        A wrong path here silently breaks diff-scoping, so normalise all of them."""
        if not path:
            return ""
        p = str(path).replace("\\", "/")
        ap = os.path.abspath(os.path.join(self.root, p.lstrip("/"))) if not os.path.isabs(p) \
            else os.path.abspath(p)
        try:
            rel = os.path.relpath(ap, self.root)
        except ValueError:
            return p.lstrip("./")
        # A path outside the repo (a tool scanning a temp copy) is not diff-scopable; keep it as
        # given so the finding is still readable rather than mangling it into ../../ soup.
        return p.lstrip("./") if rel.startswith("..") else rel

    def line(self, rel_path, lineno):
        """The source line at `lineno`, or "" if unreadable. Never called for secret findings."""
        if not rel_path or not lineno or lineno < 1:
            return ""
        if rel_path not in self._files:
            try:
                with open(os.path.join(self.root, rel_path), errors="replace") as fh:
                    self._files[rel_path] = fh.read().splitlines()
            except OSError:
                self._files[rel_path] = []
        lines = self._files[rel_path]
        if lineno > len(lines):
            return ""
        return lines[lineno - 1].strip()[:EVIDENCE_MAX]


def location(path, start, end=None):
    """Build a `location` the diff filter can line-check. See decision 2."""
    if not start:
        return path
    start = int(start)
    if not end or int(end) <= start:
        return f"{path}:{start}"
    end = int(end)
    if end - start + 1 <= RANGE_ENUM_CAP:
        return f"{path}:" + ",".join(str(n) for n in range(start, end + 1))
    return f"{path}:{start}-{end}"


def mk(ctx, *, tool, sev, category, path, start, title, recommendation,
       end=None, confidence="HIGH", secret=False, rule=""):
    rel = ctx.rel(path)
    return {
        "_tool": tool,
        "_rule": rule,
        "_path": rel,
        "_line": int(start) if start else 0,
        "severity": sev,
        "category": category,
        "location": location(rel, start, end),
        "title": title[:TITLE_MAX],
        "evidence": SECRET_EVIDENCE if secret else (ctx.line(rel, start) or "(source line unavailable)"),
        "recommendation": recommendation[:RECOMMENDATION_MAX] if recommendation else "",
        "ux_impact": False,
        # true = "this diff introduced/worsened it". Detectors only ever run on changed files, and
        # the diff filter then drops anything not on a changed LINE, so true is the honest default:
        # it opts the finding into hunk-checking rather than exempting it (in_diff false = KEEP).
        "in_diff": True,
        "confidence": confidence,
    }


# --- per-tool parsers -----------------------------------------------------------------------------

def p_ruff(raw, ctx):
    out = []
    for r in raw if isinstance(raw, list) else []:
        code = str(r.get("code") or "")
        # E (pycodestyle errors) and F (pyflakes: undefined names, unused imports) are real
        # defects; everything else in ruff's default set is style.
        sev = MAJOR if code[:1] in ("E", "F") else MINOR
        out.append(mk(
            ctx, tool="ruff", rule=code, sev=sev, category="RELIABILITY",
            path=r.get("filename"), start=(r.get("location") or {}).get("row"),
            title=f"{code}: {r.get('message', '')}",
            recommendation=r.get("url") or "See the ruff rule documentation.",
        ))
    return out


def p_bandit(raw, ctx):
    smap = {"HIGH": BLOCKER, "MEDIUM": MAJOR, "LOW": MINOR}
    out = []
    for r in (raw or {}).get("results", []) if isinstance(raw, dict) else []:
        sev = smap.get(str(r.get("issue_severity", "")).upper(), MINOR)
        out.append(mk(
            ctx, tool="bandit", rule=str(r.get("test_id") or ""), sev=sev, category="SECURITY",
            path=r.get("filename"), start=r.get("line_number"),
            title=f"{r.get('test_id')}: {r.get('issue_text', '')}",
            recommendation=r.get("more_info") or "",
            # bandit is the one tool that reports its own confidence — pass it through rather
            # than asserting HIGH for a LOW-confidence heuristic hit.
            confidence=str(r.get("issue_confidence", "HIGH")).upper()
            if str(r.get("issue_confidence", "")).upper() in ("HIGH", "MEDIUM", "LOW") else "HIGH",
        ))
    return out


def p_mypy(records, ctx):
    out = []
    for r in records:
        sev = MAJOR if str(r.get("severity", "error")).lower() == "error" else NIT
        code = r.get("code") or "type"
        out.append(mk(
            ctx, tool="mypy", rule=str(code), sev=sev, category="RELIABILITY",
            path=r.get("file"), start=r.get("line"),
            title=f"{code}: {r.get('message', '')}",
            recommendation=r.get("hint") or "Fix the type mismatch or narrow the annotation.",
        ))
    return out


def p_pylint(raw, ctx):
    keep = {"fatal": MAJOR, "error": MAJOR, "warning": MINOR}
    out = []
    for r in (raw or {}).get("messages", []) if isinstance(raw, dict) else []:
        sev = keep.get(str(r.get("type", "")).lower())
        if sev is None:      # convention / refactor — see decision 3
            continue
        conf = str(r.get("confidence", "HIGH")).upper()
        out.append(mk(
            ctx, tool="pylint", rule=str(r.get("messageId") or ""), sev=sev,
            category="RELIABILITY", path=r.get("path"), start=r.get("line"),
            title=f"{r.get('messageId')} {r.get('symbol')}: {r.get('message', '')}",
            recommendation="", confidence=conf if conf in ("HIGH", "MEDIUM", "LOW") else "HIGH",
        ))
    return out


def p_shellcheck(raw, ctx):
    smap = {"error": MAJOR, "warning": MINOR, "info": NIT, "style": NIT}
    out = []
    for c in (raw or {}).get("comments", []) if isinstance(raw, dict) else []:
        code = f"SC{c.get('code')}"
        out.append(mk(
            ctx, tool="shellcheck", rule=code,
            sev=smap.get(str(c.get("level", "")).lower(), NIT), category="RELIABILITY",
            path=c.get("file"), start=c.get("line"), end=c.get("endLine"),
            title=f"{code}: {c.get('message', '')}",
            recommendation=f"https://www.shellcheck.net/wiki/{code}",
        ))
    return out


def p_gitleaks(raw, ctx):
    out = []
    for r in raw if isinstance(raw, list) else []:
        out.append(mk(
            ctx, tool="gitleaks", rule=str(r.get("RuleID") or ""), sev=BLOCKER,
            category="SECURITY", path=r.get("File"), start=r.get("StartLine"),
            title=f"Secret detected ({r.get('RuleID')})",
            recommendation="Remove the credential, rotate it, and move it to a secret store "
                           "(op:// reference, AWS Secrets Manager, or SSM). Rotation is required "
                           "even after removal — the value is in git history.",
            secret=True,
        ))
    return out


def p_trivy(raw, ctx):
    smap = {"CRITICAL": BLOCKER, "HIGH": BLOCKER, "MEDIUM": MAJOR, "LOW": MAJOR}
    out = []
    for res in (raw or {}).get("Results", []) if isinstance(raw, dict) else []:
        for s in res.get("Secrets") or []:
            out.append(mk(
                ctx, tool="trivy", rule=str(s.get("RuleID") or ""),
                sev=smap.get(str(s.get("Severity", "")).upper(), MAJOR), category="SECURITY",
                path=res.get("Target"), start=s.get("StartLine"), end=s.get("EndLine"),
                title=f"Secret detected ({s.get('RuleID')}): {s.get('Title', '')}",
                recommendation="Remove the credential, rotate it, and move it to a secret store. "
                               "Rotation is required even after removal.",
                secret=True,
            ))
    return out


def p_checkov(raw, ctx):
    # `severity` is null unless a Bridgecrew/Prisma API key is configured, which we do not use.
    # Everything therefore lands on the MINOR fallback; scan_meta records that so a reader does
    # not mistake "all MINOR" for "nothing serious".
    smap = {"CRITICAL": MAJOR, "HIGH": MAJOR, "MEDIUM": MINOR, "LOW": NIT}
    blocks = raw if isinstance(raw, list) else [raw]
    out = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        for c in ((block.get("results") or {}).get("failed_checks") or []):
            rng = c.get("file_line_range") or []
            start = rng[0] if rng else None
            end = rng[1] if len(rng) > 1 else None
            sev_raw = str(c.get("severity") or "").upper()
            out.append(mk(
                ctx, tool="checkov", rule=str(c.get("check_id") or ""),
                sev=smap.get(sev_raw, MINOR), category="SECURITY",
                path=c.get("file_abs_path") or c.get("file_path"), start=start, end=end,
                title=f"{c.get('check_id')}: {c.get('check_name', '')}"
                      + (f" [{c.get('resource')}]" if c.get("resource") else ""),
                recommendation=c.get("guideline") or "",
            ))
    return out


def p_tflint(raw, ctx):
    smap = {"error": MAJOR, "warning": MINOR, "notice": NIT, "info": NIT}
    out = []
    for i in (raw or {}).get("issues", []) if isinstance(raw, dict) else []:
        rule = i.get("rule") or {}
        rng = i.get("range") or {}
        out.append(mk(
            ctx, tool="tflint", rule=str(rule.get("name") or ""),
            sev=smap.get(str(rule.get("severity", "")).lower(), MINOR), category="RELIABILITY",
            path=rng.get("filename"), start=(rng.get("start") or {}).get("line"),
            end=(rng.get("end") or {}).get("line"),
            title=f"{rule.get('name')}: {i.get('message', '')}",
            recommendation=rule.get("link") or "",
        ))
    return out


def p_tfsec(raw, ctx):
    smap = {"CRITICAL": MAJOR, "HIGH": MAJOR, "MEDIUM": MINOR, "LOW": NIT}
    out = []
    for r in (raw or {}).get("results", []) if isinstance(raw, dict) else []:
        loc = r.get("location") or {}
        links = r.get("links") or []
        out.append(mk(
            ctx, tool="tfsec", rule=str(r.get("long_id") or r.get("rule_id") or ""),
            sev=smap.get(str(r.get("severity", "")).upper(), MINOR), category="SECURITY",
            path=loc.get("filename"), start=loc.get("start_line"), end=loc.get("end_line"),
            title=f"{r.get('rule_id')}: {r.get('description', '')}"
                  + (f" [{r.get('resource')}]" if r.get("resource") else ""),
            recommendation=(r.get("resolution") or "") + ((" " + links[0]) if links else ""),
        ))
    return out


def p_impact(raw, ctx):
    out = []
    for f in (raw or {}).get("findings", []) if isinstance(raw, dict) else []:
        consumers = f.get("consumers") or []
        # `consumers` is already truncated by impact.sh, so the honest total comes from
        # consumer_count. Falling back to len(consumers) would silently report "20 consumers" for a
        # symbol used in 200 files — understating the blast radius, which is the whole point here.
        total = f.get("consumer_count")
        total = len(consumers) if not isinstance(total, int) else total
        shown = ", ".join(consumers[:8])
        more = f" (+{total - 8} more)" if total > 8 else ""
        # A count-only finding (impact.sh, over its GENERIC_CONSUMER_LIMIT) carries the size of the
        # blast radius and no list, because above that limit the list is mostly word-grep noise. Say
        # that plainly. Rendering the normal template would emit "Check these call sites still hold:
        # (+42 more)", which reads as a truncation bug rather than as a deliberate count.
        if f.get("count_only") or not consumers:
            rec = (f"{total} reference(s) outside the diff, too many for a word-grep to shortlist, so "
                   "no call-site list was captured. Resolve with an import graph or an editor "
                   "reference search before assuming the consumers still hold.")
        else:
            rec = f"Check these call sites still hold: {shown}{more}"
        # "removed" and "changed" are different bugs — a deleted definition breaks its consumers
        # outright, a changed signature only might — so the title says which, and the reviewer does
        # not have to open the diff to find out.
        what = ("was removed or renamed" if f.get("kind") == "removed"
                else "changed" if f.get("kind") else "changed")
        # NIT at MEDIUM is deliberate, and the PAIR is what makes this finding non-blocking on its
        # own: a name-grep knows the definition changed and knows nothing about whether any consumer
        # breaks. Neither value may be raised here, because nothing at this tier has read a consumer.
        # Both are raised by the semantic pass through `scan_triage`, which does read one. A severity
        # raise alone still cannot block: `finding_blocks` above requires `confidence == "HIGH"`, so
        # an impact lead promoted to MAJOR without a matching confidence raise reports and escalates
        # rather than blocking. That is the whole reason `scan_triage` carries a `confidence`.
        #
        # `recommendation` is the field that carries "where the symbol is used". The contract has no
        # dedicated one (`agent-contracts` gives a finding only `evidence` and `recommendation`), and
        # `location` is the in-diff definition line on purpose, never a consumer's line, so the
        # finding survives the hunk filter and anchors where the fix goes.
        out.append(mk(
            ctx, tool="impact", rule="changed-symbol", sev=NIT, category="IMPACT",
            path=f.get("path"), start=f.get("line"),
            title=f"`{f.get('symbol')}` {what} and has {total} consumer(s) outside the diff",
            recommendation=rec,
            confidence="MEDIUM",
        ))
    return out


def p_own(tool, raw, ctx, default_sev, default_category):
    """Parser for the detectors that carry their own severity — `deps`, `comments`, `iac-policy`.

    Each decides the tier at the point it decides the RULE, because the two are the same judgement:
    `actions-unpinned-uses` is MAJOR and `npm-range-loose` beside a lockfile is a NIT, and nothing
    outside the detector knows which rule fired. Re-deriving that here from a tool-wide map, the way
    p_ruff and p_tfsec must, would flatten the ladder those detectors were written to keep — and a
    detector whose findings all arrive at one tier is one a reader learns to skip.

    Whatever arrives is canonicalised rather than trusted: an unrankable severity would fall out of
    every bucket in the metrics while staying in `findings`, which is the fail-open `canon_severity`
    exists to close.
    """
    out = []
    for f in (raw or {}).get("findings", []) if isinstance(raw, dict) else []:
        out.append(mk(
            ctx, tool=tool, rule=str(f.get("rule") or ""),
            sev=canon_severity(f.get("severity")) or default_sev,
            category=str(f.get("category") or default_category),
            path=f.get("path"), start=f.get("line"),
            title=str(f.get("title") or ""),
            recommendation=str(f.get("recommendation") or ""),
        ))
    return out


def p_deps(raw, ctx):
    return p_own("deps", raw, ctx, MINOR, "RELIABILITY")


def p_comments(raw, ctx):
    # NIT is both the default and the only tier `comments.sh` emits. It is kept as a fallback rather
    # than hardcoded so a future rule there can arrive at a different tier without a change here.
    return p_own("comments", raw, ctx, NIT, "ARCHITECTURE")


def p_iac_policy(raw, ctx):
    # Tiers come from the detector, rule by rule (a PassRole on "*" is MAJOR, an undocumented
    # variable a NIT); MINOR is only the fallback for a finding that arrives without one.
    return p_own("iac-policy", raw, ctx, MINOR, "RELIABILITY")


def p_pytest(raw, ctx):
    out = []
    for f in (raw or {}).get("failed", []) if isinstance(raw, dict) else []:
        out.append(mk(
            ctx, tool="pytest", rule="test-failure", sev=BLOCKER, category="TESTING",
            path=f.get("file"), start=f.get("line"),
            title=f"Test fails: {f.get('nodeid', '')}",
            recommendation=str(f.get("message") or "")[:400],
        ))
    return out


def p_coverage(raw, ctx, fail_under):
    """One finding when total coverage is under the project's gate. Not line-scoped by design —
    coverage is a whole-run property, so it is emitted with in_diff false so the diff filter
    keeps it (a coverage regression is real even though it has no single guilty line)."""
    if not isinstance(raw, dict):
        return [], None
    pct = ((raw.get("totals") or {}).get("percent_covered"))
    if pct is None:
        return [], None
    pct = round(float(pct), 2)
    if fail_under is None or pct >= fail_under:
        return [], pct
    f = mk(ctx, tool="coverage", rule="fail-under", sev=MAJOR, category="TESTING",
           path="", start=None,
           title=f"Coverage {pct}% is below the project gate of {fail_under}%",
           recommendation="Add tests for the new branches this diff introduced.")
    f["location"] = "(whole run)"
    f["evidence"] = f"total coverage {pct}% < fail_under {fail_under}%"
    f["in_diff"] = False
    return [f], pct


# --- assembly -------------------------------------------------------------------------------------

def _is_test_path(path):
    """The ONE test-path predicate, from testpaths.py. This used to be a third, local heuristic that
    disagreed with testpaths.py (it missed `spec/`, `e2e/` and `*.test.<ext>`), so B101 in those
    files was reported as a real finding while prepare-context.sh called the same file a test."""
    return is_test_path(path or "")


# Two classes of finding are noise BY CONSTRUCTION, and both flooded the first real scans: a 16-file
# Python change produced 85 diff-scoped findings of which 71 were `bandit B101` (asserts inside test
# files) and 9 were `pylint E0401` (import-error in a checkout with no dependencies installed).
# Handing that to a triage step means paying a model to reject 94% junk — precisely the cost this
# scanner exists to remove.
#
# Entries are (tool, rule ids, path predicate or None, reason). Every suppression is COUNTED and
# REPORTED: a silently dropped rule is indistinguishable from a rule that found nothing, which is
# the failure mode this whole design is built to avoid.
SUPPRESSIONS = (
    ("bandit", {"B101"}, _is_test_path,
     "assert_used inside a test file — the asserts ARE the test, and bandit's own guidance is to "
     "skip B101 for test code. Still reported outside tests, where `python -O` really does strip it."),
    # The scanner installs nothing on purpose (the same reason pytest and coverage are skipped), so
    # every inference-dependent check measures the scanner's environment rather than the diff. They
    # cascade: one unresolved import makes each name it exported an unknown, and pylint then reports
    # the resulting Any as a membership / subscript / attribute error.
    ("pylint", {"E0401", "E0611", "E1101", "E1135", "E1136", "E1120"}, None,
     "pylint inference needs the project's installed dependencies, which the scanner does not "
     "install — these ids report the scanner's environment, not the change."),
    ("mypy", {"import-not-found", "import-untyped"}, None,
     "same cause: with no dependencies installed, an unresolvable import is an environment fact."),
)


def suppress(findings, extra=()):
    """Drop by-construction noise. Returns (kept, [{rule, count, reason}, ...]).

    `extra` carries suppressions that are only correct under a condition the table cannot see — at
    present, one rule superseded by a detector that may or may not have run. A conditional entry
    stays out of SUPPRESSIONS on purpose: a static table read as "always true" is how a rule gets
    dropped on a run where nothing replaced it.
    """
    counts, order, kept = {}, [], []
    for f in findings:
        hit = None
        for tool, rules, pred, reason in tuple(SUPPRESSIONS) + tuple(extra):
            if f["_tool"] == tool and f["_rule"] in rules and (pred is None or pred(f["_path"])):
                hit = (f"{tool}:{f['_rule']}", reason)
                break
        if hit is None:
            kept.append(f)
            continue
        key, reason = hit
        if key not in counts:
            counts[key] = {"rule": key, "count": 0, "reason": reason}
            order.append(key)
        counts[key]["count"] += 1
    return kept, [counts[k] for k in order]


def dedup(findings):
    """Collapse (path, first-line, rule) duplicates, keeping the most severe.

    Tools overlap on purpose — gitleaks and trivy both scan for secrets, ruff and pylint both flag
    unused imports — so the same defect can arrive twice under different rule ids. Only an exact
    rule match is collapsed here; cross-tool agreement is signal a triager should see, not noise.
    """
    best = {}
    order = []
    for f in findings:
        key = (f["_path"], f["_line"], f["_tool"], f["_rule"])
        if key not in best:
            best[key] = f
            order.append(key)
        elif sort_rank(f["severity"]) < sort_rank(best[key]["severity"]):
            best[key] = f
    return [best[k] for k in order]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True, help="directory holding raw/<tool>.json")
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--source-branch", default="HEAD")
    ap.add_argument("--target-branch", default="origin/main")
    ap.add_argument("--max-findings", type=int, default=150)
    ap.add_argument("--fail-under", type=float, default=None,
                    help="coverage gate; omit to skip the coverage finding entirely")
    args = ap.parse_args()

    raw_dir, ctx = args.raw, Ctx(args.repo_root)
    j = lambda n, d=None: load_json(os.path.join(raw_dir, n), d)  # noqa: E731 — terse on purpose

    findings, ran = [], []

    def add(name, produced):
        if produced is not None:
            ran.append(name)
            findings.extend(produced)

    def if_present(name, fn, loader=None):
        path = os.path.join(raw_dir, f"{name}.json")
        if not os.path.exists(path):
            return
        data = (loader or load_json)(path)
        add(name, fn(data, ctx) if data is not None else [])

    if_present("ruff", p_ruff)
    if_present("bandit", p_bandit)
    if_present("mypy", p_mypy, load_jsonl)
    if_present("pylint", p_pylint)
    if_present("shellcheck", p_shellcheck)
    if_present("gitleaks", p_gitleaks)
    if_present("trivy", p_trivy)
    if_present("checkov", p_checkov)
    if_present("tflint", p_tflint)
    if_present("tfsec", p_tfsec)
    if_present("impact", p_impact)
    if_present("deps", p_deps)
    if_present("comments", p_comments)
    if_present("iac-policy", p_iac_policy)
    if_present("pytest", p_pytest)

    coverage_pct = None
    if os.path.exists(os.path.join(raw_dir, "coverage.json")):
        cov_findings, coverage_pct = p_coverage(j("coverage.json"), ctx, args.fail_under)
        add("coverage", cov_findings)

    # Before dedup and before the cap: suppressed noise must not consume cap slots that a real
    # finding needs. The 16-file Python case truncated 37 findings at the 150 cap while carrying 71
    # B101s, so the cap was dropping signal to make room for noise.
    # pylint's W0511 (`fixme`) and the `comments` detector's untracked-marker rule are the same
    # finding at different precision: W0511 fires on EVERY marker, including one carrying an issue
    # reference — which is exactly the shape the standard asks for, so reporting it is telling a
    # developer off for complying. The narrower rule wins, but ONLY when it ran: a scan invoked as
    # `--detectors python` has no comments detector, and suppressing W0511 there would drop marker
    # coverage entirely with nothing in its place.
    extra_suppressions = ()
    if "comments" in ran:
        extra_suppressions = (
            ("pylint", {"W0511"}, None,
             "superseded by the `comments` detector's untracked-marker rule, which reports only "
             "markers with no issue reference; W0511 also flags correctly tracked ones."),
        )
    findings, suppressed = suppress(findings, extra_suppressions)

    findings = dedup(findings)
    findings.sort(key=lambda f: (sort_rank(f["severity"]), f["_path"], f["_line"]))

    # Truncate lowest-severity-first and SAY SO. A silently truncated scan reads as a clean one.
    truncated = 0
    if len(findings) > args.max_findings:
        truncated = len(findings) - args.max_findings
        findings = findings[: args.max_findings]

    skipped = []
    if os.path.isdir(raw_dir):
        for name in sorted(os.listdir(raw_dir)):
            if name.endswith(".skipped"):
                # errors="replace": a reason is often a byte-capped excerpt of a tool's stderr
                # (`excerpt` in detectors/_lib.sh), and a 200-byte cut can split a UTF-8
                # character. Strict decoding then raised here and failed the whole scan.
                try:
                    with open(os.path.join(raw_dir, name), encoding="utf-8",
                              errors="replace") as fh:
                        reason = fh.read().strip()
                except OSError:
                    reason = ""
                skipped.append({"tool": name[: -len(".skipped")], "reason": reason})

    # Detectors may report their own caveats in a top-level "notes" list — impact.sh uses it to say
    # which symbols it dropped as too generic to grep for. Surfacing them matters because a silent
    # drop is indistinguishable from "nothing found", which is the failure mode this whole scan is
    # supposed to avoid.
    detector_notes = []
    if os.path.isdir(raw_dir):
        for name in sorted(os.listdir(raw_dir)):
            if not name.endswith(".json"):
                continue
            data = load_json(os.path.join(raw_dir, name))
            if isinstance(data, dict):
                for n in data.get("notes") or []:
                    detector_notes.append(f"{name[: -len('.json')]}: {n}")

    by_sev = {s: 0 for s in (BLOCKER, MAJOR, MINOR, NIT)}
    unknown_sev = 0
    by_tool = {}
    for i, f in enumerate(findings, 1):
        # canon_severity, not a bare dict index: an unrankable value must show up in a
        # count of its own instead of dropping out of every bucket while staying in
        # `findings` — the fail-open that made the metrics contradict the finding list.
        canon = canon_severity(f["severity"])
        if canon:
            by_sev[canon] += 1
        else:
            unknown_sev += 1
        by_tool[f["_tool"]] = by_tool.get(f["_tool"], 0) + 1
        f["id"] = f"SCAN-{f['severity']}-{i}"
    ordered = []
    for f in findings:
        ordered.append({
            "id": f["id"], "severity": f["severity"], "category": f["category"],
            "location": f["location"], "title": f["title"], "evidence": f["evidence"],
            "recommendation": f["recommendation"], "ux_impact": f["ux_impact"],
            "in_diff": f["in_diff"], "confidence": f["confidence"],
            # Not in the contract, but the triage step needs to know which tool spoke, and the
            # schema does not forbid extra keys.
            "tool": f["_tool"], "rule": f["_rule"],
        })

    # ORDERING, and it is load-bearing: `rollup_verdict` runs the contract gate, `id` is one of
    # the keys that gate requires, and ids are assigned in the loop ABOVE. Compute the verdict
    # before that loop and every scanner finding reads as contentless, so a red scan reports
    # APPROVE. The bare subscripts in `ordered` are the assertion that keeps this honest: this
    # pipeline's own findings carry all ten keys by construction (`mk()`), so a KeyError here
    # means a parser regressed, and the gate below is for FOREIGN findings, not these.
    # A real check, not an `assert`: python -O strips asserts, and an invariant that silently stops
    # being checked under a flag is the shape of invariant this whole change exists to remove. The
    # ordering it guards is load-bearing — `rollup_verdict` runs the contract gate, `id` is one of the
    # keys that gate requires, so computing the verdict before the id-assignment loop above would make
    # every scanner finding read as contentless and report APPROVE on a red scan.
    if not all(f.get("id") for f in ordered):
        raise RuntimeError(
            "ids must be assigned before the verdict is rolled up — the contract gate requires `id`, "
            "so an unnumbered finding reads as contentless and silently stops blocking.")

    contract = {
        "agent": "review-scan",
        "category": "SCAN",
        "source_branch": args.source_branch,
        "target_branch": args.target_branch,
        "findings": ordered,
        # Was `by_sev[BLOCKER] or by_sev[MAJOR]`. The floor now decides, and in
        # 3.0.0 it defaults to MINOR. Computed from the findings rather than the severity
        # counts because the counts carry neither in_diff nor confidence — and INCOMPLETE
        # needs a third arm the counts cannot express at all.
        "verdict": rollup_verdict(ordered),
        "metrics": {
            "total": len(ordered),
            "blocker": by_sev[BLOCKER], "major": by_sev[MAJOR],
            "minor": by_sev[MINOR], "nit": by_sev[NIT],
            "coverage_pct": coverage_pct,
            "ux_impact_count": 0,
        },
        "scan_meta": {
            "tools_run": ran,
            "tools_skipped": skipped,
            "by_tool": by_tool,
            "truncated_findings": truncated,
            "max_findings": args.max_findings,
            "suppressed_rules": suppressed,
            "diff_scoped": False,   # set true by review-scan.sh after the hunk filter runs
            "notes": [
                n for n in (
                    "checkov severity is unavailable without a Bridgecrew/Prisma API key; its "
                    "findings default to MINOR regardless of real risk."
                    if "checkov" in by_tool else None,
                    "pylint convention/refactor messages are dropped as style noise; "
                    "fatal/error/warning are kept."
                    if "pylint" in ran else None,
                    f"{truncated} lowest-severity finding(s) truncated at the {args.max_findings} cap."
                    if truncated else None,
                    f"{unknown_sev} finding(s) carry a severity this pipeline cannot rank; they are "
                    "in `findings` but in no severity bucket, and they never block. Fix the emitting "
                    "detector rather than the count."
                    if unknown_sev else None,
                ) if n
            ] + [
                f"suppressed {s['count']} x {s['rule']}: {s['reason']}" for s in suppressed
            ] + detector_notes,
        },
    }

    tmp = args.out + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(contract, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, args.out)

    print(f"normalize: {len(ordered)} finding(s) from {len(ran)} tool(s) "
          f"({by_sev[BLOCKER]}B/{by_sev[MAJOR]}Ma/{by_sev[MINOR]}Mi/{by_sev[NIT]}N)"
          + (f", {unknown_sev} unrankable severity" if unknown_sev else "")
          + (f", {truncated} truncated" if truncated else "")
          + (f", {sum(s['count'] for s in suppressed)} suppressed "
             f"({', '.join(s['rule'] for s in suppressed)})" if suppressed else ""),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
