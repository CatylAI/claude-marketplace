---
name: provenance-and-escalation
description: "Making agent output trustworthy and escalating for the right reasons: attaching provenance at retrieval so it survives synthesis, annotating conflicting sources instead of resolving them, stating coverage gaps explicitly, validating accuracy per document type and per field before automating anything, calibrating confidence before routing on it, ordering review queues by highest uncertainty, and the three legitimate escalation triggers. Use when output needs citations, when sources disagree, when deciding what to automate versus review, or when an agent escalates too often or too rarely. Not for schema design or for the mechanics of approval gates."
license: MIT
---

# Provenance and escalation

Two failure modes sit at opposite ends of one axis. An agent that cannot say where a claim came
from is untrustworthy. An agent that escalates whenever a user sounds upset is useless. Both are
design failures, not model failures.

The governing principle: never resolve a conflict or a gap on the agent's own authority when a
human or a downstream consumer is the legitimate decider. Annotate and pass it on.

## 1. Provenance travels with every finding, not with the report

Every finding carries the claim, the source URL or identifier, the document name, the relevant
excerpt, the publication or collection date, and who retrieved it. Attach it at retrieval time.
Provenance you intend to reattach later is provenance you have already lost.

The most common loss point is **synthesis paraphrasing**. Instruct the synthesis agent explicitly
to preserve and merge claim-to-source mappings, and to end with inline citations or a structured
reference section. If your synthesis output has no citations, the defect is upstream in context
passing, not in the synthesis prompt.

Render by content type: financial comparisons as tables, news as prose, technical detail as
lists. A financial comparison written as prose forces the reader to reconstruct a table badly.

## 2. Annotate conflicts with full attribution; do not resolve them

When sources disagree, attach both values with their full context and let the consumer decide.

Do not resolve by picking the newer value, the more authoritative source, or an average. Each of
those destroys information and hides the disagreement from the only party entitled to judge it.

Preserve publication and collection dates, because different dates usually explain different
numbers — you are often looking at a trend rather than a contradiction. The same holds for audited
versus preliminary, fiscal versus calendar, and restated versus original.

An analysis agent that finds a conflict should complete its work with the conflict included and
annotated, leaving resolution to the coordinator or the consumer. Silently dropping one value is
the worst available outcome: the output looks clean and is wrong.

## 3. Make coverage gaps visible

Add coverage annotations to any synthesis built from partial inputs: "Section on geothermal is
limited — the two primary journals were unavailable during collection." A stated gap is a gap the
reader can act on. A silent gap becomes a confident claim about a thin evidence base.

This is the downstream counterpart of structured partial failure. If failures are being
suppressed upstream, there is nothing to annotate and the report lies by omission.

## 4. Validate accuracy by document type *and* field segment before automating

A high aggregate routinely hides catastrophic per-segment failure. 97% overall can be 99% on
clean digital PDFs, 60% on photographed receipts, and 45% on international date and currency
formats. Automating on the aggregate means automating the 45%.

The order matters, and skipping to the last step is the trap:

```text
Validate (by type and field) -> Calibrate (labelled sets) -> Set thresholds ->
Stratified sampling -> only THEN reduce review on the validated segments
```

Segment by the dimensions that actually vary: document type, source, language and locale, field
type, and whether a field is stated explicitly or must be inferred.

## 5. Calibrate confidence before routing on it

Per-field confidence is useful only after calibration against labelled data. Raw model
self-assessment is poorly calibrated — a 0.9 does not mean 90%.

Calibrate, then route: above threshold, automate *with ongoing sampling*; in the ambiguous band,
prioritized review; below threshold, review.

Sample stratified-randomly, **including high-confidence extractions**. Reviewing only
low-confidence items means novel error patterns in the automated path are never discovered — they
are, by construction, the errors the model is confident about.

## 6. Spend reviewer capacity on the highest uncertainty first

Reviewer capacity is fixed and small. Spending it evenly across all extractions spends most of it
on records that were already right.

Work a dynamic queue where the next item is always the highest-uncertainty item remaining, not the
next chronologically. As items are reviewed and the model corrected, the ordering changes —
recompute rather than freezing a ranked list at the start of the day.

## 7. Escalate on exactly three triggers

1. **The person explicitly asks for a human.** Do it immediately. No "let me try first."
2. **A policy gap** — the policy is *silent* on this situation. Note the distinction: a policy
   *violation* has a documented no, which is an answer, not a gap.
3. **Inability to progress** after genuinely attempting resolution.

Nothing else. In particular:

- **Do not escalate on sentiment.** Frustration is not complexity. A frustrated person with a
  resolvable problem gets acknowledgement and a resolution; escalate only if they reiterate
  wanting a human after you have offered help.
- **Do not escalate on self-reported confidence.** It is poorly calibrated, so a confidence
  trigger produces escalations that correlate with phrasing rather than with difficulty.

