// Shared relative-date resolution — used by the UserPromptSubmit hook.
// Date is intentionally used here: hooks run at request/event time, so "today" is the
// wall-clock day. The reference date is passed in so callers control it and tests stay
// deterministic; it defaults to now.

const DAY_NAMES = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

function iso(d: Date): string {
  return d.toISOString().split('T')[0];
}

/**
 * Resolve a relative-date expression (e.g. "today", "eow", "next monday") to an ISO
 * YYYY-MM-DD string, or null if the expression is not recognized.
 *
 * Recognizes: today, tomorrow, yesterday, eow/end of week, eom/end of month,
 * next week, last week, "next <weekday>", "this <weekday>", and bare weekday names.
 */
export function resolveDateExpr(expr: string, today: Date = new Date()): string | null {
  const low = expr.toLowerCase().trim();
  const dow = today.getDay();

  if (low === 'today') return iso(today);
  if (low === 'tomorrow') { const d = new Date(today); d.setDate(d.getDate() + 1); return iso(d); }
  if (low === 'yesterday') { const d = new Date(today); d.setDate(d.getDate() - 1); return iso(d); }
  if (low === 'eow' || low === 'end of week' || low === 'end-of-week') {
    const d = new Date(today); d.setDate(d.getDate() + (5 - dow + 7) % 7); return iso(d);
  }
  if (low === 'eom' || low === 'end of month') {
    return iso(new Date(today.getFullYear(), today.getMonth() + 1, 0));
  }
  if (low === 'next week') { const d = new Date(today); d.setDate(d.getDate() + 7); return iso(d); }
  if (low === 'last week') { const d = new Date(today); d.setDate(d.getDate() - 7); return iso(d); }

  // "next <weekday>" or bare weekday name → next occurrence (never today)
  const nextMatch = low.match(/^(?:next\s+)?(\w+day)$/);
  if (nextMatch) {
    const idx = DAY_NAMES.indexOf(nextMatch[1]);
    if (idx !== -1) {
      const diff = ((idx - dow) + 7) % 7 || 7;
      const d = new Date(today); d.setDate(d.getDate() + diff); return iso(d);
    }
  }

  // "this <weekday>" → this week's occurrence (may be today)
  const thisMatch = low.match(/^this\s+(\w+day)$/);
  if (thisMatch) {
    const idx = DAY_NAMES.indexOf(thisMatch[1]);
    if (idx !== -1) {
      const diff = ((idx - dow) + 7) % 7;
      const d = new Date(today); d.setDate(d.getDate() + diff); return iso(d);
    }
  }

  return null;
}

export function todayISO(today: Date = new Date()): string {
  return iso(today);
}
