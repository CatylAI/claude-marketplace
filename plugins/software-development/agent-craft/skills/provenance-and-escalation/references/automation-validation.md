# Worked examples: validating before you automate

Read this when you are deciding which extraction segments to automate, or when you are designing a
review queue.

## Findings that carry provenance from retrieval

```json
{ "findings": [{
  "claim": "Average module efficiency rose from 16.2% to 20.3% over the decade",
  "source_url": "https://example.org/solar-report",
  "document_name": "Annual Solar Industry Report",
  "page_number": 14,
  "excerpt": "Average module efficiency improved from 16.2% to 20.3%, a relative gain of 25%.",
  "publication_date": "2024-11-03",
  "retrieved_by": "source-gatherer:solar"
}] }
```

The excerpt lets a reviewer verify the claim without fetching the source again. The publication
date lets a later reader judge staleness. The retriever field traces a bad source back to the agent
that trusted it.

## A conflict preserved with attribution

```json
{ "field": "annualRevenue",
  "conflictDetected": true,
  "values": [
    { "value": "4.2M USD", "source": "Annual Report", "context": "Audited, fiscal year ending 31 Dec" },
    { "value": "3.8M USD", "source": "Regulatory filing Q4", "context": "Preliminary unaudited, calendar year" }],
  "possibleExplanation": "Audited versus preliminary, fiscal versus calendar. Not necessarily inconsistent.",
  "resolution": "deferred_to_consumer" }
```

## Segmented validation before any automation decision

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
          Review invoice_date for non-US vendors. Keep purchase_order manual.
```

The order of steps matters: validate by segment, calibrate, set thresholds, sample with
stratification, and only then reduce review on the segments that passed.

## Stratified sampling that includes the confident path

```python
sample = (
    random.sample(low_confidence,  k=30) +   # expected errors
    random.sample(mid_confidence,  k=30) +   # the ambiguous band
    random.sample(high_confidence, k=40)     # finds new error modes in the automated path
)
# Track each stratum separately. A rising high-confidence error rate is an early warning that
# the input distribution has shifted.
```

The inverse is a review queue built as `[x for x in extractions if x.confidence < 0.7]` and sorted
by arrival time. It never sees the automated path, and it spends the first hours of reviewer time on
whatever arrived first.
