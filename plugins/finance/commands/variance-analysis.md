---
description: Explain budget vs actual variances from a CSV or pasted table, with drivers and recommended actions
argument-hint: <path to CSV or paste budget/actual figures> [period]
allowed-tools: Read, Glob, Bash(python3:*), Bash(node:*)
---

Run a budget-versus-actual variance analysis on: $ARGUMENTS

Steps:
1. Load the data. Expect columns like account/line item, budget, actual (and optionally prior period). If the columns are ambiguous, ask once.
2. Compute variance in both currency and percent for every line, and flag anything over ±10% or over the larger of ±5% and the top five absolute variances.
3. Group flagged lines into: timing (spend shifted between periods), volume (more/less activity than planned), rate (price/cost per unit changed), and one-offs. Say which group each falls into and why; if you cannot tell from the data, say what information would settle it.
4. Produce:
   - A summary table of flagged lines: item, budget, actual, variance, variance %, likely driver.
   - Three sentences a CFO could read aloud: total variance, the two biggest drivers, and whether the full-year forecast should change.
   - Recommended actions, each with an owner placeholder.

Do not round away the signal: keep two decimals in tables. State the currency. Never invent numbers that are not in the source data.
