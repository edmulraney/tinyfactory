#!/usr/bin/env node
// npx tinyfactory <name>: makes the folder <name> here and runs the whole bootstrap in it.
// Every step of the bootstrap leaves alone what an earlier run finished, so the same command
// carries on after a failure is fixed: that is why a folder that already exists is not an error.
// Inside the project's own folder the command carries on there, with the name or without it.

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = basename(process.cwd());
// The scaffold copies the factory's scripts in, so a folder that holds them is a project's.
const scaffolded = existsSync('factory/scripts');
const name = process.argv[2] ?? (scaffolded ? here : undefined);

// The name becomes a folder, a GitHub repository and a Vercel project, and all three take this form.
if (!name || !/^[a-z0-9][a-z0-9-]*$/.test(name)) {
  console.error(
    'usage: npx tinyfactory <name>\n\n' +
      '<name> is the new project: its folder here, its GitHub repository and its Vercel project.\n' +
      'Use lower-case letters, digits and hyphens, for example: npx tinyfactory my-idea\n' +
      'Run it again to carry on after a failure. Inside the project folder the name can be left out.',
  );
  process.exit(2);
}

// Standing in the folder named for the project, the setup runs there and makes no folder inside it.
const inside = name === here && (scaffolded || !existsSync(name));
const folder = inside ? '.' : name;

const bootstrap = join(
  dirname(fileURLToPath(import.meta.url)),
  '../.claude/skills/bootstrap/scripts/bootstrap.sh',
);

mkdirSync(folder, { recursive: true });
const { status, error } = spawnSync('bash', [bootstrap, name], { cwd: folder, stdio: 'inherit' });
if (error) {
  console.error(`tinyfactory could not start bash: ${error.message}`);
  process.exit(1);
}
process.exit(status ?? 1);
