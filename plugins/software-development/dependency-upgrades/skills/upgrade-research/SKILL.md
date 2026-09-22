---
name: upgrade-research
description: "Researches, for every runtime and dependency in the inventory, the current version, the latest stable release, support status and end-of-life date, known advisories, and — first and most important — the deployment ceiling that caps how far the upgrade can actually go. Prefers authoritative registry commands over web search. Use after dependency-inventory and before planning an upgrade, or whenever asked whether a runtime is still supported or what version a platform allows."
license: MIT
---

# upgrade-research

Stage 2. For each row of the inventory, establish five things. Do them in this order, because the
first one changes the meaning of all the others.

1. **The deployment ceiling** — the highest version the thing this deploys onto will accept.
2. **Current** — from the inventory's resolved column.
3. **Latest stable** — from the registry, not from memory.
4. **Support status and EOL date** — is this version still receiving security patches.
5. **Known advisories** — against the *resolved* version specifically.

## The ceiling comes first

Researching upstream before the ceiling produces a number you then have to walk back, and walking
back is where the "well, 23 is only one more than 22" reasoning creeps in. Find the ceiling first
and the research question becomes bounded: *what is the best version at or below this line*.

Where ceilings come from, by deployment target:

| Target | Ceiling source | How to find it |
| --- | --- | --- |
| Serverless functions (Lambda, Cloud Functions, Azure Functions) | The provider's supported-runtimes list, which lags upstream by months and deprecates on a published schedule | Read the provider's supported-runtimes documentation page; also read the runtime identifier already configured in the IaC (`runtime = "nodejs22.x"`) |
| Managed containers (Cloud Run, App Runner, ECS/Fargate) | Usually no language ceiling — you ship the image — but the *base image availability* is the real ceiling | Check the tag exists: `docker manifest inspect <image>:<tag>` |
| Managed Kubernetes (EKS, GKE, AKS) | Control-plane version pins the maximum kubelet, which pins node images and client-tool skew | The cluster's current and available versions, from the provider's version-support page and the cluster API |
| Terraform Cloud / Enterprise | The workspace's pinned `terraform_version` overrides `required_version` intent | The workspace settings; the MCP `get_workspace_details` tool when connected, otherwise ask |
| CI | The runner image's preinstalled toolchains, and which versions the `setup-*` actions can install | The runner image's published software manifest; the action's supported-version list |
| Organisational policy | An approved-versions list, a base-image registry that only carries certain tags, a security baseline | Ask. This one is never discoverable from the repo. |
| Downstream consumers (for a library) | The oldest runtime the library promises to support | The package's own declared `engines` / `requires-python` / `rust-version` and its documented support policy |

Read the IaC for the ceiling that is already encoded, because it is usually there:

```bash
grep -rn 'runtime\s*=\|runtime:' --include='*.tf' --include='*.yaml' --include='*.yml' .
grep -rn 'image\s*=\|image:' --include='*.tf' .
grep -rn 'version\s*=' --include='*.tf' . | grep -i 'cluster\|kubernetes\|engine'
grep -rn 'terraform_version' --include='*.tf' --include='*.hcl' .
```

**Record "no ceiling found" as an explicit finding, never as an absence.** The two are not the same:
"we checked the deployment target and it imposes no cap" is a research result; a blank cell is an
unasked question. The difference surfaces when the plan is executed and deployment rejects the
artifact. If the deployment target itself is unknown — no IaC in the repo, no obvious platform —
say that, and ask the user rather than assuming a container with no ceiling.

## Four different numbers, never conflated

For every row, these are distinct and all four can differ:

| Number | Meaning |
| --- | --- |
| **latest** | The newest published version, including prereleases, RCs, betas, and `next` tags |
| **latest stable** | The newest version the project considers production-ready — the `latest` dist-tag, the newest non-prerelease semver |
| **latest supported by our ceiling** | The highest stable version at or below the deployment ceiling |
| **latest reachable without a breaking change** | The highest version within the current major |

