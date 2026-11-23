// Plan item 5.10 (S11 فاحص الأسلوب): the ESLint gate itself is tested here.
// The full-tree case is the acceptance check — zero errors on the whole repo.
// The remaining cases are positive/negative controls proving the config actually
// catches violations (a gate that reports nothing broken could just be broken itself).
import { describe, expect, it } from 'vitest';
import { ESLint } from 'eslint';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

const root = path.resolve(__dirname, '../..');

function makeLint() {
  return new ESLint({ cwd: root, overrideConfigFile: path.join(root, 'eslint.config.js') });
}

async function lintSnippet(code: string, filePath: string) {
  const [result] = await makeLint().lintText(code, { filePath: path.join(root, filePath) });
  return result.messages;
}

describe('eslint gate (5.10)', () => {
  it('the whole repository lints with zero errors', async () => {
    const results = await makeLint().lintFiles(['.']);
    const errors = results.flatMap((r) =>
      r.messages
        .filter((m) => m.severity === 2)
        .map((m) => `${path.relative(root, r.filePath)}:${m.line}:${m.column} ${m.ruleId} ${m.message}`),
    );
    expect(errors).toEqual([]);
    const warnings = ESLint.getErrorResults(results).length;
    expect(warnings).toBe(0); // no files with fatal/parse errors
  }, 120_000);

  it('package.json exposes the lint scripts and the config file exists', () => {
    const pkg = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
    expect(pkg.scripts.lint).toBe('eslint .');
    expect(pkg.scripts['lint:fix']).toBe('eslint . --fix');
    expect(existsSync(path.join(root, 'eslint.config.js'))).toBe(true);
  });

  it('catches an unused variable in app source', async () => {
    const messages = await lintSnippet('const leftover = 1;\nexport const ok = 2;\n', 'src/lib/__lint_probe__.ts');
    expect(messages.some((m) => m.ruleId === '@typescript-eslint/no-unused-vars' && m.severity === 2)).toBe(true);
  });

  it('allows the underscore-prefixed intentionally-unused convention', async () => {
    const messages = await lintSnippet('const _leftover = 1;\nexport const ok = 2;\n', 'src/lib/__lint_probe__.ts');
    expect(messages.filter((m) => m.ruleId === '@typescript-eslint/no-unused-vars')).toEqual([]);
  });

  it('catches a hook called conditionally in a component', async () => {
    const code = [
      'import { useState } from "react";',
      'export function Panel({ on }: { on: boolean }) {',
      '  if (on) { const [x] = useState(0); return <span>{x}</span>; }',
      '  return null;',
      '}',
      '',
    ].join('\n');
    const messages = await lintSnippet(code, 'src/components/__LintProbe__.tsx');
    expect(messages.some((m) => m.ruleId === 'react-hooks/rules-of-hooks' && m.severity === 2)).toBe(true);
  });

  it('catches an explicit any in app source', async () => {
    const messages = await lintSnippet('export function f(x: any) { return x; }\n', 'src/lib/__lint_probe__.ts');
    expect(messages.some((m) => m.ruleId === '@typescript-eslint/no-explicit-any' && m.severity === 2)).toBe(true);
  });

  it('ignores build output and dependency directories', async () => {
    const messages = await lintSnippet('const x: any = 1;\n', 'node_modules/__lint_probe__.ts');
    expect(messages.some((m) => m.ruleId === 'no-undef')).toBe(false);
    // lintText on an ignored path reports a single "ignored file" warning, not rule violations.
    expect(messages.filter((m) => m.ruleId === '@typescript-eslint/no-explicit-any')).toEqual([]);
  });
});
