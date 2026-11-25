// Portable repo check for the RPC adapter package. Usage: node rpc-inventory-check.mjs [dir]   (dir defaults to this file's directory)
// Independent truth: rpc-exposed-signatures.txt (exposed RPC list) and rpc-protected-skip.json (protected signatures + reasons).
// Checks: exact protected set/reasons in the SQL, inventory status of every protected row, no executable adapter (base or #variant) for a protected function,
// inventory == exposed list (no hole, extra or duplicate), total accounting, adapter rows only for exposed functions.
import fs from 'node:fs'; import path from 'node:path'; import {fileURLToPath} from 'node:url';
export function check(dir) {
  const rd = f => fs.readFileSync(path.join(dir, f), 'utf8'); const errs = [];
  const exposed = rd('rpc-exposed-signatures.txt').split('\n').map(s => s.trim()).filter(Boolean);
  const prot = JSON.parse(rd('rpc-protected-skip.json')); const sql = rd('rpc-adapters.sql'); const inv = JSON.parse(rd('rpc-inventory.json')).signatures;
  const key = (a, b) => a + '\u0000' + b;
  const sqlSkip = [...sql.matchAll(/insert into iso\.rpc_adapter_skip\(signature,reason\) values \(\$s\$([\s\S]*?)\$s\$,\$r\$([\s\S]*?)\$r\$\)/g)].map(m => key(m[1], m[2]));
  const want = prot.map(p => key(p.signature, p.reason));
  if (new Set(sqlSkip).size !== sqlSkip.length) errs.push('duplicate skip rows in SQL');
  for (const w of want) if (!sqlSkip.includes(w)) errs.push('protected row missing or reason changed in SQL: ' + w.split('\u0000')[0]);
  for (const s of sqlSkip) if (!want.includes(s)) errs.push('extra skip row in SQL: ' + s.split('\u0000')[0]);
  const bySig = new Map(); for (const i of inv) { if (bySig.has(i.signature)) errs.push('duplicate inventory signature ' + i.signature); bySig.set(i.signature, i); }
  for (const p of prot) { const i = bySig.get(p.signature); if (!i) errs.push('protected signature absent from inventory ' + p.signature); else if (i.status !== 'skipped-no-coverage-credit') errs.push('protected row reclassified: ' + p.signature + ' -> ' + i.status); else if (i.reason !== p.reason) errs.push('protected inventory reason differs: ' + p.signature); }
  const protSet = new Set(prot.map(p => p.signature));
  for (const i of inv) if (i.status === 'skipped-no-coverage-credit' && !protSet.has(i.signature)) errs.push('unprotected row marked skipped: ' + i.signature);
  const ex = new Set(exposed); if (ex.size !== exposed.length) errs.push('duplicate in exposed list');
  for (const e of ex) if (!bySig.has(e)) errs.push('inventory hole (exposed but not listed): ' + e);
  for (const s of bySig.keys()) if (!ex.has(s)) errs.push('inventory has non-exposed signature: ' + s);
  const counts = {}; for (const i of inv) counts[i.status] = (counts[i.status] || 0) + 1;
  const sum = Object.values(counts).reduce((a, b) => a + b, 0); if (sum !== exposed.length) errs.push(`status accounting ${sum} != exposed ${exposed.length}`);
  const adapters = [...sql.matchAll(/insert into iso\.rpc_adapter\(signature,[\s\S]*?values \(\$s\$([\s\S]*?)\$s\$/g)].map(m => m[1]);
  if (new Set(adapters).size !== adapters.length) errs.push('duplicate adapter signature in SQL: ' + adapters.filter((a, i) => adapters.indexOf(a) !== i).join(', '));
  for (const a of adapters) { const base = a.split('#')[0]; if (protSet.has(base)) errs.push('executable adapter overlaps a protected signature: ' + a); if (!ex.has(base)) errs.push('adapter for a non-exposed signature: ' + a); if (a.includes('#') && !bySig.has(base)) errs.push('variant without base inventory row: ' + a); }
  const baseAdapters = new Set(adapters.filter(a => !a.includes('#')));
  for (const i of inv) { const written = i.coverage === 'adapter-written'; if (written !== baseAdapters.has(i.signature)) errs.push('inventory coverage disagrees with SQL adapters: ' + i.signature); }
  return {errs, counts, total: exposed.length, protectedCount: prot.length, adapters: adapters.length};
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const r = check(process.argv[2] || path.dirname(fileURLToPath(import.meta.url)));
  if (r.errs.length) { console.error('RPC INVENTORY CHECK FAIL\n' + r.errs.join('\n')); process.exit(1); }
  console.log('RPC INVENTORY CHECK OK total=' + r.total + ' protected=' + r.protectedCount + ' adapters=' + r.adapters + ' ' + JSON.stringify(r.counts));
}
