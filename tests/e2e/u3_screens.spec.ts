/**
 * U3 (approved 31 Oct 2026): on a phone the main navigation is a bottom bar of four pages plus «المزيد»; the units
 * board opens with what needs doing now and puts the units needing attention first.
 */
import { test, expect } from "./fixtures";

test("UB01 on a phone the supervisor and the owner get a bottom bar of four pages and «المزيد» opens the whole menu", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await loginAs("supervisor");
  await go("/staff/rooms");
  const bar = page.getByTestId("bottom-tabs");
  await expect(bar).toBeVisible();
  await expect(bar.getByRole("link")).toHaveCount(4);
  await expect(bar.getByRole("link", { name: "الوحدات" })).toBeVisible();
  await page.getByTestId("bottom-tabs-more").click();
  const drawer = page.getByTestId("staff-menu-drawer");
  await expect(drawer).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(drawer).toBeHidden();
});

test("UB01b the owner's bottom bar leads to the administration's main pages, and it is gone on a computer", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await loginAs("owner");
  await go("/admin/dashboard");
  await expect(page.getByTestId("bottom-tabs").getByRole("link", { name: "المالية" })).toBeVisible();
  await page.setViewportSize({ width: 1280, height: 900 });
  await expect(page.getByTestId("bottom-tabs")).toBeHidden();
});

test("UB02 the units board says what needs doing now and lists the units needing attention first", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await go("/staff/rooms");
  await expect(page.getByTestId("occupancy-strip")).toBeVisible();
  const cards = page.getByTestId("unit-card");
  await expect(cards.first()).toBeVisible();
  const now = page.getByTestId("units-now");
  if (await now.count()) {
    await expect(now.getByText("ينتظرك الآن")).toBeVisible();
    await now.getByRole("button", { name: "عرض ما يحتاج انتباهًا" }).click();
    await expect(page.getByTestId("units-filter-attention")).toHaveAttribute("aria-pressed", "true");
  }
  const ranks = (await cards.evaluateAll((els) => els.map((e) => Number(e.getAttribute("data-urgency")))));
  expect(ranks).toEqual([...ranks].sort((a, b) => a - b));
});

test("UB04 a reservation opens with its stages, its next step and its amounts; the step's button moves to the section that does it", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await go("/staff/reservations");
  await page.locator("select").filter({ has: page.locator('option[value="confirmed"]') }).selectOption("confirmed");
  await page.locator("table tbody tr").first().getByRole("link", { name: "فتح" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
  const stages = page.getByTestId("stay-stages");
  await expect(stages.getByRole("listitem")).toHaveCount(5);
  await expect(stages.locator('[aria-current="step"]')).toHaveCount(1);
  const next = page.getByTestId("next-step");
  await expect(next).toContainText("الخطوة التالية:");
  await expect(page.getByTestId("stay-amounts")).toContainText("المتبقي على النزيل");
  await page.getByTestId("next-step-go").click();
  await expect.poll(async () => page.evaluate(() => {
    const ids = ["res-guests", "res-room", "res-stay", "res-ops"];
    return ids.some((id) => { const el = document.getElementById(id); if (!el) return false; const t = el.getBoundingClientRect().top; return t >= -5 && t < window.innerHeight / 2; });
  })).toBe(true);
});

test("UB05 the owner sees the branches side by side, the platforms net of commission and the operations alerts", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/admin/dashboard");
  const o = page.getByTestId("owner-overview");
  await expect(o).toBeVisible();
  const rows = page.getByTestId("branch-row");
  expect(await rows.count()).toBeGreaterThan(0);
  if ((await rows.count()) > 1) await expect(page.getByTestId("branches-total")).toContainText("المجموع");
  await expect(o.getByRole("heading", { name: "آجل عند المنصات (صافٍ بعد العمولة)" })).toBeVisible();
  await expect(page.getByTestId("ops-alerts").getByRole("listitem").first()).toBeVisible();
});

test("UB06 the guest's page welcomes them with the branch, lists the steps before arrival and the branch's own stay rules", async ({ page, go }) => {
  await page.evaluate(() => { try { sessionStorage.removeItem("guest_phone_session"); } catch { /* storage blocked */ } }).catch(() => undefined);
  await go("/booking/lookup");
  await page.getByPlaceholder("05xxxxxxxx").fill("0501110008");
  await page.getByRole("button", { name: "متابعة" }).click();
  await page.getByPlaceholder("رقم الحجز").fill("R-26A0008");
  await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
  await expect(page).toHaveURL(/\/booking\/status\//);
  await expect(page.getByTestId("guest-hero")).toBeVisible();
  await expect(page.getByTestId("guest-greeting")).toHaveText("أهلًا بك، إقامتك تبدأ اليوم");
  await expect(page.getByRole("heading", { name: "قبل وصولك" })).toBeVisible();
  await expect(page.getByRole("list", { name: "خطوات الإقامة" }).getByRole("listitem")).toHaveCount(5);
  await expect(page.getByTestId("guest-rules")).toBeVisible();
});
