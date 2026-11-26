/** The reservation page at 390: the stay's next step (with its button) is inside the first screen; the ban/hold stays first; the rating and hold buttons come after it. */
import { test, expect } from "./fixtures";
test("P1 the next-step card and its button fit the first screen; rating follows the next step", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("owner");
  for (const ref of ["R-26A0004", "R-26A0006"]) {
    await go("/staff/reservations"); await page.waitForTimeout(400);
    await page.locator("li, tr, div").filter({ hasText: ref }).filter({ has: page.getByRole("link", { name: "فتح" }) }).last().getByRole("link", { name: "فتح" }).first().click();
    const step = page.getByTestId("next-step"); await expect(step).toBeVisible();
    const box = (await step.boundingBox())!; const btn = (await step.getByRole("button").first().boundingBox())!;
    expect(box.y + box.height, `${ref} card ends above the footer (844 - 64)`).toBeLessThanOrEqual(844 - 64);
    expect(btn.y + btn.height, `${ref} button inside the first screen`).toBeLessThanOrEqual(844 - 64);
    const rating = page.getByTestId("guest-rating"); if (await rating.count()) expect((await rating.boundingBox())!.y).toBeGreaterThan(box.y);
  }
});
