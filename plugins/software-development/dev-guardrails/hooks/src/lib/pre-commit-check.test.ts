import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseHookIds,
  parseCannotFailHooks,
  parsePrePushHookIds,
} from './pre-commit-check.ts';

describe('parseHookIds', () => {
  it('collects active hook ids', () => {
    const cfg = `repos:
  - repo: https://example.com/hooks
    rev: v1.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
`;
    assert.deepEqual([...parseHookIds(cfg)], ['trailing-whitespace', 'end-of-file-fixer']);
  });

  // A commented-out hook is a hook that does not run. Counting it as present is how a config
  // passes a check while enforcing nothing.
  it('ignores a commented-out hook', () => {
    const cfg = `repos:
  - repo: https://example.com/hooks
    hooks:
      - id: gitleaks
      # - id: detect-private-key
`;
    assert.deepEqual([...parseHookIds(cfg)], ['gitleaks']);
  });
});

describe('parseCannotFailHooks', () => {
  it('flags an entry ending in || true', () => {
    const cfg = `repos:
  - repo: local
    hooks:
      - id: scan
        entry: sh -c 'scanner --exit-code 1 . || true'
`;
    assert.deepEqual(parseCannotFailHooks(cfg), ['scan']);
  });

  // The subtler and worse shape: `(A && B) || C`. A tool that RUNS and FINDS something takes the
  // `||` branch, prints "not installed", and exits 0 — a found secret reported as a missing tool.
  it('flags the (A && B) || echo shape', () => {
    const cfg = `repos:
  - repo: local
    hooks:
      - id: secret-scan
        entry: sh -c 'command -v scanner >/dev/null && scanner --exit-code 1 . || echo "not installed"'
`;
    assert.deepEqual(parseCannotFailHooks(cfg), ['secret-scan']);
  });

  it('flags || exit 0', () => {
    const cfg = `repos:
  - repo: local
    hooks:
      - id: lint
        entry: sh -c 'linter . || exit 0'
`;
    assert.deepEqual(parseCannotFailHooks(cfg), ['lint']);
  });

  it('accepts an entry that propagates its failure', () => {
    const cfg = `repos:
  - repo: local
    hooks:
      - id: lint
        entry: sh -c 'linter .'
      - id: strict
        entry: sh -c 'command -v scanner >/dev/null || exit 1; scanner .'
`;
    assert.deepEqual(parseCannotFailHooks(cfg), []);
  });

  // An upstream hook's entry is not in this file, so a `||` inside one is not ours to judge.
  it('only judges local hooks', () => {
    const cfg = `repos:
  - repo: https://example.com/hooks
    hooks:
      - id: upstream
        entry: sh -c 'thing || true'
`;
    assert.deepEqual(parseCannotFailHooks(cfg), []);
  });

  it('reads a folded entry across lines', () => {
    const cfg = `repos:
  - repo: local
    hooks:
      - id: folded
        entry: >
          sh -c 'scanner .
          || true'
`;
    assert.deepEqual(parseCannotFailHooks(cfg), ['folded']);
  });
});

describe('parsePrePushHookIds', () => {
  it('finds hooks declared for the pre-push stage', () => {
    const cfg = `repos:
  - repo: local
    hooks:
      - id: slow-test
        entry: pytest
        stages: [pre-push]
      - id: fast-lint
        entry: ruff
`;
    assert.deepEqual([...parsePrePushHookIds(cfg)], ['slow-test']);
  });

  it('accepts the older `push` spelling', () => {
    const cfg = `repos:
  - repo: local
    hooks:
      - id: legacy
        stages: [push]
`;
    assert.deepEqual([...parsePrePushHookIds(cfg)], ['legacy']);
  });

  it('finds none when the config declares none', () => {
    const cfg = `repos:
  - repo: local
    hooks:
      - id: fast-lint
        entry: ruff
`;
    assert.equal(parsePrePushHookIds(cfg).size, 0);
  });
});
