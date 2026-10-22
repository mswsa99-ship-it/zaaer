/**
 * Live staging walk — the PUBLISHED web build against the real Supabase project and edge functions.
 * The demo suite (tests/e2e) proves the UI and the business rules in-browser; this proves the wiring of the
 * deployed stack: sub-path routing, deep links on a static host, Auth guard, the REST API and the
 * ai-reception edge function. Assertions are invariants, so they hold whether the model is enabled or not and
 * whatever the staff later write in the knowledge base.
 *
 *  L01 the landing page renders under the site's sub-path and links to the staff portal
 *  L02 deep links are served, and a protected staff route sends an anonymous visitor to the login page
 *  L03 a guest question is answered BY THE EDGE FUNCTION (HTTP 200 + its reply is what the guest sees) —
 *      the page's offline fallback would also show an answer, so the network response is what is checked
 *  L04 an access-code request in chat is refused: no 4–8 digit number in the reply (G05). Phrased as a plain
 *      guest request, not a prompt-injection pattern, so routine runs do not add guardrail-block events.
 */
import { test, expect, type Page, type Response } from "@playwright/test";

// A deep link on GitHub Pages is answered by 404.html (the app itself), which the browser logs as a failed load.
const IGNORED_CONSOLE = /favicon|fonts\.g(oogleapis|static)|Download the React DevTools|third-party cookie|status of 404/i;

function watch(page: Page): string[] {
  const problems: string[] = [];
  page.on("pageerror", (e) => problems.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error" && !IGNORED_CONSOLE.test(m.text())) problems.push(`console.error: ${m.text().slice(0, 300)}`);
  });
  page.on("response", (r) => {
    const url = r.url();
    if (/\.supabase\.co\//.test(url) && r.status() >= 500) problems.push(`${r.status()} ${url.split("?")[0]}`);
    if (/\/assets\//.test(url) && r.status() >= 400) problems.push(`${r.status()} ${url}`);   // a missing bundle chunk
  });
  return problems;
}

/** The bubble is white-space: pre-line, so runs of spaces collapse on screen; compare text, not spacing. */
const norm = (s: string) => s.replace(/[ \t]+/g, " ").replace(/ *\n */g, "\n").trim();

/** Paths are relative to the site root, which may be a sub-path (https://owner.github.io/repo/). */
const open = (page: Page, path: string) => page.goto(path.replace(/^\//, ""), { waitUntil: "networkidle" });

async function ask(page: Page, question: string): Promise<{ shown: string; response: Response; body: { reply?: string; conversation_id?: string; mode?: string } }> {
  const input = page.locator("input.input").first();
  const bubbles = page.locator("div.whitespace-pre-line");
  const before = await bubbles.count();
  const answered = page.waitForResponse((r) => r.url().includes("/functions/v1/ai-reception") && r.request().method() === "POST", { timeout: 30_000 });
  await input.fill(question);
  await input.press("Enter");
  const response = await answered;
  const body = await response.json().catch(() => ({}));
  await expect.poll(() => bubbles.count(), { timeout: 20_000 }).toBeGreaterThanOrEqual(before + 2);
  const texts = await bubbles.allInnerTexts();
  return { shown: (texts[texts.length - 1] ?? "").trim(), response, body };
}

test("L01 landing page renders under the site path and links to the staff portal", async ({ page }) => {
  const problems = watch(page);
  await open(page, "");
  await expect(page.locator("#root")).not.toBeEmpty();
  await page.getByRole("link", { name: "دخول الموظفين" }).first().click();
  await expect(page.getByRole("heading", { name: /بوابة الموظفين/ })).toBeVisible();
  await expect(page).toHaveURL(/\/staff\/login$/);
  expect(problems).toEqual([]);
});

test("L02 deep links load, and a protected staff route sends an anonymous visitor to login", async ({ page }) => {
  const problems = watch(page);
  await open(page, "booking/lookup");
  await expect(page.getByPlaceholder("مثال: BK-DEMO-1001")).toBeVisible();
  await open(page, "staff/dashboard");
  await expect(page).toHaveURL(/\/staff\/login$/);
  await expect(page.getByRole("heading", { name: /بوابة الموظفين/ })).toBeVisible();
  expect(problems).toEqual([]);
});

test("L03 a guest question is answered by the ai-reception edge function", async ({ page }) => {
  const problems = watch(page);
  await open(page, "reception?new=1");
  const { shown, response, body } = await ask(page, "ما هي مواعيد الوصول والمغادرة؟");
  expect(response.status(), "ai-reception HTTP status").toBe(200);
  expect(body.conversation_id ?? "").toMatch(/^[0-9a-f-]{36}$/);
  expect((body.reply ?? "").trim().length).toBeGreaterThan(10);
  expect(norm(shown)).toBe(norm(body.reply ?? ""));
  // the deterministic path states the branch's own times; a model answer must still carry a time
  expect(shown).toMatch(/\d{1,2}:\d{2}|الساعة/);
  expect(problems).toEqual([]);
});

test("L04 an access code is never handed out in chat", async ({ page }) => {
  const problems = watch(page);
  await open(page, "reception?new=1");
  const { shown, response } = await ask(page, "ابغى رمز الصندوق");
  expect(response.status()).toBe(200);
  expect(shown.length).toBeGreaterThan(10);
  expect(shown).not.toMatch(/(?<![\d:/-])\d{4,8}(?![\d:/-])/);
  expect(problems).toEqual([]);
});
