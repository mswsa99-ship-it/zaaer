/**
 * New-release coverage sweep for plan items 6.5-6.8 (local demo build, synthetic data only).
 * It inventories every staff/admin route in the browser and asserts the parts that are provable
 * without touching the backend. Items it cannot prove stay listed in docs/new-release-coverage.md.
 */
import { test, expect } from "./fixtures";

const ROUTES = [
  "/staff/dashboard","/staff/arrivals","/staff/reservations","/staff/identity-verification","/staff/payments","/staff/orders",
  "/staff/pos-settlement","/staff/day-close","/staff/expenses","/staff/ledger","/staff/accounts","/staff/bank","/staff/access-approvals",
  "/staff/followups","/staff/platforms","/staff/day-summary","/staff/rooms","/staff/housekeeping","/staff/codes","/staff/tickets","/staff/inbox",
  "/admin/dashboard","/admin/organization","/admin/branches","/admin/room-categories","/admin/rooms","/admin/structure","/admin/facilities",
  "/admin/task-types","/admin/services","/admin/products","/admin/rates","/admin/availability","/admin/availability-rules","/admin/reservations",
  "/admin/guests","/admin/finance","/admin/platform-payouts","/admin/cash-accounts","/admin/bank-mail","/admin/staff","/admin/roles",
  "/admin/booking-sources","/admin/finance-controls","/admin/ai-settings","/admin/whatsapp","/admin/backups","/admin/payment-providers",
  "/admin/policies","/admin/knowledge","/admin/reports","/admin/audit-logs","/admin/usage","/admin/review","/admin/integrations","/admin/journey",
];

test.describe("new-release coverage 6.6: one state per list, every route", () => {
  for (const path of ROUTES) {
    test(`single state at rest: ${path}`, async ({ page, loginAs, go, errors }) => {
      void errors;
      await loginAs("owner");
      await go(path);
      await page.waitForTimeout(600);
      const spinners = await page.locator('[role="progressbar"], [aria-busy="true"], [data-testid*="loading"]').count();
      const alerts = await page.locator('main [role="alert"]').count();
      expect(spinners, "no spinner left after load").toBe(0);
      expect(alerts, "no error card on a healthy load").toBe(0);
    });
  }
});

test.describe("new-release coverage 6.8: disabled controls say why, every route", () => {
  for (const path of ROUTES) {
    test(`disabled reasons: ${path}`, async ({ page, loginAs, go, errors }) => {
      void errors;
      await loginAs("owner");
      await go(path);
      await page.waitForTimeout(500);
      const bad = await page.evaluate(() => {
        const out: string[] = [];
        document.querySelectorAll<HTMLElement>("button:disabled, input:disabled, select:disabled, textarea:disabled").forEach((el) => {
          const r = el.getBoundingClientRect();
          if (r.width === 0 || r.height === 0) return;
          if (el.closest("[aria-busy='true']")) return;
          const desc = el.getAttribute("aria-describedby");
          const hasDesc = !!desc && desc.split(" ").some((id) => { const t = document.getElementById(id); return !!t && (t.textContent || "").trim().length > 0 && t.getBoundingClientRect().height > 0; });
          const hasTitle = false; // 6.8: a hover-only title is not a reason; the reason must be visible text referenced by aria-describedby
          const near = (el.closest("label,div,fieldset,section")?.textContent || "").trim().length > (el.textContent || "").trim().length + 3;
          const fs = el.closest("fieldset:disabled"); void fs;
          const legend = fs?.querySelector("legend")?.textContent?.trim();
          if (!hasDesc && !hasTitle && !legend && !(el.tagName !== "BUTTON" && near)) {
            out.push(`${el.tagName.toLowerCase()}:${(el.getAttribute("aria-label") || el.textContent || el.getAttribute("name") || "").trim().slice(0, 40)}`);
          }
        });
        return out;
      });
      expect(bad, `disabled controls without a stated reason on ${path}`).toEqual([]);
    });
  }
});