The recommendation is the third. The fourth is what the plan can do in one low-risk step. The first
is never a target. Reporting only one number is how a plan ends up proposing Node 24 for a Lambda
that stops at 22, or proposing a major bump described as "a minor update".

Always state which constraint bound the recommendation: *upstream* (nothing newer exists), *ceiling*
(the platform caps us here), or *breaking* (the next version is a major we are not taking yet).

## Prefer registry commands over web search

Registries are authoritative and versioned. Web pages are summaries of registries, written at some
point in the past. Use the registry for anything the registry carries.

### Node

```bash
npm view <pkg> version                 # latest stable (the `latest` dist-tag)
npm view <pkg> dist-tags --json        # latest, next, beta — shows what is prerelease
npm view <pkg> versions --json         # every published version
npm view <pkg> engines peerDependencies deprecated
npm view <pkg> time --json             # publish dates; how stale is the current pin
npm outdated                           # current vs wanted vs latest, for the whole project
npm audit --json                       # advisories against the resolved tree
```

`npm outdated` gives three columns that map to the table above: `Current` (resolved), `Wanted`
(highest within the declared constraint — reachable with no manifest edit), `Latest` (latest
stable). It is the fastest way to separate "the lockfile is stale" from "the constraint is stale".

For the Node runtime itself:

```bash
npm view node versions --json          # the `node` npm package mirrors release versions
curl -s https://nodejs.org/dist/index.json | head -c 2000   # includes `lts` field per release
```

### Python

```bash
pip index versions <pkg>               # available versions (pip >= 21.2; still marked experimental)
pip download <pkg>== 2>&1 | head -5    # fallback: the error lists available versions
python3 -m pip install '<pkg>==' 2>&1 | head -5
uv pip list --outdated                 # uv
poetry show --outdated                 # Poetry
pip-audit                              # advisories against the installed set
```

`pip index versions` is the intended command but has been flagged experimental across several pip
releases; if it is unavailable, the deliberate-bad-version trick in the second line is reliable
because the resolver error enumerates candidates.

### Go

```bash
go list -m -versions <module>              # every version the proxy knows
go list -m -u all                          # current and available upgrade per module
go list -m -u -json all                    # same, machine-readable
govulncheck ./...                          # advisories, filtered to code paths actually reachable
```

`govulncheck` is meaningfully better than a lockfile scan because it reports only vulnerabilities in
functions the binary can actually reach. A vulnerability it does not report is still present in the
dependency; it is just not reachable from this code. Say which of the two you are reporting.

### Rust

```bash
cargo search <crate> --limit 1         # latest published version
cargo outdated                         # requires cargo-outdated
cargo audit                            # requires cargo-audit; advisories from RustSec
cargo update --dry-run                 # what the resolver would move, without moving it
```

### Ruby, Java, Kotlin

```bash
gem list <gem> --remote --all          # available versions
bundle outdated                        # current vs newest
bundle audit                           # requires bundler-audit

mvn versions:display-dependency-updates
mvn versions:display-plugin-updates
./gradlew dependencyUpdates            # requires the ben-manes versions plugin
```

### Terraform

```bash
terraform providers                                  # what is required, by module
terraform init -upgrade -backend=false               # re-resolves within constraints, rewrites the lock
terraform version -json                              # CLI and provider versions in use
```

The registry API answers version questions without touching state:

```bash
curl -s https://registry.terraform.io/v1/providers/hashicorp/aws/versions | head -c 2000
curl -s https://registry.terraform.io/v1/modules/<namespace>/<name>/<provider>/versions | head -c 2000
```

When the Terraform MCP server is connected, `get_latest_provider_version`,
`get_latest_module_version`, `get_provider_details` and `get_workspace_details` answer the same
questions more directly, and `get_workspace_details` is the only way to read a Terraform Cloud
workspace's pinned CLI version without asking a human.

