// CODEOWNERS health check — is this repo's owners file capable of gating anything?
//
// A CODEOWNERS file is the only reason a review requirement is enforced rather than requested,
// and it fails silently in four shapes. Each one leaves a file that looks fine and reviews
// nothing:
//
//   1. A RULE WITH NO OWNERS. Both GitHub and GitLab read a pattern with no owner token as
//      "explicitly unowned" — the path is removed from coverage rather than left to a broader
//      rule. Writing one to "document" a path is a trap.
//   2. A SOLE INDIVIDUAL OWNER. An author cannot approve their own change: the forge removes
//      them from the eligible approvers rather than rejecting the attempt. So a rule owned by
//      exactly one person requires zero approvals on that person's own change, which is the
//      change it most needed to gate. A team handle cannot fail that way — it has members left
//      over.
//   3. A CATCH-ALL THAT SHADOWS EVERYTHING BELOW IT. Only the LAST matching pattern applies, so
//      a trailing `*` rule silently replaces every specific rule above it.
//   4. A MALFORMED OWNER TOKEN. A typo'd handle is not an error anywhere in the toolchain; it
//      resolves to nobody and the rule requires nothing.
//
// SCOPE IS TEXTUAL, deliberately. Whether a handle names a real, active account with write
// access cannot be answered without the forge API and a token, and a session-start check earns
// its place by being free. Everything detectable from the file itself is detected here;
// membership resolution is somebody else's job.
//
// OPT-IN STRICTNESS: `CLAUDE_CODEOWNERS_REQUIRED_OWNER` names a handle (e.g. `@org/platform`)
// that every rule must list. Unset — the default — that arm does not run at all, because
// demanding a specific team in a repo that has never heard of it is pure noise.

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { context } from './output.ts';

/**
 * Where the forges look for the file. First match wins here; the forges differ slightly on
 * precedence when more than one exists, and a repo with two is its own finding — reported below.
 */
export const LOCATIONS = ['CODEOWNERS', '.github/CODEOWNERS', '.gitlab/CODEOWNERS', 'docs/CODEOWNERS'];

/** `[Section]`, `^[Optional section]`, `[Section][2]` — optionally followed by default owners. */
const SECTION_RE = /^\s*\^?\[([^\]]+)\](?:\[\d+\])?\s*(.*)$/;

/** An owner token: `@user`, `@org/team`, or an email address. */
const OWNER_RE = /^(@[A-Za-z0-9][A-Za-z0-9._/-]*|[^@\s]+@[^@\s]+\.[A-Za-z]{2,})$/;

/** A token that MEANT to be an owner — starts with `@` or contains one — but is not well-formed. */
const OWNERISH_RE = /^@|@/;

export interface CodeownersRule {
  /** 1-based line number in the file. */
  line: number;
  pattern: string;
  owners: string[];
  /** The section heading this rule sits under, or null at top level. */
  section: string | null;
}

export interface CodeownersResult {
  /** No file found in any known location. Not a failure — many repos have none. */
  present: boolean;
  /** Path actually read, relative to the repo root. */
  path: string | null;
  /** More than one location carries a file — the forges disagree on which one wins. */
  duplicateLocations: string[];
  rules: CodeownersRule[];
  ownerless: CodeownersRule[];
  soleIndividualOwner: CodeownersRule[];
  malformedOwners: Array<{ line: number; owner: string }>;
  /** Rules shadowed by a later catch-all (`*`) rule in the same section. */
  shadowedByCatchAll: CodeownersRule[];
  /** Rules missing `CLAUDE_CODEOWNERS_REQUIRED_OWNER`. Empty when that is unset. */
  missingRequiredOwner: CodeownersRule[];
  /** The value of `CLAUDE_CODEOWNERS_REQUIRED_OWNER`, or null. */
  requiredOwner: string | null;
}

/** Is this token an owner reference rather than part of a path? */
function looksLikeOwner(token: string): boolean {
  return OWNERISH_RE.test(token);
}

/**
 * Parse a CODEOWNERS file. Exported so the parse is assertable on its own — the findings below
 * are only as good as this, and a parser that mis-splits a section heading invents findings.
 */
export function parseCodeowners(content: string): {
  rules: CodeownersRule[];
  sectionHeadings: string[];
} {
  const rules: CodeownersRule[] = [];
  const sectionHeadings: string[] = [];
  let section: string | null = null;
  let sectionDefaultOwners: string[] = [];

  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const lineNo = i + 1;
    // Strip trailing comments, then blank/comment lines.
    const stripped = raw.replace(/\s+#.*$/, '').trim();
    if (!stripped || stripped.startsWith('#')) continue;

    const sectionMatch = SECTION_RE.exec(stripped);
    if (sectionMatch) {
      section = sectionMatch[1].trim();
      sectionHeadings.push(section);
      // A section heading may carry default owners after the bracket group; they apply to every
      // rule in the section that names none of its own.
      sectionDefaultOwners = sectionMatch[2].trim().split(/\s+/).filter(looksLikeOwner);
      continue;
    }

    const parts = stripped.split(/\s+/);
    const pattern = parts[0];
    if (!pattern) continue;
    const owners = parts.slice(1).filter(looksLikeOwner);
    rules.push({
      line: lineNo,
      pattern,
      owners: owners.length > 0 ? owners : [...sectionDefaultOwners],
      section,
    });
  }

  return { rules, sectionHeadings };
}

/**
 * A rule owned by exactly one token that is NOT a team path. `@org/team` contains a slash and is
 * a group; `@person` does not and is (almost always) an individual. An email address is an
 * individual too.
 */
