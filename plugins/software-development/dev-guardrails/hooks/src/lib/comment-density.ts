// Comment-density nudge — advisory only, for text Claude just wrote.
//
// IT MEASURES THE WRITTEN DELTA, NOT THE FILE. post-write-edit.ts re-reads the file from disk,
// which is right for security scanning and wrong here: a whole-file metric charges an agent for
// comments it did not write. The input is `tool_input.content` (Write) or `tool_input.new_string`
// (Edit).
//
// THE COLUMN-0 CARVE-OUT IS THE LOAD-BEARING PART. Long rationale headers explaining why a gate
// exists are good writing, and a naive ratio fires on exactly those files — so it would be
// relaxed away within a day. Two mechanisms keep them clear: the leading block of the written
// chunk is free, and a column-0 comment block whose next code line is also column 0 (a
// declaration's doc header) is free. What remains is rationale interleaved into a body, which is
// the shape the nudge actually targets.
//
// The two carve-outs are NOT redundant, and the difference is the Edit case. For a whole-file
// Write the doc-header rule alone would cover the header, since a file header is column 0 above a
// column-0 declaration. The leading-block strip is what covers an Edit whose `new_string` is a
// fragment lifted out of a function body: nothing in it is at column 0, so the doc-header rule
// cannot apply, and without the strip a legitimate long rationale would be flagged purely because
// the diff started with it.
//
// THRESHOLDS. Calibrated against a corpus of hand-written source: ratio median 0.07, p95 0.39,
// observed max 0.52; longest in-body comment run median 3, p95 16. MAX_RATIO 0.60 and MAX_RUN 25
// therefore sit above everything measured rather than at the current worst value — a threshold set
// where you already are stops being a threshold. Two things make the tight margin acceptable: this
// is ADVISORY (one stderr line, always exit 0), so a false positive costs a line and never a red
// pipeline; and it measures ONE write, so a whole-file census is a strict upper bound. If it proves
// noisy, RAISE MAX_RUN — do not add path exemptions, which is how a check stops checking the thing
// it was written for.
//
// KNOWN LIMIT: Python docstrings are not counted. Triple-quoted strings are indistinguishable from
// embedded SQL, heredocs and data fixtures without parsing, and a false positive on a query literal
// would train the nudge out faster than docstring bloat justifies. `#` comments only.

/** Minimum counted code lines before the ratio arm may fire. Small chunks are dominated by one comment. */
export const MIN_CODE_LINES = 60;

/** Counted comment lines / counted code lines above which the ratio arm fires. */
export const MAX_RATIO = 0.6;

/** Longest contiguous in-body comment run above which the run arm fires. */
export const MAX_RUN = 25;

export type CommentDensityArm = 'density' | 'run';

export interface CommentDensityFinding {
  arm: CommentDensityArm;
  commentLines: number;
  codeLines: number;
  ratio: number;
  longestRun: number;
}

const LINE_MARKERS: Record<string, string[]> = {
  ts: ['//'], tsx: ['//'], mts: ['//'], cts: ['//'],
  js: ['//'], jsx: ['//'], mjs: ['//'], cjs: ['//'],
  py: ['#'], sh: ['#'], bash: ['#'], zsh: ['#'],
  tf: ['#', '//'], tfvars: ['#', '//'],
};

// Languages with /* ... */. Terraform has it too, which is why tf/tfvars appear in both tables.
const BLOCK_LANGS = new Set(['ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs', 'tf', 'tfvars']);

/**
 * Paths whose long rationale blocks are the point rather than a defect.
 *
 * `scripts/check-*.{sh,py}` are gate scripts: their headers exist to name the defect each assertion
 * caught, so a long rationale run is the intended shape. Exempting that class by path is narrower and
 * more honest than trying to detect "rationale" heuristically. Test suites are exempt for the same
 * reason — a fixture's explanation is usually longer than the fixture.
 */
export function isCommentDensityExempt(filePath: string): boolean {
  const p = filePath.replace(/\\/g, '/');
  const base = p.slice(p.lastIndexOf('/') + 1);
  if (/\.test\.(sh|zsh|bash|py|ts|tsx|mts|cts|js|jsx|mjs|cjs)$/.test(base)) return true;
  if (/(^|\/)scripts\/check-[^/]*\.(sh|py)$/.test(p)) return true;
  return false;
}

type Kind = 'blank' | 'comment' | 'code';

interface Classified {
  kind: Kind;
  col0: boolean;
}

