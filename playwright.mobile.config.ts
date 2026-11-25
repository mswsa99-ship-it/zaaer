import base from "./playwright.config";
import { devices } from "@playwright/test";
export default { ...base, projects: [{ name: "mobile", use: { ...devices["Pixel 7"], launchOptions: { executablePath: "/usr/bin/google-chrome", args: ["--no-sandbox"] } }, testMatch: /(design_parity_regression|payment_settings_sensitive_ui)\.spec\.ts/ }] };
