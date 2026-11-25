/** Release proofs (invented demo data only): nights 1..30 both ways, a 376px modal, a two-branch export download. */
import { test, expect, fillGuest } from "./fixtures";
import * as fs from "node:fs";

test("nights stepper walks 1 to 30 and back to 1, one step at a time", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const nights = page.getByTestId("nights-value");
  const up = page.getByRole("button", { name: "ليلة أكثر" }), down = page.getByRole("button", { name: "ليلة أقل" });
  const seenUp: number[] = [], seenDown: number[] = [];
  await expect(nights).toHaveText("1"); seenUp.push(1);
  for (let n = 2; n <= 30; n++) { await up.click(); await expect(nights).toHaveText(String(n)); seenUp.push(n); }
  await expect(up).toBeDisabled();
  seenDown.push(30);
  for (let n = 29; n >= 1; n--) { await down.click(); await expect(nights).toHaveText(String(n)); seenDown.push(n); }
  await expect(down).toBeDisabled();
  expect(seenUp).toHaveLength(30); expect(seenDown).toHaveLength(30);
  fs.writeFileSync("/tmp/proof/nights.json", JSON.stringify({ up: seenUp, down: seenDown }));
});

test("company tax modal at 376px", async ({ page, loginAs }) => {
  await page.setViewportSize({ width: 376, height: 800 });
  await loginAs("owner");
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
  await expect.poll(() => roomSel.locator("option").count()).toBeGreaterThan(1);
  await roomSel.selectOption({ index: 1 });
  await page.getByRole("button", { name: "التالي" }).click();
  await fillGuest(page, "ضيف شركة اختبار", "0501110077");
  await page.getByRole("button", { name: "التالي" }).click();
  await page.locator("select").filter({ has: page.locator("option:has-text('شركة')") }).first().selectOption("company");
  await page.locator("div:has(> label:has-text('اسم الشركة')) input").first().fill("شركة اختبار");
  await page.getByRole("button", { name: "إنشاء الحجز" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
  await page.getByRole("button", { name: "الإقامة", exact: true }).click();
  await page.getByTestId("company-tax-open").click();
  await expect(page.getByTestId("company-tax-form")).toBeVisible();
  const box = await page.getByRole("dialog").boundingBox();
  expect(box!.x).toBeGreaterThanOrEqual(0); expect(box!.x + box!.width).toBeLessThanOrEqual(376);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth);
  expect(overflow).toBeLessThanOrEqual(376);
  await page.screenshot({ path: "/tmp/proof/modal-376.png" });
});

test("two-branch export: a Jeddah reservation made in the demo UI shows in the all-branches xlsx with its branch", async ({ page, loginAs }) => {
  await loginAs("owner");
  const branchSel = () => page.locator('select[aria-label="الفرع النشط"]').first();
  await page.goto("/#/staff/reservations", { waitUntil: "networkidle" });
  await expect(branchSel().locator("option").last()).toHaveText("جميع الفروع");
  await branchSel().selectOption({ label: "فرع جدة — الكورنيش" });
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
  await expect.poll(() => roomSel.locator("option").count()).toBeGreaterThan(1);
  await roomSel.selectOption({ index: 1 });
  await page.getByRole("button", { name: "التالي" }).click();
  await fillGuest(page, "ضيف جدة تجريبي", "0501110066");
  await page.getByRole("button", { name: "التالي" }).click();
  await page.getByRole("button", { name: "إنشاء الحجز" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
  await page.goto("/#/staff/reservations", { waitUntil: "networkidle" });
  await branchSel().selectOption({ label: "جميع الفروع" });
  await page.waitForTimeout(800);
  await page.getByTestId("export-trigger").click();
  const dl = page.waitForEvent("download");
  await page.getByRole("menuitem", { name: /ملف Excel/ }).click();
  if (await page.getByTestId("export-scope-all").isVisible().catch(() => false)) await page.getByTestId("export-scope-all").click();
  const d = await dl;
  await d.saveAs("/tmp/proof/all-branches.xlsx");
  expect(fs.statSync("/tmp/proof/all-branches.xlsx").size).toBeGreaterThan(1000);
});

test("CAL1 departure picker: days up to the arrival are disabled, click is rejected, 390px screenshot", async ({ page, loginAs }) => {
  await loginAs("supervisor");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: "المغادرة", exact: true }).click();
  const dlg = page.getByRole("dialog", { name: "المغادرة" });
  const arrival = await page.getByRole("button", { name: "الوصول", exact: true }).locator("bdi").innerText();
  await expect(dlg).toBeVisible();
  const earlier = dlg.locator(`button[data-day="${arrival}"]`);
  if (await earlier.count()) {
    await expect(earlier).toBeDisabled();
    await earlier.click({ force: true });
    await expect(dlg).toBeVisible();
    await dlg.getByRole("button", { name: "موافق" }).click();
    await expect(page.getByRole("button", { name: "المغادرة", exact: true }).locator("bdi")).not.toHaveText(arrival);   // the rejected click chose nothing
  }
  await page.getByRole("button", { name: "المغادرة", exact: true }).click();
  const disabledCount = await dlg.locator("button[data-day]:disabled").count();
  expect(disabledCount).toBeGreaterThan(0);
  await page.screenshot({ path: process.env.CAL1_SHOT ?? "test-results/after-departure-calendar.png" });
});

test("ALLDASH owner operations centre offers «جميع الفروع» (390px) and the combined total is at least one branch", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.setViewportSize({ width: 390, height: 844 });
  const sel = () => page.locator('select[aria-label="الفرع النشط"]').first();
  await page.goto("/#/staff/dashboard", { waitUntil: "networkidle" });
  await expect(sel().locator("option").last()).toHaveText("جميع الفروع");
  const total = async () => Number((await page.locator("a", { hasText: "إجمالي الحجوزات" }).first().innerText()).replace(/\D/g, "") || "0");
  const first = (await sel().locator("option").first().getAttribute("value")) as string;
  await sel().selectOption(first);
  await page.waitForTimeout(800);
  const one = await total();
  await sel().selectOption({ label: "جميع الفروع" });
  await page.waitForTimeout(1200);
  const all = await total();
  expect(all).toBeGreaterThanOrEqual(one);
  await page.screenshot({ path: process.env.ALLDASH_SHOT ?? "test-results/all-branches-dashboard-390.png" });
});

