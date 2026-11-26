/** LOCAL TEST HARNESS ONLY: runs dialog_reach.spec.ts against the dialog fixture dev server. */
import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: ".", testMatch: /dialog_reach\.spec\.ts/, retries: 0, workers: 1, reporter: [["list"]],
  use: { baseURL: "http://localhost:4190", locale: "ar-SA", ...devices["Desktop Chrome"], hasTouch: true, launchOptions: { executablePath: "/usr/bin/google-chrome", args: ["--no-sandbox"] } },
  webServer: { command: "VITE_DEMO=1 npx vite --config tests/harness/vite.dialog.config.ts", cwd: "../..", url: "http://localhost:4190/tests/harness/dialog/index.html", reuseExistingServer: false, timeout: 60_000 },
});
