import {INDIVIDUAL_PERMISSION_MAP} from "../../src/lib/individualPermissionMap";
import {readFileSync} from "node:fs";
import {expect,it} from "vitest";
import {PAGES} from "../../src/lib/nav";
it("draft server page allowlist exactly matches source route registry",()=>{
 const sql=readFileSync(new URL("../../supabase/migrations/20261125010000_0108_individual_permission_drafts.sql",import.meta.url),"utf8");
 const match=sql.match(/page.key <> all\(array\[([^\]]+)\]/);expect(match).not.toBeNull();
 const paths=[...match![1].matchAll(/'([^']+)'/g)].map(m=>m[1]).sort();
 expect(paths).toEqual([...new Set(PAGES.map(p=>p.path))].sort());
});
it("active server page catalog exactly matches source route registry",()=>{
 const sql=readFileSync(new URL("../../supabase/migrations/20261125020000_0109_individual_page_guard_foundation.sql",import.meta.url),"utf8");
 const block=sql.match(/returns table\(page text\) language sql immutable set search_path=public as \$\$ values ([\s\S]*?) \$\$/)![1];
 const paths=[...block.matchAll(/\('([^']+)'\)/g)].map(m=>m[1]).sort();
 expect(paths).toEqual([...new Set(PAGES.map(p=>p.path))].sort());
});

it("frontend sensitive map exactly matches proposed SQL map (0112 plus the 0125 history.details row)",()=>{
 const sql=readFileSync(new URL("../../supabase/migrations/20261125040500_0112_permission_page_map_proposed.sql",import.meta.url),"utf8");
 const sql125=readFileSync(new URL("../../supabase/migrations/20261125200000_0125_history_details_permission.sql",import.meta.url),"utf8");
 const entries=[...(sql+"\n"+sql125).matchAll(/\('([^']+)', '([^']+)', '([^']+)', (true|false), (true|false)\)/g)].map(m=>[m[1],{page:m[2],action:m[3],sensitive:m[4]==="true"}]);
 expect(entries.length).toBe(60);
 expect(new Set(entries.map(([code])=>code)).size).toBe(entries.length);
 expect(INDIVIDUAL_PERMISSION_MAP).toEqual(Object.fromEntries(entries));
 expect(INDIVIDUAL_PERMISSION_MAP["res.cancel"].sensitive).toBe(true);
 expect(INDIVIDUAL_PERMISSION_MAP["admin.permissions"]).toBeUndefined();
});