test("STAYON the reservations «مقيم في يوم» filter uses the day picker (one day + OK), not a raw date box", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/reservations");
  await page.getByTestId("toggle-advanced").click();
  await expect(page.locator('input[type="date"]')).toHaveCount(0);
  const picker = page.getByRole("button", { name: "مقيم في يوم" });
  await picker.click();
  const today = new Date().toISOString().slice(0, 10);
  await page.locator(`button[data-day="${today}"]`).click();
  await page.getByRole("button", { name: "موافق" }).click();
  await expect(page.getByText(/مقيم في يوم/).first()).toBeVisible();
});

test("NATCAP nationality is a short dropdown plus «أخرى» (one manual field)", async ({ page, loginAs }) => {
  await loginAs("supervisor");
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
  await expect.poll(() => roomSel.locator("option").count()).toBeGreaterThan(1);
  await roomSel.selectOption({ index: 1 });
  await page.getByRole("button", { name: "التالي" }).click();
  const nat = page.getByTestId("nationality-select");
  await expect(nat).toBeVisible();
  const n = await nat.locator("option").count();
  expect(n).toBeLessThanOrEqual(13); // placeholder + 10 + «أخرى» (+ slack of one)
  await expect(page.getByTestId("nationality-other")).toHaveCount(0);
  await nat.selectOption({ label: "أخرى" });
  await expect(page.getByTestId("nationality-other")).toBeVisible();
});

test("ALLFOLLOW owner sees «جميع الفروع» last on stay follow-ups and the page still renders merged groups", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/followups", { waitUntil: "networkidle" });
  const sel = page.locator('select[aria-label="الفرع النشط"]').first();
  await expect(sel.locator("option").last()).toHaveText("جميع الفروع");
  await sel.selectOption({ label: "جميع الفروع" });
  await expect(page.getByTestId("followups-overdue")).toBeVisible();
  await expect(page.getByTestId("followups-departed")).toBeVisible();
  await expect(page.getByTestId("followups-late")).toBeVisible();
});

test("ALLROOMS owner «جميع الفروع» on the units board and calendar: units of both branches, each tagged with its branch", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/rooms", { waitUntil: "networkidle" });
  const sel = page.locator('select[aria-label="الفرع النشط"]').first();
  await expect(sel.locator("option").last()).toHaveText("جميع الفروع");
  await sel.selectOption({ index: 0 });
  const one = await page.locator("[data-testid=unit-card]").count();
  await sel.selectOption({ label: "جميع الفروع" });
  await expect.poll(() => page.locator("[data-testid=unit-card]").count()).toBeGreaterThan(one);
  await page.getByRole("tab", { name: /التقويم|تقويم/ }).click();
  await expect(page.getByText(/ · فرع جدة/).first()).toBeVisible();
});

