#!/usr/bin/env node
// npx tinyfactory <name>: makes the folder <name> here and runs the whole bootstrap in it.
// Every step of the bootstrap is safe to run again, so the same command carries on after a
// failure is fixed: that is why a folder that already exists is not an error.

import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const name = process.argv[2];

// The name becomes a folder, a GitHub repository and a Vercel project, and all three take this form.
if (!name || !/^[a-z0-9][a-z0-9-]*$/.test(name)) {
  console.error(
    'usage: npx tinyfactory <name>\n\n' +
      '<name> is the new project: its folder here, its GitHub repository and its Vercel project.\n' +
      'Use lower-case letters, digits and hyphens, for example: npx tinyfactory my-idea',
  );
  process.exit(2);
}

const bootstrap = join(
  dirname(fileURLToPath(import.meta.url)),
  '../.claude/skills/bootstrap/scripts/bootstrap.sh',
);

mkdirSync(name, { recursive: true });
const { status, error } = spawnSync('bash', [bootstrap, name], { cwd: name, stdio: 'inherit' });
if (error) {
  console.error(`tinyfactory could not start bash: ${error.message}`);
  process.exit(1);
}
process.exit(status ?? 1);