/* 6.5: new-record drafts on three more long forms. Offered back, restored only on click, cleared after save. */
const DRAFT_CASES = [
  { name: "unit", path: "/admin/rooms", open: "وحدة جديدة", fields: [["رقم / اسم الوحدة (مطلوب)", "ZZ-901"]], banner: "مسودة وحدة", save: "حفظ" },
  { name: "policy", path: "/admin/policies", open: "سياسة جديدة", fields: [["العنوان", "سياسة مسودة الاختبار"], ["النص", "نص السياسة الذي كان سيضيع"]], banner: "مسودة سياسة", save: "حفظ" },
  { name: "knowledge answer", path: "/admin/knowledge", open: "سؤال وجواب", fields: [["السؤال كما يطرحه النزيل (مطلوب)", "هل يوجد موقف سيارات للمسودة؟"], ["الإجابة التي تُرسل للنزيل حرفيًا (مطلوب)", "نعم، موقف مجاني."]], banner: "مسودة إجابة", save: "حفظ" },
];
for (const c of DRAFT_CASES) {
  test(`new-release coverage 6.5: ${c.name} draft survives a reload and is restored only on click`, async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go(c.path);
    await page.getByRole("button", { name: c.open }).first().click();
    let dlg = page.getByRole("dialog");
    for (const [label, v] of c.fields) await dlg.getByLabel(label, { exact: true }).fill(v);
    await page.waitForTimeout(700);
    await page.reload({ waitUntil: "networkidle" });
    await page.getByRole("button", { name: c.open }).first().click();
    dlg = page.getByRole("dialog");
    await expect(dlg.getByTestId("form-draft-restore")).toContainText(c.banner);
    await expect(dlg.getByLabel(c.fields[0][0], { exact: true })).toHaveValue("");
    await dlg.getByRole("button", { name: "استعادة المسودة" }).click();
    for (const [label, v] of c.fields) await expect(dlg.getByLabel(label, { exact: true })).toHaveValue(v);
    await expect(dlg.getByTestId("form-draft-restore")).toHaveCount(0);
    if (process.env.K_SHOTS) await page.screenshot({ path: `/tmp/shots/draft-${c.name.replace(/ /g, "-")}.png` });
    await dlg.getByRole("button", { name: c.save, exact: true }).click();
    await expect(dlg).toBeHidden({ timeout: 15_000 });
    await page.getByRole("button", { name: c.open }).first().click();
    await expect(page.getByRole("dialog").getByTestId("form-draft-restore")).toHaveCount(0);
  });
}
test("new-release coverage 6.5: the unit draft never stores the licence number", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/admin/rooms");
  await page.getByRole("button", { name: "وحدة جديدة" }).first().click();
  const dlg = page.getByRole("dialog");
  await dlg.getByLabel("رقم / اسم الوحدة (مطلوب)", { exact: true }).fill("ZZ-902");
  await page.waitForTimeout(700);
  const stored = await page.evaluate(() => Object.entries(sessionStorage).filter(([k]) => k.includes("room-draft")).map(([, v]) => v));
  expect(stored.length).toBe(1);
  expect(stored[0]).not.toContain("license");
});

/* 6.8: visible reasons on real states, with pixels. */
test("new-release coverage 6.8: the reason is visible text beside a disabled control (audit log first page)", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/admin/audit-logs");
  const prev = page.getByRole("button", { name: "السابق" });
  if (await prev.count()) {
    await expect(prev).toBeDisabled();
    const reason = page.getByTestId("disabled-reason").filter({ hasText: "أنت في الصفحة الأولى" });
    await expect(reason).toBeVisible();
    await expect(prev).toHaveAttribute("aria-describedby", /dr-/);
    await reason.scrollIntoViewIfNeeded();
    if (process.env.K_SHOTS) await page.screenshot({ path: `/tmp/shots/reason-auditlog-${test.info().project.name}.png` });
  }
});
test("new-release coverage 6.8: roles page states why the cells are locked and the reset button is off", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/admin/roles");
  await expect(page.locator("#dr-roles-fixed")).toBeVisible();
  await expect(page.getByTestId("perm-reset")).toBeDisabled();
  await expect(page.locator("#dr-roles-reset")).toBeVisible();
  if (process.env.K_SHOTS) await page.screenshot({ path: `/tmp/shots/reason-roles-${test.info().project.name}.png` });
});

