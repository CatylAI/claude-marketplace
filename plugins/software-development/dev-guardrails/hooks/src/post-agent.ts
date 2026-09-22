// Pre/PostToolUse hook (Agent): track what the subagents are doing and how long they have been
// doing it. Non-blocking — always exits 0.
//
// BOTH EVENTS ARE REQUIRED, and that is the whole design. PreToolUse opens a `running` entry with
// a real `started_at`; PostToolUse closes it. Wire up only the Post event and every entry has
// `started_at === completed_at`, so every duration reads as zero and stuck detection can never
// fire — the machinery is present and dead. Register both, or neither.
//
// STATE LIVES IN THIS PLUGIN'S SCRATCH DIRECTORY (lib/state-dir.ts), not in the repository.
// An observability file is not the working tree's business: a hook that drops `progress.json` and
// `STATUS.md` into whatever directory the session started in pollutes `git status`, and sooner or
// later somebody commits it.

import type { HookInput } from './lib/types.ts';
import { readStdin } from './lib/stdin.ts';
import { info } from './lib/output.ts';
import { stateFile } from './lib/state-dir.ts';
import { readFileSync, writeFileSync, existsSync, renameSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PROGRESS_FILE = stateFile('agent-progress.json');
const STATUS_FILE = stateFile('agent-status.md');

const PROGRESS_INTERVAL_MS = 5 * 60 * 1000;
const STUCK_THRESHOLD_MS = 20 * 60 * 1000;
const MAX_PARALLEL_AGENTS = 4;

interface AgentEntry {
  task: string;
  agent_type: string;
  status: 'running' | 'completed' | 'failed';
  started_at: string;
  completed_at: string | null;
  error: string | null;
  output_file?: string;
}

interface Progress {
  session_id: string | null;
  started_at: string | null;
  last_update: string | null;
  last_report_at: string | null;
  agents: Record<string, AgentEntry>;
  config: {
    max_parallel: number;
    progress_interval_sec: number;
    stuck_threshold_sec: number;
  };
}

function loadProgress(): Progress {
  try {
    if (PROGRESS_FILE && existsSync(PROGRESS_FILE)) {
      return JSON.parse(readFileSync(PROGRESS_FILE, 'utf8')) as Progress;
    }
  } catch { /* start fresh */ }

  return {
    session_id: null,
    started_at: null,
    last_update: null,
    last_report_at: null,
    agents: {},
    config: {
      max_parallel: MAX_PARALLEL_AGENTS,
      progress_interval_sec: PROGRESS_INTERVAL_MS / 1000,
      stuck_threshold_sec: STUCK_THRESHOLD_MS / 1000,
    },
  };
}

// Best-effort, deliberately un-serialized. The write itself is atomic (tmp + rename), but the
// surrounding load→modify→save is NOT locked, so two Pre hooks firing within the same tick can
// both read the old file and the later write clobbers the earlier `running` entry. That is
// accepted: this progress file is observability-only, the hook always exits 0 and never blocks
// Claude, and the state self-heals on the next event. A flock would add IO+failure surface to a
// non-load-bearing feature — not worth it.
function saveProgress(progress: Progress): void {
  if (!PROGRESS_FILE) return;
  try {
    const tmp = PROGRESS_FILE + '.tmp';
    writeFileSync(tmp, JSON.stringify(progress, null, 2));
    renameSync(tmp, PROGRESS_FILE);
  } catch {
    /* best-effort: this file is observability, never correctness */
  }
}

function formatDuration(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  if (hours > 0) return `${hours}h ${minutes % 60}m`;
  if (minutes > 0) return `${minutes}m ${seconds % 60}s`;
  return `${seconds}s`;
}

function updateStatusFile(progress: Progress): void {
  if (!STATUS_FILE) return;

  const agents = Object.entries(progress.agents);
  if (agents.length === 0) return;

  const now = Date.now();
  const stuckAgents: Array<{ id: string; task: string; elapsed: number }> = [];

  let table = '| ID | Task | Status | Duration | Output |\n';
  table += '|----|------|--------|----------|--------|\n';

  for (const [id, agent] of agents) {
    const started = new Date(agent.started_at).getTime();
    let status = 'Pending';
    let duration = '-';
    let output = '-';

    if (agent.status === 'completed') {
      status = 'Complete';
      duration = formatDuration(new Date(agent.completed_at!).getTime() - started);
      output = agent.output_file || `SUMMARY-${id}.md`;
    } else if (agent.status === 'running') {
      const elapsed = now - started;
      duration = formatDuration(elapsed);
      if (elapsed > STUCK_THRESHOLD_MS) {
        status = 'STUCK';
        stuckAgents.push({ id, task: agent.task, elapsed });
      } else {
        status = 'Running';
      }
    } else if (agent.status === 'failed') {
      status = 'Failed';
      duration = agent.error || 'Unknown error';
    }

    table += `| ${id} | ${(agent.task || '').substring(0, 40)} | ${status} | ${duration} | ${output} |\n`;
  }

  const completed = agents.filter(([, a]) => a.status === 'completed').length;
  const running = agents.filter(([, a]) => a.status === 'running').length;
  const failed = agents.filter(([, a]) => a.status === 'failed').length;

  let overallStatus = 'IN_PROGRESS';
  if (completed === agents.length) overallStatus = 'COMPLETED';
  else if (stuckAgents.length > 0) overallStatus = 'STUCK';

  const stuckSection = stuckAgents.length > 0
    ? `## Stuck Detection\n\nThe following agents have exceeded ${STUCK_THRESHOLD_MS / 60000} minutes:\n\n${stuckAgents.map(a => `- **Agent ${a.id}**: ${a.task} (${formatDuration(a.elapsed)})`).join('\n')}\n\nConsider checking agent status or cancelling.`
    : '';

  const content = `# Subagent Status

**Started**: ${progress.started_at || 'Unknown'}
**Last Update**: ${new Date().toISOString()}
**Status**: ${overallStatus}

## Agents

${table}

## Summary
- Completed: ${completed}/${agents.length}
- Running: ${running}
- Failed: ${failed}

${stuckSection}
`;

  try {
    writeFileSync(STATUS_FILE, content);
  } catch {
    /* best-effort */
  }
}

function generateReport(progress: Progress): string | null {
  const agents = Object.entries(progress.agents);
  if (agents.length === 0) return null;

  const completed = agents.filter(([, a]) => a.status === 'completed').length;
  const running = agents.filter(([, a]) => a.status === 'running').length;
  const stuck = agents.filter(([, a]) => {
    if (a.status !== 'running') return false;
    return Date.now() - new Date(a.started_at).getTime() > STUCK_THRESHOLD_MS;
  }).length;

  let report = `\n=== Subagent Progress (${new Date().toLocaleTimeString()}) ===\n`;
  report += `Agents: ${completed}/${agents.length} complete`;
  if (running > 0) report += `, ${running} running`;
  if (stuck > 0) report += `, ${stuck} STUCK`;
  report += '\n';

  for (const [id, agent] of agents) {
    let icon = '[ ]';
    if (agent.status === 'completed') icon = '[x]';
    else if (agent.status === 'failed') icon = '[!]';
    else if (agent.status === 'running') {
      const elapsed = Date.now() - new Date(agent.started_at).getTime();
      icon = elapsed > STUCK_THRESHOLD_MS ? '[!!]' : '[~]';
    }
    report += `  ${icon} [${id}] ${agent.task}\n`;
  }

  return report;
}

// Applies one Agent hook event to the progress state. PreToolUse opens a 'running' entry;
// PostToolUse closes the matching entry (or, if no Pre was seen, records a terminal entry so
// nothing is lost). Pure over `progress` + `now`: the input is deep-cloned on entry and never
// mutated, so callers (and tests) can safely reuse the same Progress object across calls.
export function recordAgentEvent(input_progress: Progress, input: HookInput, now: string): Progress {
  const progress: Progress = structuredClone(input_progress);
  // Only an explicit PreToolUse opens a running entry; anything else (PostToolUse, or an absent
  // event name from a malformed payload) falls through to the close/terminal path. Degrading an
  // unknown event to "close-out" is deliberate — it can only ever record a completed entry, never
  // leak a phantom `running` one that would trip stuck detection.
  const isPre = input.hook_event_name === 'PreToolUse';

  if (!progress.session_id) {
    progress.session_id = input.session_id || 'unknown';
    progress.started_at = now;
  }
  progress.last_update = now;

  const toolInput = input.tool_input ?? {};
  const taskDescription = (toolInput.description as string) || 'Unknown task';
  const agentType = (toolInput.subagent_type as string) || 'general-purpose';

  const existingIds = Object.keys(progress.agents).map(Number).filter(n => !isNaN(n));
  const nextId = existingIds.length > 0 ? Math.max(...existingIds) + 1 : 1;

  if (isPre) {
    // Start-record: open a running entry so duration/stuck detection has a real started_at.
    progress.agents[String(nextId)] = {
      task: taskDescription,
      agent_type: agentType,
      status: 'running',
      started_at: now,
      completed_at: null,
      error: null,
    };
    return progress;
  }

  // PostToolUse: close out the oldest still-running entry with this description.
  let matchedId: string | null = null;
  for (const [id, agent] of Object.entries(progress.agents)) {
    if (agent.status === 'running' && agent.task === taskDescription) {
      matchedId = id;
      break;
    }
  }

  // `tool_response`, not `tool_result` — see lib/types.ts. The latter is the name of the content
  // block the model sees, and reading it yields undefined forever while looking correct.
  const toolResult = input.tool_response ?? {};

  if (matchedId) {
    progress.agents[matchedId].completed_at = now;
    if (toolResult.error) {
      progress.agents[matchedId].status = 'failed';
      progress.agents[matchedId].error = toolResult.error as string;
    } else {
      progress.agents[matchedId].status = 'completed';
    }
  } else {
    // No Pre event was recorded (e.g. hook installed mid-run) — record a terminal entry.
    progress.agents[String(nextId)] = {
      task: taskDescription,
      agent_type: agentType,
      status: toolResult.error ? 'failed' : 'completed',
      started_at: now,
      completed_at: now,
      error: (toolResult.error as string) || null,
    };
  }

  return progress;
}

// --- Main ---

async function main(): Promise<void> {
  try {
    const input = await readStdin();
    if (input.tool_name !== 'Agent') process.exit(0);

    const now = new Date().toISOString();
    const progress = recordAgentEvent(loadProgress(), input, now);

    // Decide on the interval report and stamp last_report_at BEFORE the single save, so the one
    // write on disk always carries the correct last_report_at (the old two-save path wrote a stale
    // value first, then re-wrote). updateStatusFile stays on both Pre and Post: the Pre write is
    // what surfaces a running/STUCK agent in STATUS.md while it is still executing.
    const lastReport = progress.last_report_at ? new Date(progress.last_report_at).getTime() : 0;
    let report: string | null = null;
    if (Date.now() - lastReport >= PROGRESS_INTERVAL_MS) {
      report = generateReport(progress);
      progress.last_report_at = now;
    }

    saveProgress(progress);
    updateStatusFile(progress);
    if (report) info(report);
  } catch {
    // Silent failure — never block Claude
  }

  process.exit(0);
}

// Only run when invoked directly as a hook — importing (e.g. from the test) must NOT block on
// stdin. Mirrors the guard in pre-bash.ts.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