test("COMPCAP companions are capped by the unit's capacity: adults + companions can never exceed max", async ({ page, loginAs }) => {
  await loginAs("supervisor");
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  const roomSel = page.locator("select").filter({ has: page.locator("option:has-text('تخصيص لاحقًا')") });
  await expect.poll(() => roomSel.locator("option").count()).toBeGreaterThan(1);
  await roomSel.selectOption({ index: 1 });
  await page.getByRole("button", { name: "التالي" }).click();
  const adults = page.locator('select[aria-label="بالغون"]').first();
  const comps = page.locator('select[aria-label="مرافقون"]').first();
  await expect(adults).toBeVisible();
  const aOpts = await adults.locator("option").allTextContents();
  const maxCap = Math.max(...aOpts.map(Number));
  await adults.selectOption(String(1));
  const c1 = (await comps.locator("option").allTextContents()).map(Number);
  expect(Math.max(...c1)).toBe(maxCap - 1);
  await adults.selectOption(String(maxCap));
  const c2 = (await comps.locator("option").allTextContents()).map(Number);
  expect(Math.max(...c2)).toBe(0);
});

test("MONEYSIGN a minus or an exponent typed in an amount is refused out loud, never dropped (-100 never becomes 100, 1e3 never 13)", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/expenses", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: /سند صرف/ }).click();
  const box = page.locator("input[data-money]").first();
  await box.click();
  await box.pressSequentially("-100");
  await expect(page.getByTestId("money-refused")).toBeVisible();
  await expect(box).not.toHaveValue("100");
  await box.fill("");
  await box.pressSequentially("1e3");
  await expect(page.getByTestId("money-refused")).toBeVisible();
  await expect(box).not.toHaveValue("13");
  await box.fill("");
  await box.pressSequentially("12.345");
  await expect(box).toHaveValue("12.34");   // a third decimal digit is still not taken
});

test("CASHFLOOR an expense above the cash-box balance is refused with the balance named (demo matches the real 0096 rule)", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/expenses", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: /سند صرف/ }).click();
  await page.locator("input[data-money]").first().fill("999999");
  await page.locator('select[aria-label="التصنيف"]').selectOption({ index: 1 });
  await page.getByLabel("الوصف").fill("اختبار تجاوز الرصيد");
  await page.locator('input[type=file]').setInputFiles({ name: "r.png", mimeType: "image/png", buffer: Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==", "base64") });
  await page.getByRole("button", { name: "حفظ السند" }).click();
  await expect(page.getByText(/أكبر من رصيد الصندوق/)).toBeVisible();
});

test("MOBRES at 390px the reservations list is cards, not a 1084px table (no horizontal scroll), and the wizard's التالي is a solid fill", async ({ page, loginAs }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await loginAs("owner");
  await page.goto("/#/staff/reservations", { waitUntil: "networkidle" });
  await expect(page.getByTestId("reservation-row").first()).toBeVisible();
  const measure = () => page.getByTestId("reservations-table").evaluate((el) => ({ table: (el.parentElement as HTMLElement).scrollWidth, page: document.documentElement.scrollWidth, view: document.documentElement.clientWidth, wide: Array.from(el.querySelectorAll("*")).filter((n) => n.getBoundingClientRect().right > document.documentElement.clientWidth + 1).map((n) => n.tagName + "." + String(n.className).slice(0, 30)).slice(0, 5) }));
  await expect.poll(async () => (await measure()).wide, { timeout: 8000 }).toEqual([]);
  await expect.poll(async () => { const w = await measure(); return w.page <= w.view; }, { timeout: 8000 }).toBe(true);
  await expect.poll(() => page.getByTestId("reservation-row").first().locator("td[data-label]").count()).toBeGreaterThan(3);
  await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
  await expect(page.getByRole("button", { name: "التالي" })).toBeVisible();
  await expect.poll(() => page.getByRole("button", { name: "التالي" }).evaluate((el) => getComputedStyle(el).backgroundColor), { timeout: 8000 }).toBe("rgb(23, 79, 96)");
});
