// Forge CLI policy (wrong CLI, wrong flag) and commands that need an interactive TTY.
//
// TWO separate forge checks, and only the first depends on a DECLARED forge:
//
//   1. Wrong-CLI. Blocked only when CLAUDE_FORGE names one forge. With the default
//      (`both`) neither `gh` nor `glab` is blocked — most developers have both installed
//      and legitimately use both, and a hook that refuses the user's primary CLI out of
//      the box is a hook that gets deleted on day one.
//   2. Wrong FLAG on the right CLI. `--body` is GitHub's and `--description` is GitLab's;
//      each is simply an error on the other tool, and one that surfaces late — after the
//      branch has already been pushed. This fires for whichever CLI is permitted, so it
//      still helps under the permissive default.
//
// Fail direction: decided from argv alone; nothing to fail. A block costs one retry.

import { parseCommand } from '../lib/bash-parse.ts';
import type { Forge } from './config.ts';

// Matched on the SUBCOMMAND as well as the binary, so a directory named `gh` or a
// variable assignment never counts as an invocation.
const GH_SUBCOMMANDS = new Set([
  'pr', 'issue', 'api', 'repo', 'release', 'run', 'workflow', 'auth', 'config', 'gist', 'label',
  'project', 'ssh-key', 'status', 'variable', 'secret', 'codespace', 'extension', 'gpg-key',
  'search', 'cache', 'ruleset', 'attestation',
]);
const GLAB_SUBCOMMANDS = new Set([
  'mr', 'issue', 'api', 'repo', 'release', 'ci', 'pipeline', 'auth', 'config', 'label', 'snippet',
  'variable', 'schedule', 'cluster', 'incident', 'iteration', 'token', 'user', 'alias',
  'changelog', 'ask', 'job', 'stack',
]);

function isFlag(word: string, flag: string): boolean {
  return word === flag || word.startsWith(flag + '=');
}

export function evaluateForgePolicy(command: string, forge: Forge): string | null {
  const commands = parseCommand(command);

  if (forge === 'gitlab' && commands.some((c) => c.head === 'gh' && GH_SUBCOMMANDS.has(c.argv[0] ?? ''))) {
    return `❌ BLOCKED: this project is configured for GitLab (CLAUDE_FORGE=gitlab)

  Tried:    a GitHub CLI command (gh pr / gh issue / gh api / gh repo)
  Instead:  glab mr create --description "text"   ← not --body
            glab mr list / view / merge
            glab issue create
            glab api projects/...                 ← not repos/...
            --target-branch main                  ← not --base
            --source-branch feature               ← not --head

  If this project actually uses GitHub, unset CLAUDE_FORGE or set it to \`github\`
  (\`both\` is the default and blocks neither CLI).`;
  }

  if (forge === 'github' && commands.some((c) => c.head === 'glab' && GLAB_SUBCOMMANDS.has(c.argv[0] ?? ''))) {
    return `❌ BLOCKED: this project is configured for GitHub (CLAUDE_FORGE=github)

  Tried:    a GitLab CLI command (glab mr / glab issue / glab api / glab ci)
  Instead:  gh pr create --body "text"            ← not --description
            gh pr list / view / merge
            gh issue create
            gh api repos/...                      ← not projects/...
            --base main                           ← not --target-branch
            --head feature                        ← not --source-branch

  If this project actually uses GitLab, unset CLAUDE_FORGE or set it to \`gitlab\`
  (\`both\` is the default and blocks neither CLI).`;
  }

  // Flag guidance, per command, so a compound command cannot cross-blame:
  // `gh pr create --body x && glab mr list` must not read as "glab was given --body".
  for (const c of commands) {
    if (c.head === 'glab' && forge !== 'github' && c.argv.some((w) => isFlag(w, '--body'))) {
      return `❌ BLOCKED: --body is a GitHub CLI flag; glab does not accept it

  Tried:    glab ... --body "..."
  Why:      glab spells it --description. The call fails, and for \`glab mr create\` it
            fails only after the branch has been pushed.
  Instead:  glab mr create --description "text"`;
    }
    if (c.head === 'gh' && forge !== 'gitlab' && c.argv.some((w) => isFlag(w, '--description'))) {
      return `❌ BLOCKED: --description is a GitLab CLI flag; gh does not accept it

  Tried:    gh ... --description "..."
  Why:      gh spells it --body.
  Instead:  gh pr create --body "text"`;
    }
  }

  return null;
}

export function evaluateNoTty(command: string): string | null {
  for (const c of parseCommand(command)) {
    if (c.head !== 'glab') continue;
    const [group, verb] = c.argv;
    if (group === 'ci' && verb === 'view') {
      return `❌ BLOCKED: glab ci view requires an interactive TTY

  Why:      it needs a terminal and errors out in an agent context
  Instead:  glab ci status              ← pipeline status (non-interactive)
            glab ci get                 ← pipeline details
            glab ci trace <job-id>      ← stream job logs`;
    }
    if (group === 'pipeline' && verb === 'view') {
      return `❌ BLOCKED: glab pipeline view requires an interactive TTY

  Instead:  glab pipeline list          ← list pipelines (non-interactive)
            glab ci status              ← current pipeline status`;
    }
  }
  return null;
}
