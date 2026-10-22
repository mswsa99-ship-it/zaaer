import { defineConfig, devices } from "@playwright/test";

/**
 * Live checks against a DEPLOYED environment (staging): the real web build, talking to the real Supabase
 * project and edge functions — what the demo suite (playwright.config.ts) cannot prove. Read-only apart from
 * one guest conversation per run; it never signs in and never touches reservations, money or staff data.
 *
 *   STAGING_URL=https://<owner>.github.io/<repo>/ npx playwright test -c playwright.staging.config.ts
 *
 * Run by .github/workflows/staging.yml after every publish. Paths in the specs are relative ("reception",
 * not "/reception") so they resolve under the site's sub-path.
 */
const target = process.env.STAGING_URL;
if (!target) throw new Error("STAGING_URL is not set (the published site, e.g. https://<owner>.github.io/<repo>/)");
const executablePath = process.env.PW_CHROMIUM;

export default defineConfig({
  testDir: "tests/staging",
  timeout: 60_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [["list"], ["html", { open: "never", outputFolder: "playwright-report-staging" }]] : [["list"]],
  outputDir: "test-results-staging",
  use: {
    baseURL: target.endsWith("/") ? target : `${target}/`,
    locale: "ar-SA",
    timezoneId: "Asia/Riyadh",
    launchOptions: executablePath ? { executablePath } : {},
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "off",
  },
  projects: [{ name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1366, height: 900 } } }],
});
