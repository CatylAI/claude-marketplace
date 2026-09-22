// Tests for comment-density.ts.
//
// THE FIRST TESTS ARE THE IMPORTANT ONES. A long rationale header justifying why a gate exists is
// good writing, and a density check that fires on one would be relaxed away within a day. So
// `a long file header never fires` and `a column-0 doc block above a declaration never fires` are
// not illustrations — they are the assertions that stop this nudge contradicting the code it ships
// alongside.
//
// Every threshold is pinned from BOTH sides (25 passes / 26 fires, 59 passes / 60 fires), because a
// one-sided bound is equally satisfied by a check that is simply always-off in that direction. The
// two regression fixtures at the bottom encode measured shapes that must stay silent: a 23-line
// in-body run in a parser, and a gate script whose 40-line run is the whole point of the file.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  analyzeCommentDensity,
  commentDensityMessage,
  isCommentDensityExempt,
  MAX_RATIO,
  MAX_RUN,
  MIN_CODE_LINES,
} from './comment-density.ts';

const TS = 'src/lib/subject.ts';

/** `function f() {` then `pairs` × (`commentsPer` indented comments + `codePer` indented code lines). */
function interleaved(pairs: number, commentsPer: number, codePer: number, marker = '//'): string {
  const out = ['function f() {'];
  for (let p = 0; p < pairs; p++) {
    for (let c = 0; c < commentsPer; c++) out.push(`  ${marker} why ${p}.${c}`);
    for (let c = 0; c < codePer; c++) out.push(`  const v${p}_${c} = ${c};`);
  }
  out.push('}');
  return out.join('\n');
}

/** A run of `n` indented comment lines inside a body, after real code. */
function inBodyRun(n: number, marker = '//'): string {
  const out = ['function f() {', '  const a = 1;'];
  for (let i = 0; i < n; i++) out.push(`  ${marker} rationale line ${i}`);
  out.push('  return a;', '}');
  return out.join('\n');
}

// --- the thresholds themselves ---

test('the threshold VALUES are pinned, not just the boundary logic', () => {
  // Every boundary test below reads these constants, so it adapts to a change and cannot catch one.
  // This is the assertion that makes raising MAX_RUN to 30 a deliberate, visible edit. Raising it is
  // the sanctioned response to noise (see the module header); adding path exemptions is not.
  assert.equal(MIN_CODE_LINES, 60);
  assert.equal(MAX_RATIO, 0.6);
  assert.equal(MAX_RUN, 25);
});

// --- the carve-outs that keep this nudge honest ---

test('a long column-0 file header never fires', () => {
  const header = Array.from({ length: 60 }, (_, i) => `// WHY THIS EXISTS, paragraph ${i}`).join('\n');
  const body = ['', 'export function f() {', '  return 1;', '}'].join('\n');
  assert.equal(analyzeCommentDensity(header + body, 'ts', TS), null);
});

test('an Edit fragment that OPENS with an indented rationale block never fires', () => {
  // The one fixture the leading-block strip alone can save: nothing here is at column 0, so the
  // doc-header carve-out does not apply. This is the shape of an Edit whose new_string is a fragment
  // lifted out of a function body, and it is why a legitimate long rationale added mid-body does not
  // get flagged just because the diff happens to start with it. Mutating the strip away fails HERE.
  const out: string[] = [];
  for (let i = 0; i < MAX_RUN + 10; i++) out.push(`  // why this bound is ${i} and not larger`);
  out.push('  for (const x of xs) {', '    total += x;', '  }');
  assert.equal(analyzeCommentDensity(out.join('\n'), 'ts', TS), null);
});

test('a shebang plus a long header never fires', () => {
  const header = Array.from({ length: 40 }, (_, i) => `# rationale ${i}`).join('\n');
  const src = `#!/usr/bin/env bash\n${header}\nset -uo pipefail\necho hi\n`;
  assert.equal(analyzeCommentDensity(src, 'sh', 'plugins/p/scripts/do-thing.sh'), null);
});

