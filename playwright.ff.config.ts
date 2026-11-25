import base from "./playwright.config";
import { devices } from "@playwright/test";
export default { ...base, projects: [{ name: "firefox", use: { ...devices["Desktop Firefox"], viewport: { width: 1366, height: 900 } }, testMatch: /(design_parity_regression|unit_license|payment_settings_sensitive_ui)\.spec\.ts/ }] };
