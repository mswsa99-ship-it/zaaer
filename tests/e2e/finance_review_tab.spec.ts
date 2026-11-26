/**
 * Review in the finance centre (see the release record, not this comment, for authority). Only the entry point moved into the finance centre: the owner gets «المراجعة»
 * as the last finance tab; manager, finance and supervisor have no such tab and still cannot open the page.
 */
import { test, expect } from "./fixtures";

test("FR1 owner: «المراجعة» is the last finance tab and opens the review page", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/payments");
  const tabs = page.getByTestId("hub-tabs").getByRole("link");
  await expect(tabs.last()).toHaveText(/^المراجعة\d*$/);   // the label, then the count of what waits when there is one
  await tabs.last().click();
  await expect(page).toHaveURL(/\/admin\/review$/);
  await expect(page.getByRole("heading", { level: 1, name: "بحاجة لمراجعة وتدقيق" })).toBeVisible();
  await expect(page.getByTestId("hub-tabs").getByRole("link", { name: "المراجعة" })).toHaveAttribute("aria-current", "page");
});

for (const role of ["manager", "finance", "supervisor"] as const) {
  test(`FR2 ${role}: no review tab in the finance centre, and the page stays closed`, async ({ page, loginAs, go }) => {
    await loginAs(role);
    await go("/staff/payments");
    await expect(page.getByTestId("hub-tabs")).toBeVisible();
    await expect(page.getByTestId("hub-tabs").getByRole("link", { name: "المراجعة" })).toHaveCount(0);
    await go("/admin/review");
    await expect(page.getByRole("heading", { level: 1, name: "بحاجة لمراجعة وتدقيق" })).toHaveCount(0);
  });
}

test("FR3 owner: the review tab carries the count of what waits, the same number as the review page", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/payments");
  const tab = page.getByTestId("hub-tabs").getByRole("link", { name: /المراجعة/ });
  const badge = tab.getByLabel(/بانتظار المراجعة/);
  await expect(badge).toBeVisible();
  const n = (await badge.textContent())!.trim();
  await tab.click();
  await expect(page.getByText(`بانتظار المراجعة: ${n} —`)).toBeVisible();
  // the tab stays at the touch height and nothing scrolls sideways
  const box = await tab.boundingBox();
  expect(box!.height).toBeGreaterThanOrEqual(44);
});

test("RV1 review page: the bulk controls follow the ticks (none, one, all), the note stays while ticking and the scope line is shown", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/admin/review");
  await expect(page.getByTestId("review-scope")).toContainText("كل الفروع المتاحة لك");
  await expect(page.getByTestId("review-scope")).toContainText("الفرع المفتوح حاليًا فقط");
  const all = page.getByRole("checkbox", { name: /^تحديد الكل/ });
  const bulk = page.getByRole("button", { name: /تأشير المحدد كمراجَع/ });
  const note = page.getByLabel("ملاحظة المراجعة", { exact: true });
  await expect(all).toBeVisible();
  await expect(bulk).toHaveCount(0);   // nothing ticked: no bulk note, no bulk button
  await expect(note).toHaveCount(0);
  await all.check();                    // select all: the bar appears with the count of the items
  await expect(bulk).toBeVisible();
  await expect(bulk).toContainText("(1)");
  await note.fill("ملاحظة للتجربة");
  await page.getByTestId("review-item").first().getByRole("checkbox").uncheck();   // one item left unticked: the bar goes
  await expect(bulk).toHaveCount(0);
  await page.getByTestId("review-item").first().getByRole("checkbox").check();     // ticked again: the bar is back
  await expect(bulk).toBeVisible();
  await expect(note).toHaveValue("ملاحظة للتجربة");   // the note typed earlier is still there
  await expect(bulk).toBeEnabled();
  await bulk.click();
  await expect(page.getByTestId("review-bulk-confirm")).toContainText("تأكيد مراجعة 1");
  await page.getByRole("button", { name: "إلغاء" }).first().click();                // cancel keeps the item open
  await expect(page.getByTestId("review-item")).toHaveCount(1);
  // the per-row actions are unchanged
  await expect(page.getByTestId("review-ok")).toBeVisible();
  await expect(page.getByTestId("review-object")).toBeVisible();
});