// Classify every line, tracking /* */ state. A line with code and a trailing comment is CODE:
// trailing why-comments are the good kind and must never count against the ratio.
function classify(lines: string[], ext: string): Classified[] {
  const markers = LINE_MARKERS[ext] ?? [];
  const hasBlocks = BLOCK_LANGS.has(ext);
  const out: Classified[] = [];
  let inBlock = false;
  let blockCol0 = false;

  for (const raw of lines) {
    const trimmed = raw.trim();

    if (inBlock) {
      const closes = hasBlocks && trimmed.includes('*/');
      const after = closes ? trimmed.slice(trimmed.indexOf('*/') + 2).trim() : '';
      out.push({ kind: 'comment', col0: blockCol0 });
      if (closes) {
        inBlock = false;
        // Code trailing the close on the same line still counts as code.
        if (after) out[out.length - 1] = { kind: 'code', col0: blockCol0 };
      }
      continue;
    }

    if (trimmed === '') {
      out.push({ kind: 'blank', col0: false });
      continue;
    }

    const col0 = raw === trimmed;

    if (hasBlocks && trimmed.startsWith('/*')) {
      const closesSameLine = trimmed.includes('*/', 2);
      const after = closesSameLine ? trimmed.slice(trimmed.indexOf('*/', 2) + 2).trim() : '';
      out.push({ kind: after ? 'code' : 'comment', col0 });
      if (!closesSameLine) {
        inBlock = true;
        blockCol0 = col0;
      }
      continue;
    }

    if (markers.some((m) => trimmed.startsWith(m))) {
      out.push({ kind: 'comment', col0 });
      continue;
    }

    out.push({ kind: 'code', col0 });
  }

  return out;
}

/**
 * Measure the comment weight of one written chunk. Returns null when the chunk is fine, the language
 * is unknown, or the path is exempt.
 */
export function analyzeCommentDensity(
  written: string,
  ext: string,
  filePath: string,
): CommentDensityFinding | null {
  if (!written) return null;
  if (isCommentDensityExempt(filePath)) return null;
  if (!(ext in LINE_MARKERS)) return null;

  let lines = written.split('\n');
  if (lines[0]?.startsWith('#!')) lines = lines.slice(1);

  const classified = classify(lines, ext);

  // The leading contiguous comment/blank block is the free header. Everything the rule asks for at the
  // top of a file lives here, so a long header can never trip either arm.
  let start = 0;
  while (start < classified.length && classified[start]!.kind !== 'code') start++;

  let commentLines = 0;
  let codeLines = 0;
  let longestRun = 0;

  let i = start;
  while (i < classified.length) {
    const c = classified[i]!;

    if (c.kind === 'code') { codeLines++; i++; continue; }
    if (c.kind === 'blank') { i++; continue; }

    // A contiguous comment block. Blanks break it, so this is one visual run.
    let end = i;
    let allCol0 = true;
    while (end < classified.length && classified[end]!.kind === 'comment') {
      if (!classified[end]!.col0) allCol0 = false;
      end++;
    }

    // A column-0 block immediately above a column-0 declaration is that declaration's doc header.
    let next = end;
    while (next < classified.length && classified[next]!.kind === 'blank') next++;
    const headsDeclaration =
      allCol0 && next < classified.length && classified[next]!.kind === 'code' && classified[next]!.col0;

    if (!headsDeclaration) {
      const run = end - i;
      commentLines += run;
      if (run > longestRun) longestRun = run;
    }

    i = end;
  }

  const ratio = codeLines > 0 ? commentLines / codeLines : 0;

  if (longestRun > MAX_RUN) {
    return { arm: 'run', commentLines, codeLines, ratio, longestRun };
  }
  if (codeLines >= MIN_CODE_LINES && ratio > MAX_RATIO) {
    return { arm: 'density', commentLines, codeLines, ratio, longestRun };
  }
  return null;
}

/**
 * The advisory message. It carries the gate-rationale carve-out so a false positive self-corrects
 * rather than needing the rule to be looked up.
 */
export function commentDensityMessage(f: CommentDensityFinding): string {
  const detail = f.arm === 'run'
    ? `a ${f.longestRun}-line comment block sits inside the body (limit ${MAX_RUN})`
    : `${f.commentLines} comment lines against ${f.codeLines} code lines, ratio ${f.ratio.toFixed(2)} (limit ${MAX_RATIO})`;
  return [
    `COMMENT DENSITY: ${detail}.`,
    '  A comment carries the WHY, not the WHAT; deep rationale goes to an ADR.',
    '  Exception: if this records why a gate/check exists or what defect it caught, keep it.',
    '  Long rationale belongs at column 0 — file top, or directly above the declaration.',
  ].join('\n');
}
