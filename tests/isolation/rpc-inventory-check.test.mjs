// Negative tests for rpc-inventory-check.mjs. Usage: node rpc-inventory-check.test.mjs
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import {fileURLToPath} from 'node:url'; import {check} from './rpc-inventory-check.mjs';
const here = path.dirname(fileURLToPath(import.meta.url)); const files = ['rpc-exposed-signatures.txt', 'rpc-protected-skip.json', 'rpc-adapters.sql', 'rpc-inventory.json'];
const P = 'fn_platform_payout_confirm(p jsonb)';
function variant(mut) { const d = fs.mkdtempSync(path.join(os.tmpdir(), 'rpcchk-')); for (const f of files) fs.copyFileSync(path.join(here, f), path.join(d, f)); mut(d); const r = check(d); fs.rmSync(d, {recursive: true}); return r; }
const editInv = (d, fn) => { const f = path.join(d, 'rpc-inventory.json'); const j = JSON.parse(fs.readFileSync(f, 'utf8')); fn(j); fs.writeFileSync(f, JSON.stringify(j)); };
const editSql = (d, fn) => { const f = path.join(d, 'rpc-adapters.sql'); fs.writeFileSync(f, fn(fs.readFileSync(f, 'utf8'))); };
const cases = [
  ['baseline passes', () => {}, null],
  ['skip row removed from SQL', d => editSql(d, s => s.replace(/insert into iso\.rpc_adapter_skip\(signature,reason\) values \(\$s\$fn_log_client_error[\s\S]*?\n/, '')), 'protected row missing'],
  ['skip reason changed in SQL', d => editSql(d, s => s.replace('platform-operator scope', 'something else')), 'reason changed'],
  ['extra skip row in SQL', d => editSql(d, s => s + "\ninsert into iso.rpc_adapter_skip(signature,reason) values ($s$fn_x(p int)$s$,$r$x$r$) on conflict do nothing;\n"), 'extra skip row'],
  ['executable adapter overlaps protected base', d => editSql(d, s => s + `\ninsert into iso.rpc_adapter(signature,family,mutates,op,call_sql,reads_target,caller_scoped,note) values ($s$${P}$s$,'x',true,'update',$q$select 1$q$,false,false,$n$x$n$) on conflict (signature) do nothing;\n`), 'overlaps a protected'],
  ['executable variant overlaps protected', d => editSql(d, s => s + `\ninsert into iso.rpc_adapter(signature,family,mutates,op,call_sql,reads_target,caller_scoped,note) values ($s$${P}#v$s$,'x',true,'update',$q$select 1$q$,false,false,$n$x$n$) on conflict (signature) do nothing;\n`), 'overlaps a protected'],
  ['protected row reclassified in inventory', d => editInv(d, j => { j.signatures.find(i => i.signature === P).status = 'unexecuted-no-adapter'; }), 'reclassified'],
  ['unprotected row marked skipped', d => editInv(d, j => { j.signatures.find(i => i.status === 'control-valid').status = 'skipped-no-coverage-credit'; }), 'unprotected row marked skipped'],
  ['inventory hole', d => editInv(d, j => { j.signatures.pop(); }), 'inventory hole'],
  ['inventory extra signature', d => editInv(d, j => { j.signatures.push({signature: 'fn_ghost()', status: 'unexecuted-no-adapter', coverage: 'none'}); }), 'non-exposed'],
  ['inventory duplicate', d => editInv(d, j => { j.signatures.push({...j.signatures[0]}); }), 'duplicate inventory'],
  ['duplicate adapter insert (ON CONFLICT would hide it)', d => editSql(d, s => { const m = s.match(/insert into iso\.rpc_adapter\(signature,[^\n]*fn_stay_status[^\n]*\n/); return s + m[0]; }), 'duplicate adapter signature'],
  ['duplicate variant insert', d => editSql(d, s => { const m = s.match(/insert into iso\.rpc_adapter\(signature,[^\n]*#nogl[^\n]*\n/); return s + m[0]; }), 'duplicate adapter signature'],
  ['inventory coverage disagrees with SQL', d => editInv(d, j => { j.signatures.find(i => i.status === 'unexecuted-no-adapter').coverage = 'adapter-written'; }), 'coverage disagrees'],
];
let bad = 0;
for (const [name, mut, expect] of cases) {
  const r = variant(mut); const ok = expect === null ? r.errs.length === 0 : r.errs.some(e => e.includes(expect));
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (expect && ok ? '  [' + r.errs.find(e => e.includes(expect)).slice(0, 80) + ']' : '')); if (!ok) { bad++; console.log('   got:', r.errs.slice(0, 3)); }
}
process.exit(bad ? 1 : 0);
