# Registry, EOL and advisory sources

Verify against current docs: endpoints, tool names and flags below were checked when this file was
written and can change. If one fails, record the row under **Queries failed** and try the next
source in its section instead of guessing.

Each ecosystem lists a shell command and an HTTP endpoint. The endpoints are GET requests, so they
also work with web fetch where there is no shell.

## Contents

- [Node (npm)](#node-npm)
- [Python (PyPI)](#python-pypi)
- [Go](#go)
- [Rust (crates.io)](#rust-cratesio)
- [Ruby (RubyGems)](#ruby-rubygems)
- [JVM (Maven Central)](#jvm-maven-central)
- [Terraform](#terraform)
- [Container images](#container-images)
- [GitHub Actions and release tags](#github-actions-and-release-tags)
- [Support status and EOL](#support-status-and-eol)
- [Advisories](#advisories)

## Node (npm)

| Need | Shell | HTTP |
| --- | --- | --- |
| Latest stable | `npm view <pkg> version` (the `latest` dist-tag) | `https://registry.npmjs.org/<pkg>/latest` |
| All versions, dist-tags, publish times | `npm view <pkg> versions dist-tags time --json` | `https://registry.npmjs.org/<pkg>` |
| Whole project at once | `npm outdated` | — |
| Node runtime releases, with `lts` field | — | `https://nodejs.org/dist/index.json` |

`npm outdated` columns map onto the research table: `Current` is the resolved version, `Wanted` is
the highest version the declared range allows (reachable with no manifest edit), `Latest` is the
`latest` dist-tag. It exits non-zero when anything is outdated; that is expected.

## Python (PyPI)

| Need | Shell | HTTP |
| --- | --- | --- |
| Available versions | `pip index versions <pkg>` | `https://pypi.org/pypi/<pkg>/json` (`info.version` is latest; `releases` keys list all) |
| Project-wide | `poetry show --outdated`, `uv pip list --outdated` | — |

## Go

| Need | Shell | HTTP |
| --- | --- | --- |
| Latest | `go list -m <module>@latest` | `https://proxy.golang.org/<module>/@latest` |
| All versions | `go list -m -versions <module>` | `https://proxy.golang.org/<module>/@v/list` |
| Whole module graph | `go list -m -u all` | — |

Module paths with uppercase letters are escaped in proxy URLs (`!` + lowercase letter).

## Rust (crates.io)

| Need | Shell | HTTP |
| --- | --- | --- |
| Latest | `cargo search <crate> --limit 1` | `https://crates.io/api/v1/crates/<crate>` |
| Project-wide | `cargo outdated` (third-party `cargo-outdated`, if installed) | — |

## Ruby (RubyGems)

| Need | Shell | HTTP |
| --- | --- | --- |
| Latest | `gem list <gem> --remote --exact` | `https://rubygems.org/api/v1/versions/<gem>/latest.json` |
| All versions | `gem list <gem> --remote --all --exact` | `https://rubygems.org/api/v1/versions/<gem>.json` |
| Project-wide | `bundle outdated` | — |

## JVM (Maven Central)

| Need | Shell | HTTP |
| --- | --- | --- |
| Latest and all versions | `mvn versions:display-dependency-updates` (versions-maven-plugin) | `https://repo1.maven.org/maven2/<group/as/path>/<artifact>/maven-metadata.xml` (`<release>`) |
| Gradle project-wide | `./gradlew dependencyUpdates` (ben-manes versions plugin, if applied) | — |

Maven and Gradle commands run the build's plugins; expect a permission prompt.

## Terraform

| Need | Shell | HTTP |
| --- | --- | --- |
| Provider versions | — | `https://registry.terraform.io/v1/providers/<namespace>/<type>/versions` |
| Module versions | — | `https://registry.terraform.io/v1/modules/<namespace>/<name>/<provider>/versions` |
| CLI releases | — | `https://api.github.com/repos/hashicorp/terraform/releases/latest` |

When the HashiCorp Terraform MCP server is connected, its `get_latest_provider_version` and
`get_latest_module_version` tools answer the registry questions, and `get_workspace_details` reads
an HCP Terraform workspace's settings, including its Terraform version. Without the server, ask the
user for the workspace's Terraform version.

Stay read-only here: `terraform init -upgrade` rewrites `.terraform.lock.hcl` and belongs to
`upgrade-execute`.

## Container images

- `docker manifest inspect <image>:<tag>` answers whether a tag exists and for which platforms
  (look for the `architecture` values; a missing `arm64` build is a real ceiling).
- There is no universal tag-listing CLI. Use the registry's own API (Docker Hub, GHCR, ECR Public,
  Artifact Registry) and name the registry in `Sources`.

## GitHub Actions and release tags

- `gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'`, or GET
  `https://api.github.com/repos/<owner>/<repo>/releases/latest`.
- For a SHA-pinned action, resolve the tag to its commit with
  `gh api repos/<owner>/<repo>/commits/<tag> --jq '.sha'`.

## Support status and EOL

| Source | Use |
| --- | --- |
| `https://endoflife.date/api/v1/products/<product>` | Release cycles with `isEol`, `eolFrom`, `isLts`, `isMaintained`, `latest`. Covers most languages, runtimes, distributions and databases. Product slugs are listed at `https://endoflife.date/api/v1/products` |
| The project's own release-policy page | When endoflife.date lacks the product, or to confirm a date close to today |
| The cloud provider's runtime-support page | Managed runtime deprecation dates, which differ from upstream EOL |

Cite the source in `Sources` (for example `endoflife.date/nodejs`), so the date can be checked.

## Advisories

| Ecosystem | Auditor (reads the resolved tree) |
| --- | --- |
| Node | `npm audit --json`; `pnpm audit`; `yarn npm audit` (Berry) |
| Python | `pip-audit` (if installed) |
| Go | `govulncheck ./...`: reports vulnerabilities in code the module calls; `-show verbose` adds detail |
| Rust | `cargo audit` (third-party `cargo-audit`, RustSec database) |
| Ruby | `bundle-audit check --update` (third-party `bundler-audit`) |
| Any | OSV query API, below |

```bash
curl -d '{"package":{"name":"<pkg>","ecosystem":"<ecosystem>"},"version":"<version>"}' \
  https://api.osv.dev/v1/query
```

OSV ecosystem names: `npm`, `PyPI`, `Go`, `crates.io`, `RubyGems`, `Maven` (name as
`groupId:artifactId`).

The auditors' `fix` modes change files; this stage runs only the read-only checks. OSV's query
endpoint is a POST, so without a shell mark `Advisories` as `not-checked` unless a GitHub advisory
page answers it.
