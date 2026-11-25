import { readFileSync } from 'node:fs';
const t = JSON.parse(readFileSync('supabase/tenancy.json','utf8')).tables;
const quote = s => "'" + s.replaceAll("'", "''") + "'";
console.log('insert into iso.scope values ' + Object.entries(t).map(([k,v]) => `(${quote(k)},${quote(v.scope)})`).join(',') + ';');
