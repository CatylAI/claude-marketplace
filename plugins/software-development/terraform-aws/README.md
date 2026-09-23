# terraform-aws

Infrastructure standards for Terraform on AWS: how modules and state backends are laid
out, how IAM roles and CI credentials are designed, how a schema change ships without
downtime, and what a human should be looking at when reviewing an infrastructure change.

Works in **Claude Code** and in **Cowork** (Claude Code on the web) — with an important
caveat about shell access and credentials, below.

## What it is

Four skills that cover the decisions a linter cannot make. The repository's review
pipeline already runs `terraform fmt`, `tflint`, `checkov` and `tfsec` on every change;
this plugin deliberately does not restate any of that. It covers the judgement: what a
state backend's locking story should be, why an apply from a laptop is a structural
problem rather than a discipline problem, which wildcard in an IAM policy is the one that
matters, when a schema change can safely ship in one deploy, and whether a plan's `-/+` is
routine or an outage.

Every identifier in every example is a placeholder — `111111111111`,
`<org>-tfstate-<env>`, `alias/<org>-terraform-state`, `arn:aws:iam::111111111111:role/<role-name>`.
Substitute your own values. Copying an identifier out of documentation into a backend file
is how state ends up in the wrong place, and it does not produce an error.

## When to use it

- Scaffolding a new Terraform project and deciding how state, environments and modules are
  arranged.
- Designing or reviewing an IAM role, a trust policy, or the credential a pipeline uses to
  reach AWS.
- Replacing long-lived CI access keys with OIDC federation.
- Sequencing a database schema change across releases so nothing breaks mid-rollout.
- Reviewing an infrastructure merge request, or reading a plan before approving an apply.

## When not to use it

- **You want something provisioned.** Nothing here creates a resource, runs `apply`, or
  attaches a policy. That is the point: this plugin's own advice is that `apply` against
  shared state belongs to a pipeline, so it does not run one for you.
- **You want the mechanical checks.** `terraform fmt`, `tflint`, `checkov` and `tfsec` are
  the `terraform` detector in `code-review-core`. Run the scan; do not reimplement it.
- **You need secret-storage conventions.** Those are `dev-standards` →
  `secrets-management`.
- **You are on another cloud, or another IaC tool.** The migration discipline ports. The
  rest does not.

## Prerequisites

A Terraform CLI on PATH and an AWS identity you can already use. Confirm both before
reading any output as meaningful:

```
terraform version
aws sts get-caller-identity
```

An unexpected account in the second answer is a reason to stop, not a detail.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install terraform-aws@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `terraform-standards` | Skill | Module layout, typed variables and outputs, S3 backend configuration with locking, directory-per-environment over workspaces, provider pinning, and the fmt/init/validate/plan order | both |
| `aws-iam-boundaries` | Skill | Least-privilege role design, assume-role chains, OIDC federation in place of static access keys, permission boundaries, and triaging policy wildcards by severity | both |
| `database-migrations` | Skill | Expand/migrate/contract, safe patterns per change type, what makes a migration reversible, deploy ordering, and forward-fixing when rollback is not available | both |
| `terraform-review` | Skill | Reading a plan for blast radius, destructive replacement and orphaned state — explicitly excluding what the `terraform` detector already catches | both |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**These skills are fully readable on both surfaces, but only executable on one.** Every
command they describe — `terraform plan`, `aws sts get-caller-identity`, a policy
simulation, a migration run — needs a shell, a checkout and live credentials, and Cowork
has none of those. The standards, the tables and the review checklists are text and work
anywhere; actually running any of it means Claude Code.

## Layout

```
terraform-aws/
├── .claude-plugin/plugin.json                 # manifest (name, version, description, dependencies)
├── SKILL.md                                   # plugin entry point; skill roster and scope
├── skills/
│   ├── terraform-standards/SKILL.md           # modules, state, environments, pinning, plan discipline
│   ├── aws-iam-boundaries/SKILL.md            # roles, assume-role chains, OIDC, boundaries, wildcards
│   ├── database-migrations/SKILL.md           # expand/contract, reversibility, deploy ordering
│   └── terraform-review/SKILL.md              # blast radius, replacement, state orphaning
└── README.md
```

## Dependencies

- `dev-standards` — the vendor-neutral engineering standards these skills sit on top of,
  in particular `secrets-management` for credential paths and `code-review-standards` for
  the severity ladder a review finding is written against.

Complementary, not required: `code-review-core`, whose `terraform` detector owns every
mechanical check this plugin refuses to duplicate.

## License

MIT
