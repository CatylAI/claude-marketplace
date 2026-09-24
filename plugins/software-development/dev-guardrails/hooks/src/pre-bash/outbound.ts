// Gate C: do not publish a credential through a forge CLI.
//
// TOKEN_PATTERNS only — a review note reporting "a credential is hardcoded at config.py:12"
// must be publishable, or the reviewer cannot describe what it found.
//
// Fail direction: CLOSED on a match. A published secret is irreversible (the notification
// is sent), while a false block costs a rewrite of the text.

import { parseCommand } from '../lib/bash-parse.ts';
import { findSecrets } from '../lib/secrets.ts';

// `<group> <verb>` pairs that put text somewhere other people read it.
const PUBLISHING_GROUPS = new Set(['pr', 'mr', 'issue', 'release', 'gist', 'snippet']);
const PUBLISHING_VERBS = new Set(['create', 'edit', 'update', 'comment', 'note', 'review', 'close', 'merge']);
// `gh api` / `glab api` flags that carry a request body.
const API_BODY_FLAGS = /^(-f|-F|--field|--raw-field|--input)(=|$)|^-[fF]./;

function publishes(head: string | null, argv: readonly string[]): boolean {
  if (head !== 'gh' && head !== 'glab') return false;
  const [group, verb] = argv;
  if (group === 'api') return argv.some((a) => API_BODY_FLAGS.test(a));
  return PUBLISHING_GROUPS.has(group ?? '') && PUBLISHING_VERBS.has(verb ?? '');
}

export function evaluateOutboundBash(command: string): string | null {
  const commands = parseCommand(command);
  if (!commands.some((c) => publishes(c.head, c.argv))) return null;
  // Scan the whole line (heredoc bodies included: `--body-file - <<EOF` carries text there),
  // AND the joined argv of every parsed command. A token split across adjacent quoted words —
  // `--body 'ghp_'"<rest>"` — is one value once the shell concatenates them, so it is invisible
  // in the raw line but plain in argv.
  const argvText = commands.flatMap((c) => c.argv).join(' ');
  const hits = [...findSecrets(command), ...findSecrets(argvText)];
  if (hits.length === 0) return null;

  const kinds = [...new Set(hits.map((h) => h.patternName))].sort().join(', ');
  return `❌ BLOCKED: this command would publish a credential

  Found:    ${hits.length} credential-shaped value(s) — ${kinds}
  Why:      pull-request descriptions and issue notes are durable and notify reviewers.
            Editing the note afterwards does not un-send the notification.

  Instead:  refer to the secret indirectly — "the token at op://vault/item/field".
            If you are describing a leak, name the LOCATION, not the value.
            If the credential is real and was exposed, it must be ROTATED.`;
}
