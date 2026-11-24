import { test, expect } from "./fixtures";
test("financial settings save actual thresholds and survive reload", async ({ page, loginAs, go }, testInfo) => {
  await loginAs("owner"); await go("/admin/finance-controls");
  await expect(page.getByRole("heading",{name:"الضبط المالي",exact:true})).toBeVisible();
  await page.getByLabel("مشرف استقبال",{exact:true}).fill("1500");
  await page.getByLabel("عتبة الخصم (نقطة أساس، ١٠٠ = ١٪)",{exact:true}).fill("2000");
  await page.getByRole("button",{name:"حفظ الضبط المالي",exact:true}).click();
  await expect(page.getByRole("status").filter({hasText:"حُفظت"})).toBeVisible();
  await page.waitForTimeout(300); // demo persistence debounce
  await page.reload();
  await expect(page.getByLabel("مشرف استقبال",{exact:true})).toHaveValue("1500");
  await page.screenshot({path:testInfo.outputPath("finance-settings-desktop.png"),fullPage:true});
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:testInfo.outputPath("finance-settings-mobile.png"),fullPage:true});
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
  await page.getByLabel("مشرف استقبال",{exact:true}).fill("-1");
  await page.getByRole("button",{name:"حفظ الضبط المالي",exact:true}).click();
  await expect(page.getByRole("alert")).toContainText("عددًا صحيحًا");
});
test("non-owner cannot open financial settings", async ({page,loginAs,go})=>{
 await loginAs("supervisor"); await go("/admin/finance-controls");
 await expect(page.getByRole("heading",{name:"الضبط المالي",exact:true})).toHaveCount(0);
});
