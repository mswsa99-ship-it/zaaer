import { defineConfig, devices } from "@playwright/test";

/**
 * End-to-end suite — runs against the DEMO build (dist-demo), which is the production UI
 * wired to the in-browser backend (src/demo). Every test gets a fresh browser context, so
 * each one starts from the seeded store (localStorage is per context). No network, no keys.
 *
 *   npm run build:demo && npm run e2e
 *
 * PW_CHROMIUM=/path/to/chrome overrides the browser binary (useful on machines where the
 * Playwright-managed download is not allowed).
 */
const PORT = Number(process.env.E2E_PORT || 4174);
const executablePath = process.env.PW_CHROMIUM;

export default defineConfig({
  testDir: "tests/e2e",
  timeout: 90_000,
  expect: { timeout: 10_000 },
  fullyParallel: true,
  workers: process.env.CI ? 2 : 3,
  retries: process.env.CI ? 1 : 0,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]] : [["list"]],
  outputDir: "test-results",
  use: {
    baseURL: `http://localhost:${PORT}`,
    locale: "ar-SA",
    timezoneId: "Asia/Riyadh",
    viewport: { width: 1366, height: 900 },
    launchOptions: executablePath ? { executablePath } : {},
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "off",
  },
  webServer: {
    command: `npx vite preview --outDir dist-demo --port ${PORT} --strictPort`,
    url: `http://localhost:${PORT}/`,
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1366, height: 900 } } },
    // Housekeeping and the guest reception are used on phones: run those specs at phone width too.
    { name: "mobile", use: { ...devices["Pixel 7"] }, testMatch: /(housekeeping|guest-reception|smoke)\.spec\.ts/ },
  ],
});
