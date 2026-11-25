import { test,expect } from "./fixtures";
const A="00000000-0000-0000-0000-000000000001";
const B="90000000-0000-0000-0000-000000000202";
// Each browser gets synthetic second-hotel fixtures. This is not a server security substitute, SQL GT01-14 cover that.
async function twoHotels(page:import("@playwright/test").Page){
 await page.goto("/#/staff/login");
 await page.getByRole("button",{name:"المالك — كل الصلاحيات"}).click();
 await page.waitForTimeout(500);
 await page.evaluate(()=>sessionStorage.clear());
 await page.evaluate(({B})=>{
  const key="zaaer_demo_store_v9";const s=JSON.parse(localStorage.getItem(key)!);
  s.organizations.push({...s.organizations[0],id:B,guest_slug:B,name_ar:"فندق الاختبار الثاني"});
  s.branches.push({...s.branches[0],id:B,organization_id:B,name_ar:"فرع الفندق الثاني"});
  s.organizations[0].guest_slug=s.organizations[0].id;
  localStorage.setItem(key,JSON.stringify(s));

 },{B});
 await page.goto("about:blank");
}
test("GT30 two hotel addresses show only their own branches and identity",async({page,errors})=>{
 await twoHotels(page);
 await page.goto(`/#/h/${A}/reception`); await page.reload();
 await expect(page.locator("header")).toContainText("فايف اورز");
 await expect(page.getByLabel("الفرع").locator("option")).toHaveCount(2);
 await expect(page.getByLabel("الفرع")).not.toContainText("فرع الفندق الثاني");
 await page.goto(`/#/h/${B}/reception`); await page.reload();
 await expect(page.locator("header")).toContainText("فندق الاختبار الثاني");
 await expect(page.getByLabel("الفرع")).toHaveCount(0);
 await expect(page.getByTestId("wa-soon")).toBeVisible();
 await page.screenshot({path:"/tmp/deep-research/roomai/review/0080-hotel-b.png",fullPage:true});
 expect(errors).toEqual([]);
});
test("GT31 no address and an unknown hotel never fall back to the first hotels data",async({page,errors})=>{
 await twoHotels(page);
 await page.goto("/#/reception"); await page.reload();
 await expect(page.locator("header")).not.toContainText("فايف اورز");
 await expect(page.getByLabel("الفرع")).toHaveCount(0);
 await page.goto("/#/h/not-a-hotel/reception"); await page.reload();
 await expect(page.locator("header")).not.toContainText("فايف اورز");
 await expect(page.getByTestId("wa-qr")).toHaveCount(0);
 expect(errors).toEqual([]);
});

test("GT32 review capability brands its hotel and rejects another hotels address",async({page,errors})=>{
 await twoHotels(page);
 await page.goto(`/#/h/${A}/reception`); await page.reload();
 await page.evaluate(({A})=>{
  const key="zaaer_demo_store_v9",s=JSON.parse(localStorage.getItem(key)!);
  const tok="gt32-synthetic-review"; let a=0x811c9dc5,b=0x9e3779b9;
  for(let i=0;i<tok.length;i++){const c=tok.charCodeAt(i);a=Math.imul(a^c,16777619)>>>0;b=Math.imul(b+c,2246822519)>>>0;}
  const hash=a.toString(16).padStart(8,"0")+b.toString(16).padStart(8,"0")+tok.length.toString(16);
  s.guest_reviews.push({id:"gt32",organization_id:A,branch_id:s.branches[0].id,reservation_id:s.reservations[0].id,token_hash:hash,invited_at:new Date().toISOString(),version:1});
  localStorage.setItem(key,JSON.stringify(s));
 },{A});
 await page.goto("about:blank");
 await page.goto("/#/booking/review/gt32-synthetic-review"); await page.reload();
 await expect(page.locator("header")).toContainText("فايف اورز");
 await expect(page.getByTestId("mark-overall")).toBeVisible();
 await page.goto("about:blank");
 await page.goto(`/#/h/${B}/booking/review/gt32-synthetic-review`);await page.reload();
 await expect(page.getByTestId("mark-overall")).toHaveCount(0);
 await expect(page.locator("header")).toContainText("فندق الاختبار الثاني");
 expect(errors).toEqual([]);
});
