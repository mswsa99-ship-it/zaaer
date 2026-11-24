import { test, expect } from "./fixtures";

test("owner can raise and lower guest limits, save and reload; invalid values are refused", async ({page, loginAs, go}) => {
  await loginAs("owner"); await go("/admin/ai-settings");
  const panel = page.getByTestId("guest-ai-limits");
  const values = [12, 25, 650, 4, 8, 90];
  const inputs = panel.locator("input");
  await expect(inputs).toHaveCount(6);
  for (let i=0;i<values.length;i++) await inputs.nth(i).fill(String(values[i]));
  await page.getByRole("button", {name:"حفظ الإعدادات"}).click();
  await expect(page.getByText("تم الحفظ", {exact:true})).toBeVisible();
  await page.waitForTimeout(500);
  await page.reload({waitUntil:"networkidle"});
  for (let i=0;i<values.length;i++) await expect(inputs.nth(i)).toHaveValue(String(values[i]));
  await inputs.nth(0).fill("0");
  await page.getByRole("button", {name:"حفظ الإعدادات"}).click();
  await expect(page.getByRole("alert").first()).toContainText("خارج النطاق");
  page.on("dialog", d=>void d.accept());
  await page.reload({waitUntil:"networkidle"});
  await expect(inputs.nth(0)).toHaveValue("12");
});

test("manager cannot edit guest limits", async ({page, loginAs, go}) => {
  await loginAs("manager"); await go("/admin/ai-settings");
  if(await page.getByTestId("guest-ai-limits").count()) {
    for(const input of await page.getByTestId("guest-ai-limits").locator("input").all()) await expect(input).toBeDisabled();
  } else await expect(page.getByRole("button",{name:"حفظ الإعدادات"})).toHaveCount(0);
});
