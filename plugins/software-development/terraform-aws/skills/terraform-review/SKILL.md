---
name: terraform-review
license: MIT
description: "Reviewing an infrastructure-as-code change for the things a scanner cannot decide: blast radius, whether a resource replacement is destructive, and whether state will be orphaned. Use when reviewing a Terraform merge request or reading a plan before approving an apply. The mechanical checks belong to the review pipeline's detectors and are deliberately not repeated here."
---

# Reviewing a Terraform Change

## What this skill is not

`code-review-core` ships a `terraform` detector that runs **`terraform fmt`, `tflint`,
`checkov` and `tfsec`** over the changed `.tf` / `.tfvars` / `.hcl` files on every scan. It
is deterministic, it is free, and it runs whether or not anyone remembered to.

So do not spend a review on:

- formatting, alignment, argument ordering — `terraform fmt`
- deprecated arguments, unused declarations, invalid instance types, missing required
  arguments, naming-convention rules — `tflint`
- unencrypted storage, public access blocks, missing logging, open security groups, IMDSv1,
  the entire library of known-bad resource configurations — `checkov` and `tfsec`

Restating those in a human review has a real cost: it fills the comment thread with things
that were already caught, and it trains the author to skim. A linter beats a reviewer at
grep-shaped detection. Leave it to the linter.

One gap worth knowing about, since it looks like it should be covered and is not:
`terraform validate` is **never** run by the detector, on purpose — it requires
`terraform init`, and a review scan authenticates nowhere. And the pipeline's `deps`
detector reads package manifests, not `.tf` provider constraints. So provider and version
pinning is on you, unless a `tflint` ruleset in the repo covers it.

## What a reviewer is actually for

Three questions no scanner can answer, because all three depend on state and on what the
resource *is to the business* rather than on what the file says:

1. **What is the blast radius if this is wrong?**
2. **Is anything here destroyed and rebuilt, and can it survive that?**
3. **Does state end up matching reality?**

## No plan, no review

Review the **plan**, not the diff. A three-line diff can produce a plan that destroys a
database, and a two-hundred-line refactor can produce a plan with zero changes. The diff
tells you what the author wrote; only the plan tells you what will happen to *this*
environment's *current* state.

Ask for the plan output — from the pipeline job, against the environment being changed.
If the change is going to several environments, the plan for production is the one that
matters, and it is not the same as the one for the sandbox.

Read the summary line, then read the body. `Plan: 3 to add, 1 to change, 2 to destroy`
is where review starts, not where it ends.

## Reading the plan

| Symbol | Meaning | Reviewer's reaction |
| --- | --- | --- |
| `+` | create | Fine, usually. Check naming and that it is not a duplicate of something that already exists outside Terraform. |
| `~` | update in place | The cheap case. Read what attribute changed. |
| `-/+` | **destroy then create** | Stop here. This is the main event — see below. |
| `+/-` | create then destroy (`create_before_destroy`) | Safer ordering, but still a new resource: new id, new endpoint, new ARN. Anything referencing the old one by a hardcoded value breaks. |
| `-` | destroy, with no replacement | Why? Either an intentional removal, or something fell out of the configuration by accident. |
| `# forces replacement` | the attribute that caused `-/+` | The single most important comment in the output. Find every one of them. |
| `(known after apply)` on an attribute another resource depends on | A cascade | Downstream resources may replace too, and the plan cannot always show it. |

### The replacement question

For every `-/+`, answer out loud: **what is lost between the destroy and the create?**

| Resource class | What replacement costs |
| --- | --- |
| Stateless compute, a function version, a task definition | Usually nothing. Replacement is the normal update path. |
| A database instance or cluster | **The data**, unless a final snapshot is taken and restored — which is not the same resource and not the same endpoint. This is never a routine approval. |
| A storage bucket or container registry | The contents, if `force_destroy` is set. If it is not set, the destroy fails halfway and leaves you with a partially applied change. |
| Anything with a DNS name or endpoint that clients cache | A rebuild is an outage of however long propagation takes |
| A security group or subnet with dependents | Cascading replacement of everything attached |
| An IAM role | Every existing session using it, and any external trust policy naming it by ARN |
| A key in a key management service | Data encrypted under the old key, if the key is genuinely destroyed rather than rotated |

Things that commonly force a replacement without the author intending it: a changed `name`
or `name_prefix`, a changed availability zone or subnet, a changed engine version on some
engines, a changed `count`/`for_each` key, and a provider upgrade that moved an attribute
from updatable to force-new.