function isSoleIndividual(rule: CodeownersRule): boolean {
  if (rule.owners.length !== 1) return false;
  const only = rule.owners[0];
  if (only.startsWith('@')) return !only.includes('/');
  return true; // a bare email address
}

export function checkCodeowners(
  repoRoot: string,
  env: NodeJS.ProcessEnv = process.env,
): CodeownersResult {
  const requiredOwner = (env.CLAUDE_CODEOWNERS_REQUIRED_OWNER ?? '').trim() || null;
  const result: CodeownersResult = {
    present: false,
    path: null,
    duplicateLocations: [],
    rules: [],
    ownerless: [],
    soleIndividualOwner: [],
    malformedOwners: [],
    shadowedByCatchAll: [],
    missingRequiredOwner: [],
    requiredOwner,
  };

  const found = LOCATIONS.filter((loc) => existsSync(join(repoRoot, loc)));
  if (found.length === 0) return result;
  result.present = true;
  result.path = found[0];
  if (found.length > 1) result.duplicateLocations = found;

  let content: string;
  try {
    content = readFileSync(join(repoRoot, found[0]), 'utf-8');
  } catch {
    // Unreadable is not "clean". Report it as absent of rules rather than as a pass, and let the
    // caller's own emptiness check stay silent — there is genuinely nothing to say about a file
    // we could not open.
    return result;
  }

  const { rules } = parseCodeowners(content);
  result.rules = rules;

  for (const rule of rules) {
    if (rule.owners.length === 0) {
      result.ownerless.push(rule);
      continue;
    }
    if (isSoleIndividual(rule)) result.soleIndividualOwner.push(rule);
    for (const owner of rule.owners) {
      if (!OWNER_RE.test(owner)) result.malformedOwners.push({ line: rule.line, owner });
    }
    if (requiredOwner) {
      const lower = rule.owners.map((o) => o.toLowerCase());
      if (!lower.includes(requiredOwner.toLowerCase())) result.missingRequiredOwner.push(rule);
    }
  }

  // Shadowing: within one section, a `*` rule replaces every rule declared BEFORE it, because
  // only the last matching pattern applies.
  for (let i = 0; i < rules.length; i++) {
    const later = rules
      .slice(i + 1)
      .find((r) => r.pattern === '*' && r.section === rules[i].section);
    if (later && rules[i].pattern !== '*') result.shadowedByCatchAll.push(rules[i]);
  }

  return result;
}

/** Run the check and emit context lines. Silent on a healthy file, and on a repo with none. */
export function runCodeownersCheck(
  repoRoot: string,
  env: NodeJS.ProcessEnv = process.env,
): void {
  let result: CodeownersResult;
  try {
    result = checkCodeowners(repoRoot, env);
  } catch {
    // A throw from an unconditional session-start check would abort the hook and lose every
    // report after it. Degrade to silence instead.
    return;
  }
  if (!result.present) return;

  const issues: string[] = [];

  if (result.duplicateLocations.length > 1) {
    issues.push(
      `CODEOWNERS exists in more than one location (${result.duplicateLocations.join(', ')}). ` +
        'Only one is read, and which one depends on the forge — delete the others.',
    );
  }

  if (result.rules.length === 0) {
    issues.push(`${result.path} has no rules — it gates nothing.`);
  }

  if (result.ownerless.length > 0) {
    const shown = result.ownerless.slice(0, 5).map((r) => `${r.pattern} (line ${r.line})`);
    issues.push(
      `Rule(s) with NO owner: ${shown.join(', ')}. An empty owner list marks the path ` +
        'EXPLICITLY UNOWNED — it is removed from review coverage, not left to a broader rule.',
    );
  }

  if (result.soleIndividualOwner.length > 0) {
    const shown = result.soleIndividualOwner.slice(0, 5).map((r) => `${r.pattern} (line ${r.line})`);
    issues.push(
      `Rule(s) owned by a single individual: ${shown.join(', ')}. That person cannot approve ` +
        'their own change, so the rule requires ZERO approvals on exactly the change it was ' +
        'written to gate. Add a team handle alongside the person.',
    );
  }

  if (result.malformedOwners.length > 0) {
    const shown = result.malformedOwners.slice(0, 5).map((m) => `${m.owner} (line ${m.line})`);
    issues.push(
      `Malformed owner token(s): ${shown.join(', ')}. These resolve to nobody, and no tool in ` +
        'the chain reports it — the rule silently requires nothing.',
    );
  }

  if (result.shadowedByCatchAll.length > 0) {
    const shown = result.shadowedByCatchAll.slice(0, 5).map((r) => `${r.pattern} (line ${r.line})`);
    issues.push(
      `Rule(s) shadowed by a later \`*\` catch-all: ${shown.join(', ')}. Only the LAST matching ` +
        'pattern applies, so these have no effect. Move the catch-all to the top.',
    );
  }

  if (result.missingRequiredOwner.length > 0 && result.requiredOwner) {
    const shown = result.missingRequiredOwner.slice(0, 5).map((r) => `${r.pattern} (line ${r.line})`);
    issues.push(
      `Rule(s) not listing ${result.requiredOwner} ` +
        `(CLAUDE_CODEOWNERS_REQUIRED_OWNER): ${shown.join(', ')}.`,
    );
  }

  if (issues.length > 0) {
    context(`CODEOWNERS (${result.path}) — this file does not gate what it looks like it gates:`);
    for (const issue of issues) context(`   - ${issue}`);
  }
}
