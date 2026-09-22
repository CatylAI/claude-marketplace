#!/usr/bin/env bash
# deps.sh — unpinned and loosely-pinned dependencies in changed manifest files.
#
# This detector exists instead of a `dependency-versions` standards document. Whether a dependency
# is pinned is decidable by reading the manifest: there is no judgement in it, no context to weigh,
# and nothing an LLM knows that a regex does not. SKILL.md's principle applies directly — "a linter
# beats an LLM at grep-shaped detection and costs nothing per run" — so the rule lives in the
# deterministic stage, where it runs on every change whether or not anyone remembered the document.
#
# There is no off-the-shelf tool for this. `npm outdated` needs a registry and answers a different
# question; Dependabot is a hosted service and this pipeline talks to no hosting provider; `pip-audit`
# and `trivy` look for KNOWN VULNERABILITIES, which is the other half of supply-chain risk and not
# this one. So this is implemented the way impact.sh is — our own logic, bounded, with the reasoning
# at the call site.
#
# THE RULE THAT MATTERS MOST is `uses: <action>@<tag>` in a GitHub Actions workflow, and it is the
# one with a real exploit path rather than a reproducibility argument. A tag is a mutable pointer in
# someone else's repository; whoever holds write access there can move it at any time, and your next
# run then executes code you never reviewed, in a job that holds your secrets. That rule is stated
# in `github-workflow/skills/actions-authoring` ("Pin third-party actions to a full commit SHA"),
# and this detector is written to agree with it clause for clause, including its two documented
# exemptions: a local action referenced by path, and a reusable workflow, which that skill pins "to
# a tag or SHA". Two parts of the repo disagreeing about one rule is worse than neither existing.
#
# SEVERITY IS NOT UNIFORM, on purpose. A detector whose findings are all one tier gets muted
# wholesale. The ladder used here, against `code-review-standards`:
#
#   MAJOR   mutable remote code: an unpinned Action, a `:latest`/untagged base image, an editable
#           VCS install or an npm git dependency on a branch. These execute bytes nobody reviewed.
#   MINOR   works, violates the standard, should be fixed: an unpinned requirements.txt line, a
#           caret range on a RUNTIME npm dependency with no lockfile beside it, a pre-commit `rev:`
#           on a branch, a dependency declared with no version constraint at all.
#   NIT     contested or already mitigated: a caret range on a devDependency, any caret range in a
#           package.json that has a lockfile next to it, a `>=` with no upper bound in pyproject
#           (upper-bounding is actively argued against for libraries, so this is a lead, not a fault).
#
# Detector contract: see _lib.sh. Always exits 0.

set -uo pipefail

LIST="${1:?changed-files list required}"
OUT="${2:?outdir required}"
RAW="$OUT/raw"
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib.sh"

mkdir -p "$RAW"

SRC="$RAW/.deps-files"
: > "$SRC"

# Manifest selection by PATH SHAPE, not extension: `package.json` is a manifest and `tsconfig.json`
# is not, and no extension filter can tell them apart. Generated trees are excluded here as well as
# in review-scan.sh, because a detector may be invoked directly (prepare-context.sh --skip-scan, or
# a human debugging) and `node_modules/**/package.json` would otherwise be thousands of findings.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  case "$f" in
    node_modules/*|*/node_modules/*|vendor/*|*/vendor/*|dist/*|*/dist/*|build/*|*/build/*) continue ;;
  esac
  case "$f" in
    package.json|*/package.json) ;;
    requirements.txt|*/requirements.txt|requirements-*.txt|*/requirements-*.txt) ;;
    pyproject.toml|*/pyproject.toml) ;;
    Dockerfile|*/Dockerfile|Dockerfile.*|*/Dockerfile.*|*.Dockerfile) ;;
    .github/workflows/*.yml|.github/workflows/*.yaml) ;;
    */.github/workflows/*.yml|*/.github/workflows/*.yaml) ;;
    .pre-commit-config.yaml|*/.pre-commit-config.yaml) ;;
    .pre-commit-config.yml|*/.pre-commit-config.yml) ;;
    *) continue ;;
  esac
  printf '%s\n' "$f" >> "$SRC"
done < "$LIST"

if ! any_lines "$SRC"; then
  skip "deps" "no dependency manifest in the diff (package.json, requirements*.txt, pyproject.toml, Dockerfile, .github/workflows/*, .pre-commit-config.yaml)"
  rm -f "$SRC"
  exit 0
fi

need python3 || { rm -f "$SRC"; exit 0; }

