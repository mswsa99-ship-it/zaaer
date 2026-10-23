/**
 * The browser WhatsApp Web runs in: the computer's own Chrome or Edge (nothing is downloaded). Edge is part of
 * Windows 10/11, so one is always there. A separate profile (the program's "session" folder) keeps it apart from the
 * receptionist's own browsing.
 */
import fs from "node:fs";
import path from "node:path";

export function browserCandidates(env = process.env, platform = process.platform) {
  if (platform === "win32") {
    const pf = env.PROGRAMFILES ?? "C:\\Program Files";
    const pf86 = env["PROGRAMFILES(X86)"] ?? "C:\\Program Files (x86)";
    const local = env.LOCALAPPDATA ?? "";
    return [
      path.win32.join(pf, "Google", "Chrome", "Application", "chrome.exe"),
      path.win32.join(pf86, "Google", "Chrome", "Application", "chrome.exe"),
      local && path.win32.join(local, "Google", "Chrome", "Application", "chrome.exe"),
      path.win32.join(pf86, "Microsoft", "Edge", "Application", "msedge.exe"),
      path.win32.join(pf, "Microsoft", "Edge", "Application", "msedge.exe"),
    ].filter(Boolean);
  }
  if (platform === "darwin") {
    return ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge", "/Applications/Chromium.app/Contents/MacOS/Chromium"];
  }
  return ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/microsoft-edge", "/opt/pw-browsers/chromium"];
}

/** configured path → PUPPETEER_EXECUTABLE_PATH → the first installed Chrome/Edge; null when there is none */
export function findBrowser(configured, { env = process.env, platform = process.platform, exists = fs.existsSync } = {}) {
  for (const p of [configured, env.PUPPETEER_EXECUTABLE_PATH, ...browserCandidates(env, platform)]) {
    if (p && exists(p)) return p;
  }
  return null;
}
