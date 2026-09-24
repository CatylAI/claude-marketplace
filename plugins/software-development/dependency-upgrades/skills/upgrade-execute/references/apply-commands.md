# Apply and restore commands

The plan's `Apply` field is authoritative. Use this table when the plan leaves a command to choose,
and for the restore command after a step is discarded. Each apply command writes the manifest and
regenerates the lockfile together; lockfiles are never edited by hand, because a hand-edited
lockfile describes a tree the resolver would not produce and the next install silently changes it.

| Ecosystem | Apply one change | Restore the installed tree to the committed lockfile |
| --- | --- | --- |
| npm | `npm install <pkg>@<version>` | `npm ci` |
| uv | `uv add '<pkg>==<version>'` (changes the constraint); `uv lock --upgrade-package <pkg>` (moves within the existing constraint); then `uv sync` | `uv sync --locked` |
| Poetry | `poetry add <pkg>@<constraint>` (changes the constraint); `poetry update <pkg>` (moves within it) | `poetry install` |
| pip-tools | `pip-compile --upgrade-package '<pkg>==<version>' <file>.in` | `pip-sync <file>.txt` |
| Go | `go get <module>@<version>`, then `go mod tidy` | none needed; Go builds from `go.mod` and `go.sum` |
| Cargo | `cargo update -p <crate> --precise <version>` (within the `Cargo.toml` requirement); for a new major, edit `Cargo.toml` first, then `cargo update -p <crate>` | none needed; Cargo builds from `Cargo.lock` |
| Bundler | `bundle update <gem> --conservative` (moves only the named gem, not its shared dependencies) | `bundle install` |
| Gradle, with dependency locking | edit the version in the build file, then `./gradlew dependencies --update-locks <group>:<name>` | none needed |
| Maven | edit the version in `pom.xml` | none needed |
| Terraform | edit the constraint, then `terraform init -upgrade -backend=false`, then `terraform providers lock -platform=<os_arch> ...` for every platform in use | `terraform init -backend=false` |
| Container base image | edit the tag (and digest, if pinned); confirm it exists with `docker manifest inspect <image>:<tag>` | none needed |
| CI action | edit the `uses:` ref | none needed |
| pre-commit hook | `pre-commit autoupdate --repo <repo-url>` | none needed |

Notes that change what the step does:

- `./gradlew dependencies --write-locks` re-resolves every locked configuration; use
  `--update-locks` so only the named module moves.
- `terraform init -upgrade` moves every module and provider to the newest version their constraints
  allow. Read the `.terraform.lock.hcl` diff; any provider the step does not name that moved is an
  unplanned change (see the step loop).
- Some files these steps edit are protected paths in Claude Code and always ask for approval, even
  with allow rules: `.pre-commit-config.yaml`, `gradle-wrapper.properties`, `maven-wrapper.properties`,
  `.yarnrc.yml`, and anything under `.mvn/`, `.yarn/` or `.devcontainer/`. Expect the prompt.
