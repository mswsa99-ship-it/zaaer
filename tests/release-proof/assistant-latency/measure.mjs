#!/usr/bin/env node
// Release proof 6.12 (U5 سرعة المساعد): measures the reception assistant's answer time on the fixed 20-question
// suite (questions.json), before and after a change. Per-question timeout with a clear message; every response's
// answering model and fallback chain are recorded (llm.ts returns `model` and `fallbacks`).
//
// Model source: the model chain is the hotel's approved AI settings read by the ai-reception edge function
// (supabase/functions/ai-reception/index.ts: a simple question starts from the fastest approved model — flash-lite —
// with the full chain behind it; see the 6.12 comment there). This tool changes no model and spends nothing by
// default: without --live it validates the suite and prints the plan only.
//
// Usage:
//   node measure.mjs                      # dry run: validate questions, print what would run (no requests, no spend)
//   node measure.mjs --live --label before
//   node measure.mjs --live --label after
//   node measure.mjs --compare before.json after.json
// Env for --live: AI_RECEPTION_URL (edge function URL), HOTEL_SLUG (x-hotel-slug), GUEST_TOKEN (optional),
//   TIMEOUT_MS (default 30000), ANON_KEY (apikey header).
// Output: latency-<label>.json in the current directory + a summary table on stdout.
// Running --live hits the real endpoint and MAY SPEND AI QUOTA — run it only with the owner's permission (staging
// project only while permission is pending; see acceptance/release-proof/staging-email-sessions-1.4-1.5.md).

import { readFileSync, writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
const live = args.includes('--live');
const label = args[args.indexOf('--label') + 1] || 'run';
const compareIdx = args.indexOf('--compare');

const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 30000);

function summarize(results) {
  const ok = results.filter((r) => r.ok);
  const by = (kind) => ok.filter((r) => r.kind === kind).map((r) => r.ms);
  const stat = (arr) => arr.length ? { n: arr.length, avg: Math.round(arr.reduce((a, b) => a + b, 0) / arr.length), max: Math.max(...arr) } : { n: 0 };
  return {
    total: { n: results.length, ok: ok.length, timeouts: results.filter((r) => r.timeout).length, errors: results.filter((r) => !r.ok && !r.timeout).length },
    simple: stat(by('simple')),
    complex: stat(by('complex')),
    models: [...new Set(ok.map((r) => r.model || 'unknown'))],
  };
}

async function ask(base, headers, q) {
  const started = Date.now();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(base, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify({ message: q.text }),
      signal: ctrl.signal,
    });
    const ms = Date.now() - started;
    const body = await res.json().catch(() => ({}));
    return { id: q.id, kind: q.kind, ok: res.ok, ms, status: res.status, mode: body.mode, model: body.model, fallbacks: body.fallbacks ?? [] };
  } catch (e) {
    const ms = Date.now() - started;
    const timeout = e.name === 'AbortError';
    return { id: q.id, kind: q.kind, ok: false, ms, timeout, error: timeout ? `timeout after ${TIMEOUT_MS} ms — الحد الزمني برسالة واضحة` : String(e.message || e) };
  } finally {
    clearTimeout(timer);
  }
}

if (compareIdx >= 0) {
  const [b, a] = [args[compareIdx + 1], args[compareIdx + 2]].map((f) => JSON.parse(readFileSync(f, 'utf8')));
  console.log('id     kind     before(ms)  after(ms)   delta');
  for (const qb of b.results) {
    const qa = a.results.find((r) => r.id === qb.id) || {};
    console.log(`${qb.id}  ${qb.kind.padEnd(8)} ${String(qb.ms ?? '-').padStart(9)}  ${String(qa.ms ?? '-').padStart(9)}  ${qa.ms != null && qb.ms != null ? String(qa.ms - qb.ms).padStart(7) : '      -'}`);
  }
  console.log('\nbefore:', JSON.stringify(summarize(b.results)));
  console.log('after: ', JSON.stringify(summarize(a.results)));
  process.exit(0);
}

const suite = JSON.parse(readFileSync(new URL('./questions.json', import.meta.url)));
if (suite.questions.length !== 20 || new Set(suite.questions.map((q) => q.id)).size !== 20) {
  console.error('suite must hold exactly the fixed 20 questions'); process.exit(1);
}

if (!live) {
  console.log(`dry run — no requests, no spend. suite ${suite.suite}: ${suite.questions.length} questions, timeout ${TIMEOUT_MS} ms each.`);
  console.log('to measure (owner permission required, staging only while pending):');
  console.log('  AI_RECEPTION_URL=... HOTEL_SLUG=... ANON_KEY=... node measure.mjs --live --label before');
  process.exit(0);
}

const base = process.env.AI_RECEPTION_URL;
if (!base) { console.error('AI_RECEPTION_URL required'); process.exit(1); }
const headers = { 'x-hotel-slug': process.env.HOTEL_SLUG || '', apikey: process.env.ANON_KEY || '' };
if (process.env.GUEST_TOKEN) headers['x-guest-token'] = process.env.GUEST_TOKEN;

const results = [];
for (const q of suite.questions) {
  const r = await ask(base, headers, q);
  results.push(r);
  console.log(`${r.id} ${r.ok ? 'ok' : r.timeout ? 'TIMEOUT' : 'ERR'} ${r.ms}ms model=${r.model ?? '-'} ${r.error ?? ''}`);
}
const out = { label, at: new Date().toISOString(), timeout_ms: TIMEOUT_MS, endpoint: base.replace(/\?.*$/, ''), results };
writeFileSync(`latency-${label}.json`, JSON.stringify(out, null, 2));
console.log('\nsummary:', JSON.stringify(summarize(results)));
console.log(`wrote latency-${label}.json`);