/* 6.6: failure and recovery on every route the older specs do not cover (25 are covered there). */
const COVERED = /^\/(staff\/(expenses|ledger|arrivals|reservations|payments|tickets|housekeeping|codes|followups|orders|bank|platforms|identity-verification)|admin\/(room-categories|services|rooms|facilities|task-types|structure|cash-accounts|booking-sources|branches|staff|knowledge|policies))$/;
const REMAINING = ROUTES.filter((r) => !COVERED.test(r));
for (const path of REMAINING) {
  test(`new-release coverage 6.6 failure+recovery: ${path}`, async ({ page, loginAs, go, errors }) => {
    await loginAs("owner");
    // start from a different page than the one under test (a hash change to the same route would not reload it)
    const home = path === "/admin/dashboard" ? "/staff/dashboard" : path === "/staff/dashboard" ? "/admin/dashboard" : path.startsWith("/admin") ? "/admin/dashboard" : "/staff/dashboard";
    await go(home);
    await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = () => "network down"; });
    await page.evaluate((p) => { window.location.hash = p; }, path);
    await page.waitForTimeout(1200);
    const main = page.locator("main");
    const failed = await main.locator("[role=alert]").count();
    const empty = await main.getByText(/^لا (توجد|يوجد)/).filter({ hasNotText: "للتصدير" }).count(); // the export button's own reason is not a list state
    const spinning = await main.locator(".animate-spin").count();
    if (process.env.K_LIST) (await import("node:fs")).appendFileSync("/tmp/fail-sweep.txt", `${path} alert=${failed} empty=${empty} spin=${spinning}\n`);
    expect(failed, `${path}: an injected load failure must be visible as one error`).toBeGreaterThanOrEqual(1);
    expect([failed > 0, empty > 0, spinning > 0].filter(Boolean).length, `${path}: error=${failed} empty=${empty} loading=${spinning}`).toBeLessThanOrEqual(1);
    await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = undefined; });
    const retry = main.getByRole("button", { name: "إعادة المحاولة" }).first();
    if (await retry.count()) await retry.click();
    else await page.evaluate(([h, p]) => { window.location.hash = h; setTimeout(() => { window.location.hash = p; }, 50); }, [home, path]);
    await page.waitForTimeout(1200);
    // some pages carry several independent sections whose error banners have no retry of their own (admin/reports): leaving and re-entering the route is the recovery there
    if (await main.locator("[role=alert]").count()) {
      await page.evaluate(([h, p]) => { window.location.hash = h; setTimeout(() => { window.location.hash = p; }, 50); }, [home, path]);
      await page.waitForTimeout(1200);
    }
    await expect(main.locator("[role=alert]")).toHaveCount(0);
    await expect(main.locator(".animate-spin")).toHaveCount(0);
    const unexpected = errors.filter((e) => !/network down/i.test(e));
    expect(unexpected, "no unexpected console errors during injected failure").toEqual([]);
    errors.splice(0, errors.length, ...unexpected);
  });
}

/* 6.7: same-tick double submit reaches the server once (ref lock added on these two ad-hoc handlers). */
test("new-release coverage 6.7: two same-tick submits of the card-terminal settlement call the server once", async ({ page, loginAs, go }) => {
  await loginAs("finance");
  await go("/staff/pos-settlement");
  await page.evaluate(() => {
    const w = window as unknown as { __calls: number; __demoLatency: (t: string) => number };
    w.__calls = 0;
    w.__demoLatency = (t) => { if (t === "rpc:fn_pos_settle") { w.__calls += 1; return 800; } return 0; };
  });
  const total = page.locator("div:has(> label:has-text('إجمالي جهاز الشبكة')) input").first();
  await total.fill("100");
  const note = page.getByLabel("سبب الفرق");
  if (await note.count()) await note.fill("سبب اختبار الضغطتين");
  const save = page.getByRole("button", { name: /حفظ التسوية|تحديث التسوية/ });
  await save.evaluate((b) => { const f = (b as HTMLButtonElement).form!; f.requestSubmit(); f.requestSubmit(); });
  await expect(save).toBeDisabled();
  await page.waitForTimeout(1500);
  expect(await page.evaluate(() => (window as unknown as { __calls: number }).__calls)).toBe(1);
});

test("new-release coverage 6.7: two same-tick submits of a key-box code change call the server once", async ({ page, loginAs, go }) => {
  await loginAs("housekeeping");
  await go("/staff/codes");
  await page.evaluate(() => {
    const w = window as unknown as { __calls: number; __demoLatency: (t: string) => number };
    w.__calls = 0;
    w.__demoLatency = (t) => { if (t === "rpc:fn_staff_rotate_keybox_code") { w.__calls += 1; return 800; } return 0; };
  });
  const card = page.locator('[data-testid="code-unit"][data-state="change"]').first();
  await expect(card).toBeVisible();
  await card.getByRole("button", { name: "تغيير الرمز" }).click();
  const form = card.getByTestId("code-form");
  await form.getByLabel("الرمز الجديد", { exact: true }).fill("7391");
  await form.getByLabel("تأكيد الرمز", { exact: true }).fill("7391");
  await form.getByRole("checkbox").check();
  const save = form.getByRole("button", { name: "حفظ الرمز" });
  await save.evaluate((b) => { const f = (b as HTMLButtonElement).form!; f.requestSubmit(); f.requestSubmit(); });
  await page.waitForTimeout(1800);
  expect(await page.evaluate(() => (window as unknown as { __calls: number }).__calls)).toBe(1);
});
