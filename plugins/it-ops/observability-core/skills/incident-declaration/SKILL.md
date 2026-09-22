---
name: incident-declaration
description: "Declare a production incident the moment impact is confirmed — before root cause is known. Use when production is degraded or broken, when someone asks 'is this an incident?', when severity must be assigned, or when incident roles and a stakeholder update cadence need setting up. Vendor-neutral: works with any incident tool or a plain shared document."
license: MIT
---

# Incident Declaration

## The mandate: declare at confirmation, not at diagnosis

**The moment production impact is confirmed, open the incident record.** Not after the
root cause is found. Not after the fix merges. At confirmation, with nothing but the
symptom — then amend the record as evidence arrives.

Declaring early is cheap and reversible: an incident opened on a symptom that turns out
to be benign is downgraded and closed in a minute. Declaring late is not reversible. The
minutes between "we noticed" and "we declared" are the minutes nobody else could help,
nobody was paged, and no timeline was being kept.

**Do not report a diagnosis while the incident does not exist or does not say it.** If
you are writing up a root cause anywhere — a chat message, a ticket, a summary for the
user — that write-up belongs in the incident record first.

**A ticket does not discharge this.** A work tracker item records the *fix*; the incident
records the *event* — how it was detected, what was tried, when impact started and
stopped. A production defect gets both.

### Why this rule exists

The failure mode is not laziness; it is momentum. An engineer confirms impact, forms a
hypothesis, starts investigating, and the investigation absorbs all available attention.
The diagnosis comes out sound — and the record of the event very nearly does not survive
the session, because nobody stopped to declare. Declaring is part of responding, not
paperwork appended to it.

### The confirmation test

Declare when **any** of these is true:

- A user-facing request path is failing, hanging, or returning wrong results.
- An error rate, latency percentile or success-rate metric has crossed its alerting
  threshold and a human has confirmed the signal is real.
- Data is being lost, duplicated, or written incorrectly.
- A security-relevant control has failed open.
- You are about to tell someone outside your team that production is broken.

If you are debating whether it qualifies, declare at the lowest severity and downgrade
later. The debate itself costs more than the declaration.

## Severity by customer impact, never by cause

Severity answers *how badly are users hurt right now*. It does not answer how interesting
the bug is, how hard the fix looks, or which team's code is at fault. Establish the
affected population first (see the `blast-radius` skill), then read severity off it.

| Sev | Customer impact | Response posture |
|-----|-----------------|------------------|
| **Sev1** | Core function unusable for most users, or any confirmed data loss / security exposure. No workaround. | Page immediately, 24/7. All-hands. Continuous comms. |
| **Sev2** | Core function broken for a significant subset (a region, a tenant tier, a major feature), or severe degradation for most. Workaround exists but is painful. | Page during and outside hours. Dedicated responders. Regular comms. |
| **Sev3** | Narrow or intermittent impact; a secondary feature, a small tenant set, or degradation users can route around. | Business-hours response. Named owner. Update on change. |
| **Sev4** | No current customer impact — near-miss, internal-only breakage, or a control that failed silently and was caught. | Track and fix on the normal schedule. Record so it is not forgotten. |

**Severity is a live field.** Re-evaluate when the blast-radius number changes, when a
mitigation lands, or when a new population is found to be affected. Raising severity late
is normal and expected; it is not an admission that the first call was wrong.

**Cause never changes severity.** "It's only a config typo" and "it's a deep race
condition" produce the same severity if the same number of users are broken. The cause
determines the *fix*, not the *response*.

## Roles

Assign these explicitly and by name, out loud, at declaration. On a small incident one
person may hold several — but say which ones they hold.

- **Incident Commander (IC).** Owns the response, not the fix. Decides severity, assigns
  work, calls checkpoints, decides when to escalate and when to declare mitigated. The IC
  should not be head-down in a debugger; if they start debugging, hand the role over.
- **Operations / fixers.** The people actually investigating and shipping changes. They
  report findings to the IC and do not ship mitigations without the IC knowing.
- **Communications lead.** Owns stakeholder and customer-facing updates on the cadence
  below, so responders are not context-switching to write status posts.
- **Scribe.** Keeps the timeline in the incident record as events happen — detection,
  each hypothesis, each action, each observed effect. Retro-fitting a timeline from chat
  history afterwards loses exactly the beliefs-at-the-time that make it useful.

## Communication cadence

Set the cadence at declaration and state it in the first update, so nobody has to ask
whether news is coming.

| Sev | Internal update | Stakeholder / customer update |
|-----|-----------------|-------------------------------|
| Sev1 | Every 15–30 min, even if the update is "no change" | At declaration, then at least hourly, plus at mitigation and resolution |
| Sev2 | Every 30–60 min | At declaration, then on material change |
| Sev3 | On material change | On resolution, or sooner if a customer is asking |
| Sev4 | On resolution | Usually none |

**"No change" is a valid update and must still be sent.** Silence is read as either
"resolved" or "abandoned", and both readings cause harm.

Every update states, in this order: current impact, what is known, what is being tried,
and when the next update lands. Do not publish a root cause until it is confirmed —
publish the symptom and the current hypothesis, labelled as a hypothesis.

## The scope-reset checkpoint

**After two consecutive mitigations to the same layer with no movement in the top-line
symptom, the IC must call a scope-reset checkpoint before a third is shipped.** Say it in
the channel: *"Scope-reset checkpoint — no third fix until we answer 1/2/3."*

The checkpoint takes fifteen minutes and answers three questions in writing:

1. **Has the symptom actually moved?** Compare the top-line signal — error rate, failed
   request count, latency percentile — against the value at declaration. If two deploys
   have not moved it, the layer being fixed is not the cause.
2. **What is the working hypothesis, and what would falsify it?** One sentence for the
   hypothesis, then a specific query, log or metric whose result would prove it wrong. A
   hypothesis nothing can falsify is not a hypothesis; reset.
3. **What layers outside the hypothesis are unchecked?** Enumerate at minimum: shared
   telemetry and gateway infrastructure, upstream (auth, ingress, DNS, CDN), downstream
   (database, cache, queue), and configuration or infrastructure changes in *adjacent*
   repositories in the last 24 hours — not just the one being fixed.

Only after all three are answered may a third mitigation ship. If the answers point
outside the current layer, hand the incident to the team that owns the actual layer and
stop shipping in the original one.

The reason this is a rule and not advice: under pressure, the second failed fix generates
*more* conviction rather than less, because sunk effort reads as evidence. The checkpoint
exists so the next IC does not have to invent the decision to stop while the clock runs.

## Closing out

Resolving impact is not closing the incident. Before an incident closes, confirm the
record contains: the symptom as first seen, how it was detected, corrected detection and
start times, severity history, affected services and populations, the timeline with
hypotheses that were refuted, the mitigation, the confirmed root cause, and the
follow-ups.

**Every follow-up becomes an owned item in the work tracker** — not a checkbox that lives
only in the incident record, which evaporates when the incident closes. Each follow-up
gets a real ticket in a ready state with a named owner (default: the IC, who may
reassign), cross-linked from the incident. Two qualifications:

- If an existing ticket already covers the follow-up, link it rather than duplicating.
- If that existing ticket belongs to someone else, do not reassign it to yourself to
  satisfy this rule. Assign-to-the-IC governs *new* items.

An incident with an empty root cause field reads, a quarter later, exactly like no
incident at all. State any field you could not fill, and why you could not fill it.

For the blameless write-up itself — timeline format, five-whys, contributing factors and
the action-item table — use the `incident-postmortem` skill from the `ops-workflows`
plugin. This skill hands off there; it does not duplicate it.
