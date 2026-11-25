import { test, expect } from "./fixtures";

// Regression for the approved keybox strip only, not the separate guest-journey notice.
for (const width of [1366, 390]) for (const theme of ["light", "dark"] as const) {
  test(`keybox strip retains 50% red background in ${theme} at ${width}px`, async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    await page.addInitScript((value) => localStorage.setItem("roomai-theme", value), theme);
    await loginAs("owner");
    await go("/staff/dashboard");
    await expect(page.getByRole("heading", { name: "مركز العمليات", exact: true })).toBeVisible();
    const strip = page.getByTestId("keybox-alert");
    await expect(strip).toBeVisible();
    await expect(strip).toHaveCSS("background-color", "rgba(140, 33, 27, 0.5)");
    await expect(strip).toHaveCSS("opacity", "1");
    await expect(strip.locator(".font-semibold")).toHaveCSS("opacity", "1");
    await strip.hover();
    await expect(strip).toHaveCSS("background-color", "rgba(140, 33, 27, 0.5)");
  });
}