### Containers and GitHub releases

```bash
docker manifest inspect <image>:<tag>                       # does the tag exist; which platforms
docker manifest inspect <image>:<tag> | grep architecture   # arm64 availability is a real ceiling
gh api /repos/<owner>/<repo>/releases/latest --jq '.tag_name,.published_at'
gh api /repos/<owner>/<repo>/releases --jq '.[] | select(.prerelease==false) | .tag_name' | head -10
gh api /repos/<owner>/<repo>/tags --jq '.[].name' | head -20
```

Registries for image tags vary — Docker Hub, GHCR, ECR Public, gcr.io — and none of them has a
universal "list tags" CLI. `docker manifest inspect` answers "does this specific tag exist", which
is the question that matters when validating a proposed bump. For enumerating tags, use the
registry's own API and say which registry you queried.

## What registries do not carry — and only then, web search

Registries know versions. They do not know support policy. Use web research for exactly these:

| Question | Where to look |
| --- | --- |
| EOL date and support status of a runtime | `endoflife.date` — it carries Node, Python, Go, Ruby, Java, Terraform, Kubernetes, Debian, Ubuntu, Alpine, PostgreSQL and most base images, each with release, active-support-end and security-support-end dates. Machine-readable: `curl -s https://endoflife.date/api/nodejs.json` |
| A language's own support schedule | The project's release or downloads page — Node's release schedule, Python's developer guide "status of versions" page, Go's release policy (the two most recent majors), Rust's six-week train |
| Cloud runtime deprecation dates | The provider's runtime-support documentation, which publishes deprecation and block-creation dates per runtime identifier |
| Migration guides and breaking changes | The project's own upgrade guide and release notes for the specific major, plus its `CHANGELOG.md` and the release body on GitHub |
| Whether an advisory applies to this configuration | The advisory text itself — GHSA, CVE record, RustSec or PyPA advisory database entry |

Name the source in the output. "EOL 2026-04-30 per endoflife.date/nodejs" is checkable; "EOL next
spring, per the docs" is not.

**If web access is unavailable on this surface**, say which rows have unknown EOL status rather than
guessing from the version number. A runtime's support window is not derivable from its version.

## Output — the research table

One row per inventory row, runtimes first.

| Kind | Name | Current | Latest stable | Ceiling | Ceiling source | Recommended | Bound by | Support status | EOL | Advisories |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| runtime | node | 20.11.1 | 24.x | 22.x | Lambda supported runtimes (`nodejs22.x`) | 22.x (latest 22 patch) | ceiling | maintenance LTS | 2026-04-30 | none |
| runtime | terraform | 1.9.5 | 1.13.x | 1.9.x | TFC workspace pin | 1.9.x latest patch | ceiling | supported | — | none |
| provider | hashicorp/aws | 5.62.0 | 6.x | none found | no ceiling found — checked TFC + CI | 5.latest now, 6.x as a major step | breaking | supported | — | none |
| direct dep | express | 4.19.2 | 5.x | none found | no ceiling found | 4.latest now | breaking | v4 maintained | — | none |
| base image | node:22-alpine | sha256:abc… | 22.x-alpine current | 22 (matches runtime) | function runtime | retag and re-pin digest | ceiling | — | — | — |

Then rank the rows by the priority ladder, which is about exposure rather than distance:

1. **Out of support now** — no security patches are being issued for this version.
2. **Out of support soon** — EOL falls inside the planning horizon; state the date.
3. **Known advisory** against the resolved version.
4. **Feature-blocked** — something the team needs requires a newer version.
5. **Merely behind** — everything else, in whatever order is convenient.

A runtime three minors behind but actively supported ranks below one minor behind and out of support
next month. Rank by the ladder, never by how many versions separate current from latest.

Close with the unknowns, listed rather than omitted: rows where the ceiling was not found, rows
where EOL could not be established, and rows where the registry query failed. Hand the table to
`upgrade-plan`.
