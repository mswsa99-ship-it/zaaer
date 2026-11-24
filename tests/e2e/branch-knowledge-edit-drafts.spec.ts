/** Local synthetic 6.5 increment only: branch settings and knowledge edits. */
import type { Page } from "@playwright/test";
import { test, expect } from "./fixtures";
const FORMS = [
 { name: "branch", path: "/admin/branches", field: "المدينة", key: "zaaer:branch-edit:", rpc: "rpc:fn_admin_upsert_branch" },
 { name: "knowledge", path: "/admin/knowledge", field: "الإجابة التي تُرسل للنزيل حرفيًا (مطلوب)", key: "zaaer:knowledge-edit:", rpc: "rpc:fn_admin_upsert_knowledge" },
];
for (const f of FORMS) {
 const edit = (page: Page) => page.getByRole("button", { name: f.name === "knowledge" ? /^تعديل:/ : /^تعديل / }).first();
 for (const width of [1280, 390]) test(`${f.name} edit ${width}: explicit restore, failed save retains, successful save clears`, async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width, height: 900 });
  await loginAs("owner"); await go(f.path); await edit(page).click();
  let dlg = page.getByRole("dialog");
  const original = await dlg.getByLabel(f.field, { exact: true }).inputValue();
  await dlg.getByLabel(f.field, { exact: true }).fill("تعديل تجريبي غير محفوظ");
  if (f.name === "branch") {
    await dlg.getByLabel("البريد", { exact: true }).fill("synthetic-private@example.invalid");
    await dlg.getByLabel("الهاتف", { exact: true }).fill("0500000000");
  }
  await page.waitForTimeout(650);
  const env = await page.evaluate((prefix) => { const k = Object.keys(sessionStorage).find((x) => x.startsWith(prefix))!; return { k, raw: sessionStorage.getItem(k)! }; }, f.key);
  expect(env.k.split(":")).toHaveLength(5); // prefix, form, user, org, record
  if (f.name === "branch") { expect(env.raw).not.toContain("synthetic-private"); expect(env.raw).not.toContain('"phone"'); expect(env.raw).not.toContain('"tax_number"'); }
  await page.reload({ waitUntil: "networkidle" }); await edit(page).click(); dlg = page.getByRole("dialog");
  await expect(dlg.getByLabel(f.field, { exact: true })).toHaveValue(original);
  await expect(dlg.getByTestId("form-draft-restore")).toBeVisible();
  await page.screenshot({ path: `/downloads/${f.name}-edit-${width}-offered.png` });
  await dlg.getByRole("button", { name: "استعادة المسودة" }).click();
  await expect(dlg.getByLabel(f.field, { exact: true })).toHaveValue("تعديل تجريبي غير محفوظ");
  await page.evaluate((rpc) => { (window as any).__demoFail = (t: string) => t === rpc ? "network down" : undefined; }, f.rpc);
  await dlg.getByRole("button", { name: /^حفظ/ }).first().click();
  await expect(dlg.getByRole("alert")).toBeVisible();
  expect(await page.evaluate((k) => sessionStorage.getItem(k), env.k)).not.toBeNull();
  await page.evaluate(() => { (window as any).__demoFail = undefined; });
  await dlg.getByRole("button", { name: /^حفظ/ }).first().click();
  await expect(dlg).toHaveCount(0);
  expect(await page.evaluate((k) => sessionStorage.getItem(k), env.k)).toBeNull();
  await edit(page).click();
  await expect(page.getByRole("dialog").getByLabel(f.field, { exact: true })).toHaveValue("تعديل تجريبي غير محفوظ");
  await expect(page.getByRole("dialog").getByTestId("form-draft-restore")).toHaveCount(0);
  await page.screenshot({ path: `/downloads/${f.name}-edit-${width}-saved.png` });
 });
 test(`${f.name}: untouched form stores nothing; same-record version mismatch is discarded`, async ({ page, loginAs, go }) => {
  await loginAs("owner"); await go(f.path); await edit(page).click();
  const initial = await page.getByRole("dialog").getByLabel(f.field, { exact: true }).inputValue();
  await page.waitForTimeout(650);
  expect(await page.evaluate((p) => Object.keys(sessionStorage).filter((k) => k.startsWith(p)), f.key)).toEqual([]);
  await page.getByRole("dialog").getByLabel(f.field, { exact: true }).fill("تعديل قديم"); await page.waitForTimeout(650);
  const key = await page.evaluate((p) => Object.keys(sessionStorage).find((k) => k.startsWith(p))!, f.key);
  await page.reload({ waitUntil: "networkidle" }); await edit(page).click();
  await expect(page.getByTestId("form-draft-restore")).toBeVisible();
  await page.keyboard.press("Escape");
  await page.evaluate((k) => { const e = JSON.parse(sessionStorage.getItem(k)!); e.version = "stale"; sessionStorage.setItem(k, JSON.stringify(e)); }, key);
  await page.reload({ waitUntil: "networkidle" }); await edit(page).click();
  await expect(page.getByTestId("form-draft-restore")).toHaveCount(0);
  await expect(page.getByRole("dialog").getByLabel(f.field, { exact: true })).toHaveValue(initial);
  expect(await page.evaluate((k) => sessionStorage.getItem(k), key)).toBeNull();
 });
}

for (const f of FORMS) test(`${f.name}: other user, org, or record keys cannot be restored`, async ({ page, loginAs, go }) => {
 await loginAs("owner"); await go(f.path);
 const edit = () => page.getByRole("button", { name: f.name === "knowledge" ? /^تعديل:/ : /^تعديل / }).first();
 await edit().click();
 await page.getByRole("dialog").getByLabel(f.field, { exact: true }).fill("مسودة محصورة"); await page.waitForTimeout(650);
 const stored = await page.evaluate((p) => { const k = Object.keys(sessionStorage).find((x) => x.startsWith(p))!; return { k, v: sessionStorage.getItem(k)! }; }, f.key);
 await page.keyboard.press("Escape");
 for (const index of [2, 3, 4]) {
   await page.evaluate(({ k, v, index }) => { Object.keys(sessionStorage).filter((x) => x.startsWith(k.split(":").slice(0, 2).join(":") + ":")).forEach((x) => sessionStorage.removeItem(x)); const pieces = k.split(":"); pieces[index] = "different"; sessionStorage.setItem(pieces.join(":"), v); }, { ...stored, index });
   await page.reload({ waitUntil: "networkidle" }); await edit().click();
   await expect(page.getByTestId("form-draft-restore")).toHaveCount(0);
   await page.keyboard.press("Escape");
 }
});
test("knowledge: an uncommitted keyword input is recovered, not silently lost", async ({ page, loginAs, go }) => {
 await loginAs("owner"); await go("/admin/knowledge");
 const edit = () => page.getByRole("button", { name: /^تعديل:/ }).first();
 await edit().click(); await page.getByRole("dialog").getByLabel("أضف كلمة مفتاحية").fill("مرادف تجريبي");
 await page.waitForTimeout(650); await page.reload({ waitUntil: "networkidle" }); await edit().click();
 await page.getByRole("button", { name: "استعادة المسودة" }).click();
 await expect(page.getByRole("dialog").getByLabel("أضف كلمة مفتاحية")).toHaveValue("مرادف تجريبي");
});