For ambiguous record matches, ask for a disambiguating identifier — email, phone, order number.
Never auto-select among multiple matches by "most recent", "most active", or any other heuristic:
that is a privacy violation and a wrong-account action waiting to happen.

## 8. The handoff payload itself is a separate concern

The human does not see the transcript, so every escalation must be self-contained. This skill
decides *whether* to escalate; the required fields and a worked example belong with the
enforcement and handoff guidance.

## Audit checklist

- [ ] Pick three claims from a recent agent output. Each traces to a source, a document, and an
      excerpt without re-running anything.
- [ ] Provenance is attached at retrieval, not assembled after synthesis.
- [ ] The synthesis prompt says to *preserve and merge* source mappings, not merely to "cite".
- [ ] Spot-check five citation URLs. Fabricated citations cluster.
- [ ] There is a conflict-detected path; one value does not silently win.
- [ ] Publication and collection dates are preserved, so a trend is not mistaken for a
      contradiction.
- [ ] Partial-coverage reports carry an explicit limitations section.
- [ ] An empty section is distinguishable from an unattempted one.
- [ ] Accuracy is segmented by document type, source, locale, and field — not a single number.
- [ ] You know which segment has the worst accuracy, and whether it is currently automated.
- [ ] Confidence values are calibrated against a labelled set rather than used raw.
- [ ] Sampling includes high-confidence items.
- [ ] The review queue is ordered by uncertainty and recomputed, not ordered by arrival.
- [ ] Every escalation trigger in the code is one of the three.
- [ ] Neither sentiment nor model confidence is wired to escalation anywhere.
- [ ] When someone asks for a human, the agent escalates immediately.
- [ ] There is no auto-selection among ambiguous record matches.
- [ ] Handoffs carry everything a reviewer needs, with a machine-readable reason code.

## Patterns that hold up

**Findings that carry provenance from retrieval.**

```json
{ "findings": [{
  "claim": "Utility-scale solar module efficiency rose 25% between 2014 and 2024",
  "source_url": "https://example.org/solar-report-2024",
  "document_name": "Annual Solar Industry Report 2024",
  "page_number": 14,
  "excerpt": "Average module efficiency improved from 16.2% in 2014 to 20.3% in 2024, a relative gain of 25%.",
  "publication_date": "2024-11-03",
  "retrieved_at": "2026-09-08",
  "retrieved_by": "source-gatherer:solar",
  "confidence": "high"
}] }
```

The excerpt lets a reviewer verify the claim without re-fetching, the publication date lets a
later reader judge staleness, and the retriever field makes a systematically bad source traceable
to the agent that trusted it.

**Conflict preserved with attribution and a hypothesis.**

```json
{ "field": "annualRevenue",
  "conflictDetected": true,
  "values": [
    { "value": "4.2M USD", "source": "Annual Report 2023",
      "context": "Audited, fiscal year ending 31 Dec 2023", "published": "2024-03-14" },
    { "value": "3.8M USD", "source": "Regulatory filing Q4 2023",
      "context": "Preliminary unaudited, calendar 2023", "published": "2024-01-29" }],
  "possibleExplanation": "Audited versus preliminary figures, and fiscal versus calendar period. Not necessarily inconsistent.",
  "resolution": "deferred_to_consumer" }
```

The consumer gets both numbers, the reason they differ, and an explicit statement that nobody
resolved it. Compare with "Annual revenue was 4.2M USD" — one of the two numbers, chosen
arbitrarily, with the context that explained the gap deleted.

**Coverage annotation on a partial synthesis.**

```markdown
# Key findings (read first)
...

## Coverage and limitations
- **Geothermal (limited):** the two primary journals were unreachable during collection on
  2026-09-08. Findings here rest on three secondary sources and should be treated as indicative.
- **Offshore wind (complete):** 11 primary sources, including 2026 operator filings.
- **Tidal:** not researched — out of the agreed scope.
```

A reader weighting the geothermal section now knows to discount it, and the distinction between
thin evidence, good evidence, and deliberate exclusion is explicit rather than inferred from
section length.

**Segmented validation before any automation decision.**

```text
Aggregate field accuracy: 97.1%   <- do not automate on this number

By document type:
  digital PDF invoice      99.4%   n=1,840
  scanned PDF invoice      96.1%   n=612
  photo of paper receipt   61.3%   n=208    <- manual only
  handwritten receipt      58.7%   n=94     <- manual only

By field, within digital PDFs:
  invoice_number           99.8%
  total_amount             99.6%
  invoice_date             94.2%   <- DD/MM vs MM/DD on non-US vendors drives every miss
  purchase_order           88.1%   <- absent in 30% of docs; misses are fabrications, not blanks

Decision: automate digital PDFs for invoice_number and total_amount.
          Review invoice_date for any non-US vendor. Never automate purchase_order.
```

The automation boundary follows the measurement. The aggregate would have automated the 58.7%
segment and the field whose errors are inventions rather than omissions.

**Stratified sampling that includes the confident path.**

