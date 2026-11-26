/** An empty expense save names every missing field and puts the focus on the first one on the page. Demo build only. */
import { test, expect } from "./fixtures";
for (const w of [360, 1280]) test(`EXE1 empty save marks amount and attachment, focus on the amount (${w})`, async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: w, height: 800 });
  await loginAs("supervisor");
  await go("/staff/expenses");
  await page.getByRole("button", { name: "سند صرف" }).click();
  const dlg = page.getByRole("dialog");
  await dlg.getByRole("button", { name: "حفظ السند" }).click();
  await expect(dlg.getByLabel("المبلغ")).toHaveAttribute("aria-invalid", "true");
  await expect(dlg.getByLabel("المرفق")).toHaveAttribute("aria-invalid", "true");
  await expect(dlg.getByLabel("المبلغ")).toBeFocused();
  // the attachment rule is unchanged: a valid amount alone still refuses, and focus moves to the attachment
  await dlg.getByLabel("المبلغ").fill("45");
  await expect(dlg.getByLabel("المبلغ")).not.toHaveAttribute("aria-invalid", "true");
  await dlg.getByRole("button", { name: "حفظ السند" }).click();
  await expect(dlg.getByLabel("المرفق")).toBeFocused();
  await expect(dlg).toBeVisible();
  await page.screenshot({ path: `/tmp/proof/exe-${w}.png` });
});
