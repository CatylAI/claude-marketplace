import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { resolveDateExpr, todayISO } from './dates.ts';

// A fixed Wednesday, so every weekday assertion below is deterministic.
const WED = new Date('2026-09-23T12:00:00Z');

describe('resolveDateExpr', () => {
  it('resolves the absolute anchors', () => {
    assert.equal(resolveDateExpr('today', WED), '2026-09-23');
    assert.equal(resolveDateExpr('tomorrow', WED), '2026-09-24');
    assert.equal(resolveDateExpr('yesterday', WED), '2026-09-22');
  });

  it('is case-insensitive and tolerates surrounding whitespace', () => {
    assert.equal(resolveDateExpr('  ToDaY ', WED), '2026-09-23');
  });

  it('resolves end-of-week to the coming Friday', () => {
    for (const expr of ['eow', 'end of week', 'end-of-week']) {
      assert.equal(resolveDateExpr(expr, WED), '2026-09-25', expr);
    }
  });

  it('resolves end-of-month to the last day of the month', () => {
    assert.equal(resolveDateExpr('eom', WED), '2026-09-30');
    assert.equal(resolveDateExpr('end of month', WED), '2026-09-30');
  });

  it('resolves week offsets', () => {
    assert.equal(resolveDateExpr('next week', WED), '2026-09-30');
    assert.equal(resolveDateExpr('last week', WED), '2026-09-16');
  });

  // "next friday" and a bare "friday" both mean the NEXT occurrence — never today, which is the
  // reading that causes a missed deadline rather than an early one.
  it('resolves a weekday to its next occurrence, never today', () => {
    assert.equal(resolveDateExpr('friday', WED), '2026-09-25');
    assert.equal(resolveDateExpr('next friday', WED), '2026-09-25');
    assert.equal(resolveDateExpr('wednesday', WED), '2026-09-30', 'today must roll to next week');
  });

  it('resolves "this <weekday>" within the current week, which may be today', () => {
    assert.equal(resolveDateExpr('this wednesday', WED), '2026-09-23');
    assert.equal(resolveDateExpr('this friday', WED), '2026-09-25');
  });

  it('returns null for anything it does not recognise', () => {
    for (const expr of ['', 'soon', 'in a bit', 'next sprint', 'funday']) {
      assert.equal(resolveDateExpr(expr, WED), null, expr);
    }
  });
});

describe('todayISO', () => {
  it('formats as YYYY-MM-DD', () => {
    assert.equal(todayISO(WED), '2026-09-23');
    assert.match(todayISO(), /^\d{4}-\d{2}-\d{2}$/);
  });
});
