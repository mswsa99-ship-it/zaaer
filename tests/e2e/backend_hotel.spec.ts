import {test,expect} from "./fixtures";
test("BT30 switching reception branches starts an independent assistant conversation",async({page,loginAs,errors})=>{
 await loginAs("owner"); await page.goto("/#/admin/assistant?new=1");
 const input=page.getByPlaceholder(/اكتب سؤالك|اكتب لموظف/).first();
 await input.fill("ما موعد الوصول والمغادرة؟");await input.press("Enter");
 await expect(page.getByText(/الوصول يبدأ من الساعة/).last()).toBeVisible();
 await expect.poll(()=>page.evaluate(()=>JSON.parse(localStorage.getItem("zaaer_demo_store_v9")!).conversation_messages.filter((m:any)=>m.sender==="guest"&&m.content==="ما موعد الوصول والمغادرة؟").length)).toBeGreaterThan(0);
 const first=await page.evaluate(()=>{const s=JSON.parse(localStorage.getItem("zaaer_demo_store_v9")!);const m=s.conversation_messages.filter((m:any)=>m.sender==="guest"&&m.content==="ما موعد الوصول والمغادرة؟").at(-1);return s.conversations.find((c:any)=>c.id===m.conversation_id);});
 const picker=page.getByLabel("الفرع النشط",{exact:true});await picker.selectOption({index:1});
 await input.fill("ما موعد الوصول والمغادرة؟");await input.press("Enter");
 await expect(input).toBeEnabled();
 await expect.poll(()=>page.evaluate(({id,branch})=>{const s=JSON.parse(localStorage.getItem("zaaer_demo_store_v9")!);return s.conversation_messages.some((m:any)=>m.sender==="guest"&&m.content==="ما موعد الوصول والمغادرة؟"&&m.conversation_id!==id&&s.conversations.some((c:any)=>c.id===m.conversation_id&&c.branch_id!==branch));},{id:first.id,branch:first.branch_id})).toBe(true);
 await page.screenshot({path:"/tmp/deep-research/roomai/review/0081-assistant-branch.png",fullPage:true});
 expect(errors).toEqual([]);
});
