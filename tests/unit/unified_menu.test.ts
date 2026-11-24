import {expect,it} from "vitest";
import {unifiedMenu,PAGES,pageAllowed} from "../../src/lib/nav";
import {defaultPermissions} from "../../src/lib/permissionCatalog";
it.each(["owner","manager","supervisor","finance","housekeeping"])("one menu never expands legacy grant for %s",role=>{
 const permissions=defaultPermissions(role);const allows={can:(c:string)=>permissions.allowed.has(c),canFull:(c:string)=>permissions.full.has(c)};
 const menu=unifiedMenu(role,allows);expect(new Set(menu.map(p=>p.path)).size).toBe(menu.length);
 for(const p of menu)expect(pageAllowed(p,role,allows)).toBe(true);
});
it("owner's menu includes hotel administration and operations in one place",()=>{
 const paths=unifiedMenu("owner").map(p=>p.path);expect(paths).toContain("/staff/dashboard");expect(paths).toContain("/admin/staff");expect(paths).toContain("/admin/organization");expect(paths).not.toContain("/platform");
 const admin=PAGES.filter(p=>p.area==="admin"&&!p.hidden&&p.roles.includes("owner"));for(const p of admin)expect(paths).toContain(p.path);
});
