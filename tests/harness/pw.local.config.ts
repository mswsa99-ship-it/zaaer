/** LOCAL TEST HARNESS ONLY: serves /tmp/dist-harness (built by vite.individual.config.ts) and runs tests/harness/*.spec.ts */
import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: ".", testMatch: /.*\.spec\.ts/, retries: 0, workers: 1, reporter: [["list"], ["json", { outputFile: "/tmp/harness-results.json" }]],
  use: { baseURL: "http://localhost:4180", locale: "ar", ...devices["Desktop Chrome"], launchOptions: { executablePath: "/usr/bin/google-chrome" } },
  webServer: { command: "npx vite preview --outDir /tmp/dist-harness --port 4180 --strictPort", url: "http://localhost:4180", reuseExistingServer: false, timeout: 60_000 },
});
