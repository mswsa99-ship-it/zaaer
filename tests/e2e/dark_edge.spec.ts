/** The sideways-scroll edge cue on a phone paints in the card's own colour: in the dark theme it must not paint white over the text. */
import { test, expect } from "./fixtures";
test("DARKEDGE the scroll-edge cue uses the card colour in dark and light (no hard white)", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await loginAs("owner");
  for (const scheme of ["dark", "light"] as const) {
    await page.emulateMedia({ colorScheme: scheme }); await go("/staff/reservations");
    const card = page.locator(".card.overflow-x-auto").first(); await expect(card).toBeVisible();
    const bg = await card.evaluate((e) => getComputedStyle(e).backgroundImage + "|" + getComputedStyle(e).backgroundColor);
    if (scheme === "dark") expect(bg).not.toContain("rgb(255, 255, 255)");
    expect(bg).toContain("gradient");
  }
});
