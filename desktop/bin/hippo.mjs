#!/usr/bin/env node
// node:sqlite prints an ExperimentalWarning on first use. Silence that one warning only; every other warning still shows.
const emitWarning = process.emitWarning;
process.emitWarning = function (warning, ...rest) {
  const type = typeof rest[0] === 'string' ? rest[0] : rest[0]?.type ?? (warning instanceof Error ? warning.name : undefined);
  const text = typeof warning === 'string' ? warning : warning?.message;
  if (type === 'ExperimentalWarning' && /^SQLite is an experimental feature/.test(String(text))) return;
  return emitWarning.call(this, warning, ...rest);
};
// A dynamic import, so the line above runs before the CLI (and node:sqlite) loads.
await import('../src/cli.ts');