# The file list is passed through a FILE, never interpolated into the Python source, for the reason
# terraform.sh states about its fmt synthesiser: a path containing a quote would otherwise close a
# string literal and the rest of the path would be executed as code.
if ! python3 - "$SRC" "$RAW/deps.json" <<'PY'
"""Read each changed manifest, emit one finding per unpinned or loosely-pinned dependency.

Output shape (normalize.py's `p_deps` consumes it):
    {"findings": [{path, line, rule, severity, category, title, recommendation}], "notes": [...]}

The severity is decided HERE rather than in normalize.py because the rule id is what determines it,
and the rule id is only meaningful in this file. normalize.py canonicalises whatever arrives and
does not second-guess it.
"""
import json, os, re, sys

src_path, out_path = sys.argv[1], sys.argv[2]

MAJOR, MINOR, NIT = "MAJOR", "MINOR", "NIT"
SECURITY, RELIABILITY = "SECURITY", "RELIABILITY"

# A finding per dependency, capped: a package.json with 300 caret ranges is a fact about the project
# rather than a review finding, and 300 NITs would push every real finding past normalize.py's cap.
MAX_PER_FILE = 25

findings, notes = [], []


def add(path, line, rule, sev, category, title, rec):
    findings.append({
        "path": path, "line": int(line) if line else 1, "rule": rule,
        "severity": sev, "category": category, "title": title[:300],
        "recommendation": rec[:600],
    })


