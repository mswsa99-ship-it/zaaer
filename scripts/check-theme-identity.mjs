import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findHardcodedColors } from './lib/colorScan.mjs';

export function inventory(root) {
  const files = [];
  const walk = dir => { for (const n of readdirSync(dir)) { const p = join(dir, n); if (statSync(p).isDirectory()) walk(p); else if (/\.(tsx?|css)$/.test(p)) files.push(p); } };
  walk(join(root, 'src')); files.push(join(root, 'index.html'));
  const out = new Map();
  const add = (file, kind, match) => { const key = JSON.stringify([file, kind, match]); out.set(key, (out.get(key) || 0) + 1); };
  for (const p of files) {
    const file = relative(root, p).split('\\').join('/');
    if (['src/tokens.css', 'src/lib/designTokens.ts', 'src/themeIdentity.css'].includes(file)) continue;
    const text = readFileSync(p, 'utf8');
    // Source-only ratchet: comments may produce conservative hits. No inline opt-out markers.
    for (const h of findHardcodedColors(text.replaceAll('token-ok', 'token-review-required'), file)) add(file, 'literal', h.match);
    const utility = /(?<![\w-])(?:(?:[\w-]+):)*(?:bg|text|border|ring|from|via|to|fill|stroke)-(?:white|black|(?:ink|brand|accent|success|warning|danger|slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-(?:50|[1-9]00))(?:\/\d+)?(?![\w-])/g;
    for (const m of text.matchAll(utility)) add(file, 'legacy-utility', m[0]);
  }
  return Object.fromEntries([...out].sort(([a], [b]) => a.localeCompare(b)));
}

const root = process.argv.includes('--root') ? process.argv[process.argv.indexOf('--root') + 1] : fileURLToPath(new URL('..', import.meta.url));
const current = inventory(root);
if (process.argv.includes('--inventory')) console.log(JSON.stringify(current, null, 2));
else {
  const baseline = JSON.parse(readFileSync(join(root, 'scripts/theme-debt-baseline.json'), 'utf8'));
  const violations = Object.entries(current).filter(([k, n]) => n > (baseline.entries[k] || 0));
  if (violations.length) {
    console.error('New non-semantic theme colors are not allowed. Use shared semantic tokens.');
    for (const [k, n] of violations) console.error(k, 'count', n, 'baseline', baseline.entries[k] || 0);
    process.exitCode = 1;
  } else console.log('Theme ratchet passed. Existing migration debt is bounded; new literals and fixed-palette utilities are rejected.');
}