test('a column-0 doc block above a column-0 declaration is free even past MAX_RUN', () => {
  const doc = Array.from({ length: MAX_RUN + 10 }, (_, i) => ` * doc line ${i}`).join('\n');
  const src = ['export const A = 1;', '', '/**', doc, ' */', 'export function foo() {', '  return A;', '}'].join('\n');
  assert.equal(analyzeCommentDensity(src, 'ts', TS), null);
});

test('the same block indented inside a body DOES fire — placement is the discriminator', () => {
  const f = analyzeCommentDensity(inBodyRun(MAX_RUN + 1), 'ts', TS);
  assert.equal(f?.arm, 'run');
  assert.equal(f?.longestRun, MAX_RUN + 1);
});

test('a trailing comment on a code line never counts', () => {
  const lines = ['function f() {'];
  for (let i = 0; i < 40; i++) lines.push(`  const v${i} = ${i}; // why ${i}`);
  lines.push('}');
  assert.equal(analyzeCommentDensity(lines.join('\n'), 'ts', TS), null);
});

// --- the run arm, pinned from both sides ---

test(`an in-body run of exactly MAX_RUN (${MAX_RUN}) passes`, () => {
  assert.equal(analyzeCommentDensity(inBodyRun(MAX_RUN), 'ts', TS), null);
});

test(`an in-body run of MAX_RUN + 1 (${MAX_RUN + 1}) fires`, () => {
  assert.equal(analyzeCommentDensity(inBodyRun(MAX_RUN + 1), 'ts', TS)?.arm, 'run');
});

test('a blank line breaks the run, so two half-blocks pass', () => {
  const half = Math.ceil((MAX_RUN + 1) / 2);
  const out = ['function f() {', '  const a = 1;'];
  for (let i = 0; i < half; i++) out.push(`  // first ${i}`);
  out.push('');
  for (let i = 0; i < half; i++) out.push(`  // second ${i}`);
  out.push('  return a;', '}');
  assert.equal(analyzeCommentDensity(out.join('\n'), 'ts', TS), null);
});

// --- the density arm, pinned from both sides ---

test(`density fires at MIN_CODE_LINES (${MIN_CODE_LINES}) or more when the ratio is exceeded`, () => {
  const src = interleaved(20, 2, 3);
  const f = analyzeCommentDensity(src, 'ts', TS);
  assert.equal(f?.arm, 'density');
  assert.ok(f!.codeLines >= MIN_CODE_LINES, `codeLines ${f!.codeLines} should be >= ${MIN_CODE_LINES}`);
  assert.ok(f!.ratio > MAX_RATIO, `ratio ${f!.ratio} should exceed ${MAX_RATIO}`);
  assert.ok(f!.longestRun <= MAX_RUN, 'must be the density arm, not the run arm');
});

test('the same ratio below the code-line floor stays silent', () => {
  const src = interleaved(19, 2, 3);
  const probe = analyzeCommentDensity(src, 'ts', TS);
  assert.equal(probe, null);
});

test('a high ratio over very few lines stays silent (one comment dominates a small chunk)', () => {
  const src = ['function f() {', '  // the only thing worth saying here', '  return 1;', '}'].join('\n');
  assert.equal(analyzeCommentDensity(src, 'ts', TS), null);
});

// --- languages ---

test('python # comments are measured the same way', () => {
  assert.equal(analyzeCommentDensity(inBodyRun(MAX_RUN, '#'), 'py', 'plugins/p/pipeline/thing.py'), null);
  assert.equal(
    analyzeCommentDensity(inBodyRun(MAX_RUN + 1, '#'), 'py', 'plugins/p/pipeline/thing.py')?.arm,
    'run',
  );
});