def read(path):
    try:
        with open(path, errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return None


SHA40 = re.compile(r"^[0-9a-f]{40}$")
ANY_SHA40 = re.compile(r"[0-9a-f]{40}")


# ---------------------------------------------------------------- GitHub Actions
# `uses: owner/repo@ref`. The ref is everything after the LAST `@`, because an action can live in a
# subdirectory (`owner/repo/path/to/action@ref`) and a container action can carry a registry host.
USES_RE = re.compile(r"""^\s*(?:-\s+)?uses\s*:\s*(["']?)([^"'#\s]+)\1""")


def scan_workflow(path, lines, budget):
    n = 0
    for i, line in enumerate(lines, 1):
        m = USES_RE.match(line)
        if not m:
            continue
        ref_str = m.group(2)
        # Exemption 1, from actions-authoring: "The only thing that does not need pinning is a local
        # action in your own repository referenced by path". It is your own repo at your own commit.
        if ref_str.startswith("./") or ref_str.startswith("../") or ref_str == ".":
            continue
        # A container action names an image, not a git ref. Its mutability is the Dockerfile rule's
        # subject, not this one, and there is no SHA to demand.
        if ref_str.startswith("docker://"):
            continue
        # An expression resolves at run time; there is no literal ref to inspect.
        if "${{" in ref_str:
            continue
        name, sep, ref = ref_str.rpartition("@")
        if not sep:
            name, ref = ref_str, ""
        # Exemption 2: actions-authoring pins a reusable-workflow caller "to a tag or SHA of the
        # reusable workflow", which is a weaker bar than it sets for an action, and this detector
        # follows the document rather than overruling it.
        if "/.github/workflows/" in name:
            continue
        if SHA40.match(ref):
            continue
        if n >= budget:
            return n
        n += 1
        what = f"the mutable tag `{ref}`" if ref else "no ref at all"
        add(path, i, "actions-unpinned-uses", MAJOR, SECURITY,
            f"`uses: {name}` is pinned to {what}, not a 40-character commit SHA",
            "A tag is a pointer in someone else's repository and can be moved to any commit by "
            "anyone with write access there, so the next run executes code nobody reviewed — with "
            "this job's secrets. Resolve the SHA for the version you reviewed "
            f"(`gh api repos/{name}/git/ref/tags/{ref or 'vX.Y.Z'} --jq '.object.sha'`) and pin to "
            "it with the version in a trailing comment. See the `actions-authoring` skill.")
    return n


# ---------------------------------------------------------------- Dockerfile
FROM_RE = re.compile(r"^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+AS\s+(\S+))?\s*$", re.I)


def image_tag(image):
    """The tag, or "" when the reference carries none. Registry ports (`host:5000/img`) are not
    tags, which is why the last `:` only counts when it falls after the last `/`."""
    slash, colon = image.rfind("/"), image.rfind(":")
    return image[colon + 1:] if colon > slash else ""


def scan_dockerfile(path, lines, budget):
    n, stages = 0, set()
    for i, line in enumerate(lines, 1):
        m = FROM_RE.match(line)
        if not m:
            continue
        image, alias = m.group(1), m.group(2)
        if alias:
            stages.add(alias.lower())
        low = image.lower()
        # `scratch` is the empty image; there is nothing to pin.
        if low == "scratch":
            continue
        # A build-arg base (`FROM $BASE_IMAGE`) is resolved at build time. Flagging it would report
        # a line that cannot carry a tag, so it is recorded as a note instead of a finding.
        if image.startswith("$") or "${" in image:
            notes.append(f"{path}:{i}: base image comes from a build argument; pinning cannot be "
                         "checked from the Dockerfile alone")
            continue
        # A reference to an earlier stage in this same file — already as pinned as its own base.
        if low in stages:
            continue
        # A digest cannot be moved, which is the strongest pin available.
        if "@sha256:" in low:
            continue
        tag = image_tag(image)
        if n >= budget:
            return n
        if not tag:
            n += 1
            add(path, i, "docker-base-untagged", MAJOR, SECURITY,
                f"`FROM {image}` has no tag, so it resolves to `:latest`",
                "An untagged base resolves to whatever `latest` points at when the image is built, "
                "so two builds of the same commit can ship different bytes and a compromised "
                "upstream tag lands in your image with no diff. Pin to a version tag, or to a "
                "`@sha256:` digest when the build must be reproducible.")
        elif tag.lower() == "latest":
            n += 1
            add(path, i, "docker-base-latest", MAJOR, SECURITY,
                f"`FROM {image}` pins the mutable `latest` tag",
                "`latest` is a pointer the publisher re-aims at every release, so the image this "
                "builds is not the image you reviewed. Pin to a version tag, or to a `@sha256:` "
                "digest when the build must be reproducible.")
    return n


# ---------------------------------------------------------------- requirements.txt
VCS_SCHEME = re.compile(r"^(git|hg|svn|bzr)\+", re.I)


def scan_requirements(path, lines, budget):
    n = 0
    for i, raw_line in enumerate(lines, 1):
        line = raw_line.split(" #", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("-"):
            opt, _, rest = line.partition(" ")
            rest = rest.strip()
            if opt in ("-e", "--editable"):
                if "://" not in rest and not VCS_SCHEME.match(rest):
                    continue                       # `-e .` — a local path, nothing remote to pin
                ref = rest.rpartition("@")[2].split("#", 1)[0]
                if SHA40.match(ref):
                    continue
                if n >= budget:
                    return n
                n += 1
                add(path, i, "python-editable-mutable-ref", MAJOR, SECURITY,
                    f"editable install from a mutable ref: `{line[:120]}`",
                    "An `-e` install from a branch (or from no ref at all) runs setup code from "
                    "whatever that name points at when the environment is built. Pin to the full "
                    "commit SHA: `-e git+https://host/org/repo@<40-char-sha>#egg=name`.")
            continue                               # -r / -c / --index-url / --hash: not requirements
        # PEP 508 direct reference: `name @ https://…`. Pinned only if the URL names a commit or a
        # hash; a bare archive URL can be republished under the same name.
        if " @ " in line or line.startswith("http"):
            if ANY_SHA40.search(line) or "sha256=" in line:
                continue
            if n >= budget:
                return n
            n += 1
            add(path, i, "python-unpinned-requirement", MINOR, RELIABILITY,
                f"direct URL requirement with no commit or hash: `{line[:120]}`",
                "Add `#sha256=…` or pin the VCS ref to a commit, so the artifact installed is the "
                "one that was reviewed.")
            continue
        if "==" in line:
            continue                               # `==` and `===` are both exact
        if n >= budget:
            return n
        n += 1
        add(path, i, "python-unpinned-requirement", MINOR, RELIABILITY,
            f"requirement is not pinned with `==`: `{line[:120]}`",
            "A requirements.txt without `==` resolves differently on every install, so the "
            "environment CI tested is not the environment that ships. Pin exactly, and generate "
            "the file from a `requirements.in` with `pip-compile` if the loose list is the one you "
            "want to maintain by hand.")
    return n


# ---------------------------------------------------------------- pyproject.toml
# Line-oriented rather than `tomllib`, which only exists on Python 3.11+ and this pipeline targets
# whatever `python3` the machine has. The shapes handled are the two that declare runtime deps:
# PEP 621 `[project] dependencies = [...]` and `[tool.poetry.dependencies]`.
PEP508 = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*(.*)$")


def spec_verdict(name, spec):
    """(rule, severity, title-fragment) for one version specifier, or None when acceptable."""
    spec = spec.split(";", 1)[0].strip()           # drop the environment marker
    if not spec or spec == "*":
        return ("python-dep-unconstrained", MINOR,
                f"`{name}` is declared with no version constraint")
    if "==" in spec or "~=" in spec or "<" in spec:
        return None                                # exact, compatible-release, or upper-bounded
    if spec.lstrip().startswith("^") or spec.lstrip().startswith("~"):
        return None                                # poetry carets/tildes carry an implicit ceiling
    if ">" in spec:
        return ("python-dep-open-upper-bound", NIT,
                f"`{name} {spec}` has a lower bound and no upper bound")
    return None


def scan_pyproject(path, lines, budget):
    n, section, in_deps = 0, "", False
    for i, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if line.startswith("["):
            section, in_deps = line.strip("[]").strip(), False
            continue
        if section == "project":
            if re.match(r"^dependencies\s*=\s*\[", line):
                in_deps = True
                line = line.split("[", 1)[1]
            elif not in_deps:
                continue
            if in_deps and "]" in line:
                in_deps = False
            for raw_dep in re.findall(r"""["']([^"']+)["']""", line):
                m = PEP508.match(raw_dep.strip())
                if not m:
                    continue
                v = spec_verdict(m.group(1), m.group(2))
                if not v or n >= budget:
                    continue
                n += 1
                rule, sev, title = v
                add(path, i, rule, sev, RELIABILITY, title,
                    "An unbounded runtime requirement means a future major release of the "
                    "dependency installs without a code change here. State the range you actually "
                    "support (`>=2.0,<3`), and keep a lock file for the versions you ship.")
            continue
        if section == "tool.poetry.dependencies":
            m = re.match(r"""^([A-Za-z0-9][A-Za-z0-9._-]*)\s*=\s*(.+)$""", line)
            if not m:
                continue
            name, value = m.group(1), m.group(2).strip()
            if name.lower() == "python":
                continue                           # the interpreter range, not a dependency
            if value.startswith("{"):
                vm = re.search(r"""version\s*=\s*["']([^"']+)["']""", value)
                if not vm:
                    continue                       # a path/git table — out of this rule's scope
                value = vm.group(1)
            else:
                value = value.strip("\"'")
            v = spec_verdict(name, value)
            if not v or n >= budget:
                continue
            n += 1
            rule, sev, title = v
            add(path, i, rule, sev, RELIABILITY, title,
                "State the range you actually support and let `poetry.lock` hold the resolved "
                "versions.")
    return n


# ---------------------------------------------------------------- package.json
LOCKFILES = ("package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml")
EXACT_VERSION = re.compile(r"^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?$")


def npm_verdict(value, runtime, locked):
    """(rule, severity, fragment) or None. `runtime` = dependencies rather than devDependencies."""
    v = value.strip()
    # A local or workspace protocol resolves inside the repo; there is no registry range to pin.
    if v.startswith(("file:", "link:", "workspace:", "portal:", "patch:")):
        return None
    if "://" in v or v.startswith("github:") or re.match(r"^[\w.-]+/[\w.-]+#", v):
        if ANY_SHA40.search(v):
            return None
        return ("npm-git-mutable-ref", MAJOR if runtime else MINOR,
                "resolves a git dependency through a branch or tag rather than a commit SHA")
    if v.startswith("npm:"):                       # `npm:@scope/pkg@1.2.3` — judge the version half
        v = v.rpartition("@")[2] or v
    if v in ("", "*", "x", "X", "latest", "next"):
        return ("npm-any-version", MAJOR if runtime else MINOR,
                f"`{value.strip() or '(empty)'}` accepts any published version, including one "
                "released after this change was reviewed")
    if EXACT_VERSION.match(v):
        return None
    # Everything left is a range of some shape — `^1.2.3`, `~1.2`, `>=1 <2`, `1.x`, `1 || 2`, or a
    # bare `4`, which npm reads as `>=4.0.0 <5.0.0`. They differ in width, not in kind.
    #
    # A lockfile is what makes `npm ci` reproducible, and a caret beside one is the npm ecosystem's
    # normal shape. Reporting that at MINOR would be a standing false alarm on almost every Node
    # repository, which is how a detector gets switched off wholesale. It stays reported — the range
    # still governs `npm install` and `npm update` — but at the tier that means "a lead, not a
    # fault". Same for a devDependency, where an unreviewed minor release reaches the build and not
    # the artifact.
    sev = MINOR if (runtime and not locked) else NIT
    return ("npm-range-loose", sev, f"`{value.strip()}` is a range, not a pinned version")


def scan_package_json(path, lines, budget):
    try:
        data = json.loads("\n".join(lines))
    except ValueError:
        notes.append(f"{path}: not parseable as JSON; dependency pinning was not checked")
        return 0
    if not isinstance(data, dict):
        return 0
    locked = any(os.path.exists(os.path.join(os.path.dirname(path) or ".", lf))
                 for lf in LOCKFILES)
    n = 0
    for section, runtime in (("dependencies", True), ("devDependencies", False)):
        block = data.get(section)
        if not isinstance(block, dict):
            continue
        for name, value in block.items():
            if not isinstance(value, str):
                continue
            v = npm_verdict(value, runtime, locked)
            if not v:
                continue
            if n >= budget:
                return n
            n += 1
            rule, sev, frag = v
            # The line number is recovered by searching the source text: json.loads discards
            # positions, and a finding at line 1 of a 200-line manifest is unlocatable and would be
            # dropped by the diff filter for the wrong reason.
            line_no = 1
            key = f'"{name}"'
            for idx, text in enumerate(lines, 1):
                if key in text and value in text:
                    line_no = idx
                    break
            rec = ("Pin to the exact version you reviewed, or keep the range and commit the "
                   "lock file so installs are reproducible.")
            if locked:
                rec = ("A lock file is present, so `npm ci` is reproducible — this range only "
                       "governs `npm install` and `npm update`. Tighten it when an unreviewed "
                       "minor release must not enter without a code change.")
            add(path, line_no, rule, sev, RELIABILITY,
                f"{section}.{name} {frag}", rec)
    return n


# ---------------------------------------------------------------- .pre-commit-config.yaml
REV_RE = re.compile(r"""^\s*rev\s*:\s*(["']?)([^"'#\s]+)\1""")


def scan_precommit(path, lines, budget):
    n = 0
    for i, line in enumerate(lines, 1):
        m = REV_RE.match(line)
        if not m:
            continue
        rev = m.group(2)
        # Deliberately conservative: only a rev with NO DIGIT ANYWHERE is reported. Every release
        # tag scheme in use carries a digit (`v4.2.2`, `24.1.0`, `2024.03`), and every commit SHA is
        # hex, so "no digit" isolates the branch names — `main`, `master`, `stable`, `HEAD` — with
        # no way to mistake a tag for one. A stricter "is this a tag or a branch" test cannot be
        # answered without the network, and guessing it would flag real tags.
        if any(c.isdigit() for c in rev):
            continue
        if n >= budget:
            return n
        n += 1
        add(path, i, "precommit-rev-mutable", MINOR, SECURITY,
            f"`rev: {rev}` tracks a branch rather than a tag or commit",
            "pre-commit clones that ref and runs its hooks on every developer's machine, so a "
            "branch means the hook code changes under you with no diff here. Pin to a release tag "
            "or a commit SHA — `pre-commit autoupdate` writes the tag for you.")
    return n


SCANNERS = (
    (lambda p: "/.github/workflows/" in "/" + p, scan_workflow),
    (lambda p: os.path.basename(p) == "package.json", scan_package_json),
    (lambda p: os.path.basename(p).startswith("requirements")
     and p.endswith(".txt"), scan_requirements),
    (lambda p: os.path.basename(p) == "pyproject.toml", scan_pyproject),
    (lambda p: os.path.basename(p).startswith("Dockerfile")
     or p.endswith(".Dockerfile"), scan_dockerfile),
    (lambda p: os.path.basename(p).startswith(".pre-commit-config."), scan_precommit),
)

for path in [l.strip() for l in open(src_path).read().splitlines() if l.strip()]:
    lines = read(path)
    if lines is None:
        continue
    for matches, scan in SCANNERS:
        if not matches(path):
            continue
        produced = scan(path, lines, MAX_PER_FILE) or 0
        if produced >= MAX_PER_FILE:
            notes.append(f"{path}: reporting stopped at {MAX_PER_FILE} findings; the file has more "
                         "unpinned entries than a review can act on one at a time")
        break

json.dump({"findings": findings, "notes": notes}, open(out_path, "w"))
print(f"{len(findings)} unpinned dependency finding(s)", file=sys.stderr)
PY
then
  skip "deps" "manifest scan failed"
  rm -f "$RAW/deps.json"
else
  note deps "ok"
fi

rm -f "$SRC" 2>/dev/null
exit 0
