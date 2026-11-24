// ESLint flat config — plan item 5.10 (S11 فاحص الأسلوب): P0 style-lint gate, zero errors.
//
// Scope: app source, tests, root configs and scripts. Excluded on purpose:
//  - supabase/functions: Deno edge functions, covered by the `edge` gate (tsc Deno shim)
//  - bridge: standalone Node program with its own package.json and its own gate (scripts/bridge/check.sh)
//  - android: Java sources
//
// Rule-tuning notes (no source files were edited; this package is not allowed to):
//  - `no-unused-vars` ignores the `_`-prefix convention used throughout the codebase.
//  - `no-irregular-whitespace` skips regexes/templates: Arabic text handling deliberately
//    matches NBSP (\u00A0) inside character classes (src/demo/bank.ts).
//  - `no-control-regex` is off for src/lib/xlsx.ts only: those regexes deliberately strip
//    control characters when sanitizing Excel export values.
//  - Per-file downgrades to `warn` (visible in gate output, not hidden) for pre-existing
//    violations in files outside this package's allowed edit list:
//      src/pages/admin/AdminReview.tsx  one `Record<string, any>` without an inline disable
//      src/demo/knowledge.ts            one unnecessary `\-` escape inside a regex class
//  - react-hooks applies to React code only (src/**): tests/e2e uses Playwright's `use()`
//    fixture callback, which is not a React hook and false-positives rules-of-hooks.

import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';

export default tseslint.config(
  {
    ignores: [
      'node_modules/**',
      'dist/**',
      'dist-demo/**',
      'coverage/**',
      'verify-results/**',
      'playwright-report/**',
      'test-results/**',
      'public/**',
      'android/**',
      'bridge/**',
      'supabase/functions/**',
      'supabase/.branches/**',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    // Shared tuning for every linted file.
    rules: {
      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
          destructuredArrayIgnorePattern: '^_',
        },
      ],
      'no-irregular-whitespace': [
        'error',
        { skipStrings: true, skipTemplates: true, skipRegExps: true, skipJSXText: true },
      ],
    },
  },
  {
    // React app source.
    files: ['src/**/*.{ts,tsx}'],
    languageOptions: { globals: globals.browser },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': ['warn', { allowConstantExport: true }],
    },
  },
  {
    // Node tooling: scripts, root configs, this file.
    files: [
      'scripts/**/*.mjs',
      'tests/**/*.mjs',
      'eslint.config.js',
      '*.config.{js,ts}',
      'vite.config.ts',
      'vitest.config.ts',
      'playwright.config.ts',
      'playwright.staging.config.ts',
    ],
    languageOptions: { globals: globals.node },
  },
  {
    // Tests: Node context; `any` is idiomatic in fixtures/mocks.
    files: ['tests/**/*.{ts,tsx}'],
    languageOptions: { globals: globals.node },
    rules: {
      // Fixtures and mocks lean on `any` (the existing test suite carries blanket
      // inline disables for it); off here keeps the gate output readable.
      '@typescript-eslint/no-explicit-any': 'off',
    },
  },
  {
    // Pre-existing violations in files this work package may not edit (see header notes).
    files: ['src/pages/admin/AdminReview.tsx'],
    rules: { '@typescript-eslint/no-explicit-any': 'warn' },
  },
  {
    files: ['src/demo/knowledge.ts'],
    rules: { 'no-useless-escape': 'warn' },
  },
  {
    // Deliberate control-character stripping: Excel export sanitization (xlsx.ts)
    // and ANSI escape stripping when redacting logs (redact.mjs).
    files: ['src/lib/xlsx.ts', 'scripts/lib/redact.mjs'],
    rules: { 'no-control-regex': 'off' },
  },
  {
    // Pre-existing defect outside this package's allowed edit list: unused import.
    files: ['scripts/check-change.mjs'],
    rules: { '@typescript-eslint/no-unused-vars': 'warn' },
  },
);
