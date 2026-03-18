#!/usr/bin/env node

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');

// ── Argument parsing ──────────────────────────────────────────────────────────
// Positional args : domain, magento-version
// Variable args   : KEY=VALUE pairs forwarded to make (e.g. PHP_VERSION=8.2)
const args        = process.argv.slice(2);
const positional  = args.filter(a => !a.includes('='));
const makeVars    = args.filter(a =>  a.includes('='));
const [domain, version] = positional;

// ── Help / usage ──────────────────────────────────────────────────────────────
if (!domain || !version || args.includes('--help') || args.includes('-h')) {
  console.log(`
  Usage:
    npx create-magento <domain> <magento-version> [KEY=VALUE ...]

  Examples:
    npx create-magento app.myshop.test 2.4.8-p3
    npx create-magento app.myshop.test 2.4.8-p3 PHP_VERSION=8.2
    npx create-magento app.myshop.test 2.4.8-p3 SAMPLE_DATA=true

  Variables:
    PHP_VERSION    PHP version inside the Warden container  (default: 8.3)
    SAMPLE_DATA    Install Magento sample data              (default: false)
  `);
  process.exit(domain && version ? 0 : 1);
}

// ── Pre-flight: require make ──────────────────────────────────────────────────
const makeCheck = spawnSync('make', ['--version'], { stdio: 'pipe' });
if (makeCheck.error) {
  console.error('\n  Error: make is not installed or not found in PATH.');
  console.error('    macOS : xcode-select --install   or   brew install make');
  console.error('    Linux : sudo apt install make    or   sudo yum install make\n');
  process.exit(1);
}

// ── Run the bundled Makefile ──────────────────────────────────────────────────
// -f points to the Makefile shipped inside this package.
// $(CURDIR) in make is the working directory of the make process, so projects
// are created relative to wherever the user runs this command — not relative
// to the package directory.
const makefilePath = path.join(__dirname, '..', 'Makefile');

const result = spawnSync(
  'make',
  ['-f', makefilePath, 'create-magento', domain, version, ...makeVars],
  { stdio: 'inherit', cwd: process.cwd() }
);

process.exit(result.status ?? 1);