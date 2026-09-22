"""skillmd.py — read `name` and `description` out of a SKILL.md, with no YAML dependency.

No shebang: imported, never executed.

This repo's Python has no requirements file, so there is no PyYAML to lean on. That is fine,
because the job is narrow: two scalar keys out of the frontmatter block, including the block and
folded scalar forms (`|`, `>`, `|-`, `>-`) that long descriptions use.

It is deliberately STRICT about the frontmatter delimiters. Malformed frontmatter is the silent
failure in skill authoring — Claude Code loads the body with empty metadata, so the slash command
still works while the description can never match anything. A skill that "works when I invoke it
but never triggers on its own" is usually this, and a harness that shrugged at it would measure a
parse error and report it as a bad description.
"""

from __future__ import annotations

from pathlib import Path

_SCALAR_INDICATORS = (">", "|", ">-", "|-", ">+", "|+")


class SkillParseError(ValueError):
    """The SKILL.md is not loadable as written. Fix the file; do not measure it."""


def parse_skill_md(skill_path) -> dict:
    """Return {"name", "description", "body", "path"} for a skill directory or a SKILL.md path."""
    path = Path(skill_path)
    if path.is_dir():
        path = path / "SKILL.md"
    if not path.is_file():
        raise SkillParseError(f"no SKILL.md at {path}")

    content = path.read_text()
    lines = content.split("\n")
    if not lines or lines[0].strip() != "---":
        raise SkillParseError(
            f"{path}: frontmatter must open with `---` on the very first line; "
            "anything before it loads the body with empty metadata"
        )

    end = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end = i
            break
    if end is None:
        raise SkillParseError(f"{path}: frontmatter is never closed with `---`")

    fields = {}
    fm = lines[1:end]
    i = 0
    while i < len(fm):
        line = fm[i]
        if not line or line[0].isspace() or ":" not in line:
            i += 1
            continue
        key, _, raw = line.partition(":")
        key, value = key.strip(), raw.strip()
        if value in _SCALAR_INDICATORS:
            gathered = []
            i += 1
            while i < len(fm) and (fm[i].startswith((" ", "\t")) or not fm[i].strip()):
                gathered.append(fm[i].strip())
                i += 1
            fields[key] = " ".join(g for g in gathered if g)
            continue
        fields[key] = value.strip('"').strip("'")
        i += 1

    name = fields.get("name", "").strip()
    description = fields.get("description", "").strip()
    if not description:
        raise SkillParseError(
            f"{path}: no `description` in frontmatter — there is nothing to measure. "
            "The description is the only thing the model reads when deciding to load a skill."
        )
    if not name:
        name = path.parent.name

    return {
        "name": name,
        "description": description,
        "body": "\n".join(lines[end + 1:]).strip(),
        "path": str(path),
    }