```python
sample = (
    random.sample(low_confidence,  k=30) +      # expected errors
    random.sample(mid_confidence,  k=30) +      # the ambiguous band
    random.sample(high_confidence, k=40)        # the point: novel error discovery
)
# Track separately. A rising high-confidence error rate is an early warning that the
# input distribution shifted, and it is invisible if you only review low confidence.
```

The automated path is the one with no human in it, so it is the one that needs an independent
error estimate. Sampling only the queue you already distrust measures nothing new.

**Escalation decisions on the three triggers.**

```text
"This is the third time I've called and I'm furious."   [issue: resolvable replacement]
  -> RESOLVE. Acknowledge, reference the earlier tickets, process the replacement now.
     Sentiment is not a trigger. Escalate only if they then ask for a person.

"I want to speak to a person."
  -> ESCALATE immediately. Structured handoff. No investigation first.

"I'm relocating mid-contract to a country you don't ship to — what happens to my subscription?"
  -> ESCALATE (policy gap). The handbook covers cancellation and address changes, not
     cross-border relocation mid-term. Silence is not a no.

"Can I get a refund 9 months after purchase?"
  -> ANSWER, do not escalate. Policy documents a 90-day limit. That is a documented no.

"I found two accounts under that email — which is yours?"
  -> ASK for a disambiguating identifier. Never pick the more recently active one.
```

Each branch names the trigger it matched, so the policy is auditable and an agent that starts
over-escalating can be diagnosed to a specific rule rather than "it got cautious."

## Failure modes

**Provenance stripped at synthesis, then patched with prompt pressure.** "You must include
citations for every claim" reaches a synthesis agent that was never given sources, so the
instruction can only be satisfied by inventing plausible ones — and fabricated citations are worse
than none, because they survive casual review.

**Conflicts resolved by heuristic.** Picking the larger, newer, or more official figure deletes
the context that explained the difference. Averaging is worse: the mean of an audited fiscal-year
figure and a preliminary calendar-year figure appears in no source and describes no real period.

**Silent gaps.** An empty section marked success reads as "nothing notable" rather than "we could
not look," and a summary that generalizes "across all technologies surveyed" from three of five
is false on its face.

**Automating on an aggregate metric.** "97% clears our 95% bar, enabling auto-approval for all
document types" averages over segments with wildly different behavior. Two weeks later the
handwritten segment has produced hundreds of wrong payments, and the metric still reads 97%
because that segment is small.

**Reviewing only low-confidence items, evenly and chronologically.**

```python
queue = [x for x in extractions if x.confidence < 0.7]     # never sees the automated path
for item in sorted(queue, key=lambda x: x.received_at):    # chronological, not by uncertainty
    review(item)
```

Two compounding defects: excluding high-confidence items makes a new error mode in the automated
path undetectable, and chronological ordering spends the first hours of finite capacity on
whatever arrived first rather than on what is most likely wrong.

**Escalating on sentiment or on confidence.**

```python
if sentiment_score < -0.6 or model_confidence < 0.75:
    return escalate_to_human()
```

The sentiment branch escalates every frustrated person with a trivially solvable problem, which
is most of them: the queue fills, humans handle work the agent could have done, and satisfaction
drops because resolution got slower. The confidence branch keys on a poorly calibrated
self-report, so escalation tracks phrasing rather than difficulty.

**Auto-selecting among ambiguous matches.** Choosing the most recently active of several matching
records exposes one person's data to another and acts against the wrong account. "Most recently
active" is a heuristic about the data, not evidence about the person you are talking to. Have the
tool return an ambiguity flag with the candidates and take no action.

## Porting to other stacks

- **RAG pipelines generally** — chunk-level metadata must survive reranking and prompt assembly,
  not just retrieval. The usual break is a template that concatenates chunk text and drops the
  metadata; that is the provenance-loss failure in a different costume. Keep chunk IDs in the
  prompt and resolve them to citations after generation.
- **Document-framework tool layers** — document metadata exists precisely for this and is
  routinely discarded by custom prompt templates. Source-node return is opt-in in several chain
  types; turn it on and assert on it in tests.
- **Human-in-the-loop platforms** — highest-uncertainty-first ordering and stratified sampling
  that includes the confident path are queue-design rules, independent of tooling. Most
  out-of-the-box queues default to chronological; change it.
- **Anywhere** — "annotate conflicts, don't resolve them", "segment before you automate", and
  "sentiment is not complexity" are policy decisions about who gets to decide. No framework makes
  them for you, and every framework lets you get them wrong.

## Scope note

The escalation triggers, the calibrate-then-route split, the segment-before-automating sequence,
and the highest-uncertainty-first queue are engineering practice distilled from production agent
deployments — not API specifications. They are defensible and testable, but present them to your
team as house rules with a rationale rather than as platform requirements. The one hard technical
fact underneath them all: model self-reported confidence is poorly calibrated, so anything routing
on it without calibration is routing on noise.
