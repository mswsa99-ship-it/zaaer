import { describe, it, expect } from 'vitest';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readFileSync, writeFileSync, rmSync, mkdirSync, mkdtempSync } from 'node:fs';

describe('shared theme ratchet', () => {
  it('accepts only the reviewed current baseline', () => {
    expect(execFileSync('node', ['scripts/check-theme-identity.mjs'], { encoding: 'utf8' })).toContain('passed');
  });
  it('rejects a new raw literal and a fixed white utility', () => {
    const root = mkdtempSync(join(tmpdir(), 'theme-gate-'));
    mkdirSync(join(root, 'src')); mkdirSync(join(root, 'scripts'));
    writeFileSync(join(root, 'index.html'), '');
    writeFileSync(join(root, 'scripts/theme-debt-baseline.json'), JSON.stringify({entries:{}}));
    const file = join(root, 'src/probe.tsx');
    try {
      writeFileSync(file, 'export const probe = <div className="text-white bg-[#123456]" />;');
      const result = spawnSync('node', ['scripts/check-theme-identity.mjs', '--root', root], { encoding: 'utf8' });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain('text-white');
      expect(result.stderr).toContain('#123456');
    } finally { rmSync(root, {recursive:true, force:true}); }
  });
  it('runs on both production and demo builds', () => {
    const pkg = JSON.parse(readFileSync('package.json', 'utf8'));
    expect(pkg.scripts.build).toMatch(/^npm run check:theme &&/);
    expect(pkg.scripts['build:demo']).toMatch(/^npm run check:theme &&/);
  });
});