test('shell # comments are measured the same way', () => {
  assert.equal(
    analyzeCommentDensity(inBodyRun(MAX_RUN + 1, '#'), 'sh', 'plugins/p/scripts/run.sh')?.arm,
    'run',
  );
});

test('a python docstring is not counted — the known limit, asserted so it cannot drift silently', () => {
  const doc = Array.from({ length: MAX_RUN + 10 }, (_, i) => `    prose line ${i}`).join('\n');
  const src = ['def f():', '    """', doc, '    """', '    return 1'].join('\n');
  assert.equal(analyzeCommentDensity(src, 'py', 'plugins/p/pipeline/thing.py'), null);
});

test('an unknown extension is never analyzed', () => {
  assert.equal(analyzeCommentDensity(inBodyRun(MAX_RUN + 20), 'md', 'docs/thing.md'), null);
  assert.equal(analyzeCommentDensity(inBodyRun(MAX_RUN + 20), 'json', 'a.json'), null);
});

test('empty input is never analyzed', () => {
  assert.equal(analyzeCommentDensity('', 'ts', TS), null);
});

// --- path exemptions ---

test('gate scripts and test suites are exempt by path', () => {
  assert.equal(isCommentDensityExempt('scripts/check-parity.py'), true);
  assert.equal(isCommentDensityExempt('scripts/check-hygiene.sh'), true);
  assert.equal(isCommentDensityExempt('/abs/repo/scripts/check-thing.sh'), true);
  assert.equal(isCommentDensityExempt('plugins/p/pipeline/thing.test.sh'), true);
  assert.equal(isCommentDensityExempt('src/lib/git.test.ts'), true);
  assert.equal(isCommentDensityExempt('plugins/p/pipeline/contract.py'), false);
  assert.equal(isCommentDensityExempt('src/lib/git.ts'), false);
  // A check-*.ts is NOT exempt: the exemption is the shell/python gate class under scripts/.
  assert.equal(isCommentDensityExempt('plugins/p/src/check-thing.ts'), false);
  // Nor is a check-* outside scripts/.
  assert.equal(isCommentDensityExempt('plugins/p/pipeline/check-thing.sh'), false);
});

test('an exempt path is silent even at a run that would otherwise fire', () => {
  assert.equal(analyzeCommentDensity(inBodyRun(40, '#'), 'py', 'scripts/check-parity.py'), null);
  assert.equal(analyzeCommentDensity(inBodyRun(40, '#'), 'sh', 'scripts/check-hygiene.test.sh'), null);
});

// --- regression: real measured shapes that must stay silent ---

test('regression: the 23-line in-body run measured in lib/bash-parse.ts stays silent', () => {
  assert.equal(analyzeCommentDensity(inBodyRun(23), 'ts', 'src/lib/bash-parse.ts'), null);
});

test('regression: this analyser itself does not trip its own check', () => {
  // The header is column 0 and the internal comments head column-0 declarations, which is the shape
  // the rule prescribes. If this ever fires, the carve-out has regressed.
  const self = ['// header line one', '// header line two', '', 'export const A = 1;', '', '/**', ' * doc', ' */', 'export function f() {', '  return A;', '}'].join('\n');
  assert.equal(analyzeCommentDensity(self, 'ts', TS), null);
});

// --- the message ---

test('the message names the arm and carries the gate-rationale carve-out', () => {
  const run = analyzeCommentDensity(inBodyRun(MAX_RUN + 1), 'ts', TS)!;
  const m = commentDensityMessage(run);
  assert.match(m, /COMMENT DENSITY/);
  assert.match(m, new RegExp(`${MAX_RUN + 1}-line comment block`));
  assert.match(m, /WHY, not the WHAT/);
  assert.match(m, /why a gate\/check exists/);
  assert.match(m, /column 0/);

  const density = analyzeCommentDensity(interleaved(20, 2, 3), 'ts', TS)!;
  assert.match(commentDensityMessage(density), /ratio 0\.\d\d/);
});