Guardrails to look for in the same review: `lifecycle { prevent_destroy = true }` on the
resources whose loss would be unrecoverable, `deletion_protection` where the provider
offers it, and `skip_final_snapshot = false` on anything holding data. If a change *removes*
one of those, that removal is the change being reviewed, whatever else is in the diff.

### Count and for_each index shifts

A resource with `count` over a list is addressed by position: `module.x.aws_thing.y[2]`.
Remove the second element and every subsequent resource shifts down one index, so
Terraform plans to replace all of them — changing live resources purely because a list got
shorter.

`for_each` over a map addresses by key, so removing an entry destroys exactly that entry.
Prefer it. But be aware that **converting `count` to `for_each` re-addresses every
existing instance**, which is itself a mass replacement unless `moved` blocks are supplied.
That conversion is a legitimate, valuable change and a dangerous one to approve casually:
it should arrive with the `moved` blocks in the same change and a plan showing zero
replacements.

## State orphaning

The failure mode that survives the apply and bites weeks later: state and reality disagree,
and nothing errors.

| Situation | What happens | What the change should contain |
| --- | --- | --- |
| A resource or module is **renamed** in the configuration | Terraform sees the old address gone and a new one arrived: destroy + create | A `moved` block from the old address to the new one, and a plan proving it is a no-op |
| A resource is **deleted from the configuration** but should keep existing | Terraform destroys it | A `removed` block with `destroy = false`, so it leaves state without being deleted |
| A resource exists in the cloud but not in state | Terraform tries to create it and fails on a name conflict, or worse, creates a duplicate | An `import` block, reviewed against the real resource's id |
| Someone ran `terraform state rm` | The resource is live, unmanaged, and invisible to every future plan | It should not be in the change at all; ask what problem it was solving |
| A resource was **moved between root modules** | It is destroyed by one and created by the other, in whichever order the two pipelines happen to run | A deliberate, sequenced migration: import into the new state first, `removed` from the old second |
| The apply was **`-target`ed** | State is a partial application of the configuration; the next full plan shows diffs nobody expected | `-target` in a pipeline is a finding. It is a debugging tool, not a deploy mechanism. |

The reviewer's shortcut: **any change to a resource's address deserves the same scrutiny as
a change to its arguments.** Renaming for clarity is a good thing to do and a thing that
destroys production if it arrives without a `moved` block.

## Blast radius

Before approving, size the change:

- **How many resources, and in which environment?** A plan that touches 40 resources in
  production is not the same review as one that touches 2 in a sandbox.
- **Is this environment shared?** A change to a VPC, a shared subnet, a transit
  attachment, a shared key or a central logging configuration affects every workload in the
  account, including ones the author has never heard of.
- **Who consumes the outputs of this stack?** If another stack reads this one's remote
  state or its published parameters, renaming or removing an output is a breaking change to
  a consumer that will not fail until its own next apply.
- **Is it reversible?** Reverting the commit and re-applying restores most things. It does
  not restore deleted data, and it does not un-send whatever the intermediate state did.
- **Has it been applied anywhere first?** A change that landed cleanly in a lower
  environment is evidence. A change going straight to production is not, and the reason
  should be in the description.

## Cross-cutting things to check

- **Secrets.** No literal credential in `.tf` or committed `.tfvars`; data sources for
  anything sensitive. Note that any secret the configuration reads is in state in
  plaintext regardless — so a new secret-reading data source is also a question about who
  can read the state bucket. See `dev-standards` → `secrets-management`.
- **Provider upgrades bundled with resource changes.** Keep them separate. When a bundled
  change produces an unexpected replacement, you cannot tell whether the author caused it
  or the provider did.
- **Module source and version.** A module pinned to a branch rather than a version is
  mutable remote code: it can change under you between plan and apply.
- **Environment parity.** If a change goes to one environment and not the others, the
  description should say why. Silent divergence is how the sandbox stops predicting
  production.
- **Tagging.** Not cosmetic — cost attribution, ownership routing during an incident, and
  frequently the thing IAM conditions and automation match on.

## The approval sentence

Before approving, write one sentence in the review: *"This changes `<what>` in `<which
environment>`; the destructive operations are `<list, or none>`; if it is wrong, `<what
breaks>` and recovery is `<how>`."*

If you cannot complete that sentence from the plan, you have not reviewed the change yet —
ask for what is missing rather than approving on the strength of a clean scan.
