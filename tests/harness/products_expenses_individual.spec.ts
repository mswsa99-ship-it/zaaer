/** LOCAL harness proof (UI affordances only; enforcement is SQL 0138/0139): «المنتجات» and «المصروفات» for individual non-owner accounts. */
import { test, expect } from "@playwright/test";
const SHOTS = process.env.SHOTS_DIR ?? "/downloads/lane1/shots";
const acc = (path: string, o: Record<string, boolean>) => JSON.stringify({ mode: "individual", revision: 1, sensitive: [], home_page: null, pages: { [path]: o } });
const combos = [
  { n: "view-only", g: { view: true }, add: false, edit: false },
  { n: "view-add", g: { view: true, add: true }, add: true, edit: false },
  { n: "view-edit", g: { view: true, edit: true }, add: false, edit: true },
  { n: "view-add-edit", g: { view: true, add: true, edit: true }, add: true, edit: true },
];
async function login(page: import("@playwright/test").Page, grants: string) {
  await page.addInitScript((v) => localStorage.setItem("__harness_page_access", v), grants);
  await page.goto("/#/staff/login", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: "مدير الفرع" }).click();
  await page.waitForURL(/#\/(staff|admin)\//, { timeout: 15_000 });
}
for (const c of combos) {
  test(`individual products ${c.n}`, async ({ page }) => {
    const errs: string[] = []; page.on("pageerror", (e) => errs.push(e.message));
    await login(page, acc("/admin/products", c.g));
    await page.goto("/#/admin/products", { waitUntil: "networkidle" }); await page.waitForTimeout(600);
    await expect(page.getByTestId("product-category").first()).toBeVisible();
    await expect(page.getByRole("button", { name: "استيراد قائمة" })).toHaveCount(c.add ? 1 : 0);
    await expect(page.getByRole("button", { name: "منتج جديد" })).toHaveCount(c.add ? 1 : 0);
    await expect(page.getByRole("button", { name: "فئة جديدة" })).toHaveCount(c.add ? 1 : 0); // fn_admin_upsert_product_category: create = Add
    const catPencil = page.getByRole("button", { name: /^تعديل الفئة/ });
    if (c.edit) await expect(catPencil.first()).toBeVisible(); else await expect(catPencil).toHaveCount(0); // update = Edit
    const pencil = page.getByRole("button", { name: /^تعديل (?!الفئة)/ });
    if (c.edit) await expect(pencil.first()).toBeVisible(); else await expect(pencil).toHaveCount(0);
    await page.screenshot({ path: `${SHOTS}/products-${c.n}.png` });
    expect(errs).toEqual([]);
  });
  test(`individual expenses categories ${c.n}`, async ({ page }) => {
    const errs: string[] = []; page.on("pageerror", (e) => errs.push(e.message));
    await login(page, acc("/staff/expenses", c.g));
    await page.goto("/#/staff/expenses", { waitUntil: "networkidle" }); await page.waitForTimeout(600);
    const btn = page.getByRole("button", { name: "التصنيفات" });
    await expect(btn).toHaveCount(c.add || c.edit ? 1 : 0);
    await page.screenshot({ path: `${SHOTS}/expenses-${c.n}.png` });
    expect(errs).toEqual([]);
  });
}
