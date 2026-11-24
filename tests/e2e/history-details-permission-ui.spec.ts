/**
 * 0125 «تفاصيل قبل وبعد التعديل» — UI facet (group c). Bounds: the demo build's in-browser backend does not model
 * individual-mode accounts, so server enforcement is proven in tests/sql/history_details_tests.sql, not here.
 * HD-UI2/UI3 feed the history tab SYNTHETIC audit rows through the demo store: one row as the server returns it WITH
 * the before/after (grant present) and one WITHOUT (grant absent: only the reason). Not a live backend.
 */
import { test, expect } from "./fixtures";
import type { Page } from "@playwright/test";

test("HD-UI1 the owner's individual-permission draft offers the history-details sensitive action", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/staff", { waitUntil: "networkidle" });
  await page.getByRole("button", { name: "مسودة صلاحيات فردية" }).first().click();
  await page.getByText(/تفاصيل الإجراءات الحساسة/).click();
  const box = page.getByLabel(/تفاصيل قبل وبعد التعديل/);
  await expect(box).toBeVisible();
  await expect(box).not.toBeChecked();
  await box.scrollIntoViewIfNeeded();
  await page.locator("details", { has: box }).screenshot({ path: "test-results/hd-ui1-sensitive-section.png" });
});

async function openHistory(page: Page, loginAs: (r: "manager") => Promise<void>, details: Record<string, unknown>) {
  await loginAs("manager");
  await page.goto("/#/staff/reservations", { waitUntil: "networkidle" });
  const href = await page.locator("a[href*='/staff/reservations/']:not([href$='/new'])").first().getAttribute("href");
  const id = href!.split("/").pop()!;
  await page.evaluate(([rid, d]) => {
    const raw = JSON.parse(localStorage.getItem("zaaer_demo_store_v9")!);
    raw.audit_events.unshift({ id: "synthetic-hd-1", entity_id: rid, entity_type: "reservation", action: "reservation.dates_changed",
      created_at: new Date().toISOString(), actor_id: null, details: d, correlation_id: "synthetic", source: "screen", actor_type: "staff", result: "success", category: "business" });
    localStorage.setItem("zaaer_demo_store_v9", JSON.stringify(raw));
  }, [id, details] as const);
  await page.reload({ waitUntil: "networkidle" });
  await page.goto(`/#/staff/reservations/${id}`, { waitUntil: "networkidle" });
  await page.getByRole("button", { name: "السجل", exact: true }).first().click();
  await expect(page.getByText("سجل التعديلات")).toBeVisible();
}

test("HD-UI2 synthetic response WITH before/after (grant present): the history tab shows reason and before → after", async ({ page, loginAs }) => {
  await openHistory(page, loginAs, { reason: "سبب-اختبار-HD", before: { nights: 2 }, after: { nights: 3 } });
  await expect(page.getByText("السبب: سبب-اختبار-HD")).toBeVisible();
  await expect(page.getByText('{"nights":2} → {"nights":3}')).toBeVisible();
  await page.getByText("سجل التعديلات").locator("xpath=..").screenshot({ path: "test-results/hd-ui2-with-details.png" });
});

test("HD-UI3 synthetic response WITHOUT before/after (grant absent): the history tab shows the reason only", async ({ page, loginAs }) => {
  await openHistory(page, loginAs, { reason: "سبب-اختبار-HD" });
  await expect(page.getByText("السبب: سبب-اختبار-HD")).toBeVisible();
  await expect(page.getByText("→")).toHaveCount(0);
  await page.getByText("سجل التعديلات").locator("xpath=..").screenshot({ path: "test-results/hd-ui3-reason-only.png" });
});
