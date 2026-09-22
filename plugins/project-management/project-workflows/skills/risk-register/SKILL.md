---
name: risk-register
description: Create and maintain a project risk register with likelihood, impact, owners and mitigations. Use when the user mentions project risks, a risk register, "what could go wrong", dependencies, assumptions, or planning a project kickoff.
---

# Risk register

A risk is an uncertain event that would matter. An issue is a risk that has already happened. Keep them in separate lists.

## Register format

| ID | Risk (if X happens, then Y) | Likelihood 1-5 | Impact 1-5 | Score | Owner | Mitigation | Trigger / early warning | Status |
|----|-----------------------------|----------------|------------|-------|-------|------------|-------------------------|--------|

Score = likelihood × impact. Anything 15 or above needs a mitigation with an owner and a date; anything 20 or above goes in the status report every week.

## Writing a good risk statement

- Format: "If **cause**, then **effect**, resulting in **impact to the project**."
- Bad: "Vendor delays." Good: "If the payment vendor's sandbox is not available by 1 Oct, integration testing slips two weeks, pushing launch past the marketing campaign."
- One risk per row. Split compound risks.

## Building a register from scratch

Walk these categories with the user and propose two or three risks each: people (availability, key-person), scope (unclear requirements), technical (unproven components, integrations), external (vendors, regulation), schedule (dependencies, holidays), and budget.

## Maintaining it

- Review at each status meeting: re-score, close risks that have passed, promote triggered risks to the issue list.
- Record the date of each change in a short changelog under the table so the history survives.
