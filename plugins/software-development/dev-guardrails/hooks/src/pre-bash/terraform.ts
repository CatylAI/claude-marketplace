// terraform init against a PARTIAL backend configuration.
//
// A backend block with an empty body (`backend "s3" {}`) is the partial-configuration
// pattern: the bucket, key and region are meant to come from `-backend-config`. Run init
// without it and Terraform asks for them interactively, which fails in an agent context,
// or picks up whatever ambient settings happen to be present and points at the wrong
// state. A fully-written backend block needs no flag, and no backend block at all is local
// state by design, so both are allowed: blocking them would fire on every ordinary
// Terraform project.
//
// Fail direction: OPEN. If the directory cannot be read, or holds no partial backend,
// the command is allowed. Terraform itself errors on a genuinely missing value.

import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseCommand } from '../lib/bash-parse.ts';
import { commandDir } from './config.ts';

export interface TerraformDeps {
  /** Contents of every `*.tf` file in `dir`; empty when it cannot be read. */
  readTerraformFiles: (dir: string) => string[];
}

function readTerraformFiles(dir: string): string[] {
  try {
    return readdirSync(dir)
      .filter((f) => f.endsWith('.tf'))
      .slice(0, 200) // bound the work on a pathological directory
      .map((f) => readFileSync(join(dir, f), 'utf-8'));
  } catch {
    return [];
  }
}

const PARTIAL_BACKEND = /\bbackend\s+"[^"]+"\s*\{\s*\}/;

export function evaluateTerraformBackend(
  command: string,
  cwd?: string,
  deps: TerraformDeps = { readTerraformFiles },
): string | null {
  for (const c of parseCommand(command)) {
    if (c.head !== 'terraform') continue;
    // Global options come before the subcommand: `terraform -chdir=infra init`.
    let chdir: string | null = null;
    let i = 0;
    for (; i < c.argv.length && c.argv[i]!.startsWith('-'); i++) {
      const m = c.argv[i]!.match(/^--?chdir=(.*)$/);
      if (m) chdir = m[1]!;
    }
    if (c.argv[i] !== 'init') continue;
    const args = c.argv.slice(i + 1);
    const opt = (name: string): boolean => args.some((a) => a.replace(/^--/, '-').split('=')[0] === name);
    if (opt('-help') || opt('-h')) continue;
    if (opt('-backend-config')) continue;
    // -backend=false is the sanctioned form for validate, lock-file upgrade and module-only init.
    if (args.some((a) => /^--?backend=false$/.test(a))) continue;

    const dir = commandDir(cwd, chdir === null ? c.cdArgs : [...c.cdArgs, chdir]);
    if (dir === null) continue; // `cd "$X"`: cannot read the right directory
    const files = deps.readTerraformFiles(dir ?? process.cwd());
    if (!files.some((f) => PARTIAL_BACKEND.test(f))) continue;

    return `❌ BLOCKED: terraform init on a partial backend without -backend-config

  Why:      this configuration's backend block is empty, so its settings are meant to come
            from -backend-config. Without them Terraform prompts (there is no TTY here) or
            initialises against whatever ambient settings exist — not the state every
            teammate and every CI run is using.
  Instead:  terraform init -backend-config=backends/<env>.tfbackend

            Lock-file upgrade only (no remote state needed):
              terraform init -upgrade -backend=false`;
  }
  return null;
}
