# terraform-aws

Infrastructure standards for Terraform on AWS: how modules and state backends are laid
out, how IAM roles and CI credentials are designed, and what a human should be looking at
when reviewing an infrastructure change.

Works in **Claude Code** (including Claude Code on the web) and in **Cowork and the claude.ai
apps**. In Cowork and claude.ai, and wherever there is no checkout, the skills work from HCL,
policy JSON or plan output you paste in.

## What it is

Three skills that cover the decisions a linter cannot make. The repository's review
pipeline already runs `terraform fmt`, `tflint`, `checkov` and `tfsec` on every change;
this plugin deliberately does not restate any of that. It covers the judgement: what a
state backend's locking story should be, why an apply from a laptop is a structural
problem rather than a discipline problem, which wildcard in an IAM policy is the one that
matters, and whether a plan's `-/+` is routine or an outage.

The through-line: **dangerous operations should be impossible from a laptop, not merely
discouraged.** A state backend whose role only the CI identity can assume is a mechanism; a
rule in a README is a wish.

Every identifier in every example is a placeholder — `111111111111`,
`<org>-tfstate-<env>`, `alias/<org>-terraform-state`, `arn:aws:iam::111111111111:role/<role-name>`.
Substitute your own values. Copying an identifier out of documentation into a backend file
is how state ends up in the wrong place, and it does not produce an error.

## When to use it

- Scaffolding a new Terraform project and deciding how state, environments and modules are
  arranged.
- Designing or reviewing an IAM role, a trust policy, or the credential a pipeline uses to
  reach AWS.
- Replacing long-lived CI access keys with OIDC federation from GitHub Actions or GitLab CI.
- Reviewing an infrastructure merge request, or reading a plan before approving an apply.

## When not to use it

- **You want something provisioned.** Nothing here creates a resource, runs `apply`, or
  attaches a policy. That is the point: this plugin's own advice is that `apply` against
  shared state belongs to a pipeline, so it does not run one for you.
- **You want the mechanical checks.** `terraform fmt`, `tflint`, `checkov` and `tfsec` are
  the `terraform` detector in `code-review-core`. Run the scan; do not reimplement it.
- **You need secret-storage conventions.** Those are `dev-standards` →
  `secrets-management`.
- **You are sequencing a database schema change.** That is `dev-standards` →
  `database-migrations`; RDS-specific plan review (blue/green, maintenance windows) stays in
  `terraform-review`.
- **You are on another cloud, or another IaC tool.**

## Prerequisites

For running commands (Claude Code only): a Terraform CLI on PATH and an AWS identity you
can already use. Confirm both before reading any output as meaningful:

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

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `terraform-standards` | Skill | Module layout, typed variables and outputs, S3 backend configuration with locking, directory-per-environment over workspaces, provider pinning, and the fmt/init/validate/plan order | both |
| `aws-iam-boundaries` | Skill | Least-privilege role design, assume-role chains, OIDC trust policies for GitHub and GitLab, permission boundaries versus SCPs, RCPs and session policies, and triaging policy wildcards | both |
| `terraform-review` | Skill | Reading a plan (pasted, or `terraform show -json`) for blast radius, destructive replacement and orphaned state — explicitly excluding what the `terraform` detector already catches | both |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**Without a shell or credentials, paste the input.** The commands the skills describe — `terraform
plan`, `aws sts get-caller-identity`, a policy simulation — need a shell and live credentials.
Cowork and claude.ai have no shell, and Claude Code on the web has credentials only if its
environment provides them. Without them, paste the HCL, policy JSON or plan output
(`terraform show -json tfplan` is best) and the skill reviews that, listing the commands for
you to run instead of reporting them as done.

## Layout

```
terraform-aws/
├── .claude-plugin/plugin.json                 # manifest (name, version, description, dependencies)
├── skills/
│   ├── terraform-standards/
│   │   ├── SKILL.md                           # modules, state, environments, pinning, plan discipline
│   │   └── references/versions.md             # version floors; verify against current docs
│   ├── aws-iam-boundaries/
│   │   ├── SKILL.md                           # roles, assume-role chains, OIDC, boundaries, wildcards
│   │   └── references/oidc-claims.md          # OIDC sub/aud claim shapes
│   └── terraform-review/SKILL.md              # blast radius, replacement, state orphaning
└── README.md
```

## Dependencies

- `dev-standards` — the vendor-neutral engineering standards these skills sit on top of,
  in particular `secrets-management` for credential paths and `database-migrations` for
  schema changes.

Complementary, not required: `code-review-core`, whose `terraform` detector owns every
mechanical check this plugin refuses to duplicate.

## License

MIT
