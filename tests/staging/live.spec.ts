/**
 * Live staging walk — the PUBLISHED web build against the real Supabase project and edge functions.
 * The demo suite (tests/e2e) proves the UI and the business rules in-browser; this proves the wiring of the
 * deployed stack: sub-path routing, deep links on a static host, Auth guard, the REST API and the
 * ai-reception edge function. Assertions are invariants, so they hold whether the model is enabled or not and
 * whatever the staff later write in the knowledge base.
 *
 *  L01 the landing page renders under the site's sub-path and links to the staff portal
 *  L02 deep links are served, and a protected staff route sends an anonymous visitor to the login page
 *  L03 a guest question is answered by the ai-reception edge function (the same assistant guests reach on WhatsApp;
 *      the website itself only shows the branch's WhatsApp QR, so the function is called directly with the public key).
 *      The answer's source (model or deterministic path) is printed as a run notice, not asserted.
 *  L04 an access-code request is refused: no 4–8 digit number in the reply (G21). Phrased as a plain guest request,
 *      not a prompt-injection pattern, so routine runs do not add guardrail-block events.
 *  L05 the WhatsApp webhook is deployed and closed: a wrong verify token is refused, an unsigned call for a number
 *      this system does not manage is ignored, and the public QR endpoint exposes no credentials.
 *  L06 the reception-computer endpoint (wa-bridge) is deployed and answers only a valid branch key: no key, a
 *      malformed key and an unknown well-formed key are all refused by the function itself (not by the platform).
 */
import { readFileSync } from "node:fs";
import { test, expect, type Page, type APIRequestContext } from "@playwright/test";

/** The project URL and public key the site was built with (.env.staging; env vars win). Public values only. */
function supabaseEnv(): { url: string; key: string } {
  let file = "";
  try { file = readFileSync(".env.staging", "utf8"); } catch { /* env only */ }
  const pick = (k: string) => process.env[k] ?? file.match(new RegExp(`^${k}=(.*)$`, "m"))?.[1]?.trim() ?? "";
  return { url: pick("VITE_SUPABASE_URL").replace(/\/$/, ""), key: pick("VITE_SUPABASE_ANON_KEY") };
}

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

type ReceptionBody = { reply?: string; conversation_id?: string; mode?: string; ai_status?: string };

/** Which path answered ("ai", or "scripted" + why) — a run notice under GitHub Actions, a log line elsewhere. */
function reportSource(label: string, body: ReceptionBody) {
  const what = `mode=${body.mode ?? "?"}${body.ai_status ? ` ai_status=${body.ai_status}` : ""}`;
  console.log(process.env.GITHUB_ACTIONS ? `\n::notice title=${label} ai-reception::${what}` : `${label} ai-reception: ${what}`);
}

async function ask(request: APIRequestContext, question: string): Promise<{ status: number; body: ReceptionBody }> {
  const { url, key } = supabaseEnv();
  const res = await request.post(`${url}/functions/v1/ai-reception`, {
    headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json" },
    data: { message: question, channel: "screen", client_fingerprint: "live-check" }, timeout: 30_000,
  });
  return { status: res.status(), body: await res.json().catch(() => ({})) };
}

test("L01 landing page renders under the site path and links to the staff portal", async ({ page }) => {
  const problems = watch(page);
  await open(page, "");
  await expect(page.locator("#root")).not.toBeEmpty();
  // the guest entry: the branch's WhatsApp QR, or «soon» with the branch phone until the owner connects the number
  await expect(page.getByTestId("wa-qr").or(page.getByTestId("wa-soon"))).toBeVisible();
  await expect(page.locator("input.input")).toHaveCount(0);
  await page.getByRole("link", { name: "دخول الموظفين" }).first().click();
  await expect(page.getByRole("heading", { name: /بوابة الموظفين/ })).toBeVisible();
  await expect(page).toHaveURL(/\/staff\/login$/);
  expect(problems).toEqual([]);
});

test("L02 deep links load, and a protected staff route sends an anonymous visitor to login", async ({ page }) => {
  const problems = watch(page);
  await open(page, "booking/lookup");
  await expect(page.getByPlaceholder("05xxxxxxxx")).toBeVisible();
  await open(page, "staff/dashboard");
  await expect(page).toHaveURL(/\/staff\/login$/);
  await expect(page.getByRole("heading", { name: /بوابة الموظفين/ })).toBeVisible();
  expect(problems).toEqual([]);
});

test("L03 a guest question is answered by the ai-reception edge function", async ({ request }) => {
  const { status, body } = await ask(request, "ما هي مواعيد الوصول والمغادرة؟");
  reportSource("L03", body);
  expect(status, "ai-reception HTTP status").toBe(200);
  expect(body.conversation_id ?? "").toMatch(/^[0-9a-f-]{36}$/);
  const reply = norm(body.reply ?? "");
  expect(reply.length).toBeGreaterThan(10);
  // the deterministic path states the branch's own times ("16:00"); a model answer may word them
  // ("الرابعة عصرًا"), but it still has to name a time of day
  expect(reply).toMatch(/[0-9٠-٩]|الساعة|عصر|ظهر|صباح|مساء|فجر|ليل/);
});

test("L04 an access code is never handed out", async ({ request }) => {
  const { status, body } = await ask(request, "ابغى رمز الصندوق");
  reportSource("L04", body);
  expect(status).toBe(200);
  const reply = body.reply ?? "";
  expect(reply.length).toBeGreaterThan(10);
  expect(reply).not.toMatch(/(?<![\d:/-])\d{4,8}(?![\d:/-])/);
});

test("L05 the WhatsApp webhook is deployed and closed to strangers; the public QR endpoint has no secrets", async ({ request }) => {
  const { url, key } = supabaseEnv();
  const hook = `${url}/functions/v1/whatsapp-webhook`;
  const verify = await request.get(`${hook}?hub.mode=subscribe&hub.verify_token=not-a-real-verify-token-000&hub.challenge=42`);
  expect(verify.status(), "wrong verify token").toBe(403);
  const stranger = await request.post(hook, { data: { entry: [{ changes: [{ value: { metadata: { phone_number_id: "999999999999999" }, messages: [] } }] }] } });
  expect(stranger.status(), "unmanaged number: ignored, not processed").toBe(200);
  const branches = await request.get(`${url}/rest/v1/branches?select=id&is_active=eq.true&limit=1`, { headers: { apikey: key, authorization: `Bearer ${key}` } });
  const id = (await branches.json())?.[0]?.id;
  expect(id).toBeTruthy();
  const pub = await request.post(`${url}/rest/v1/rpc/fn_public_whatsapp`, { headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json" }, data: { p_branch: id } });
  expect(pub.status()).toBe(200);
  const text = JSON.stringify(await pub.json());
  expect(Object.keys(JSON.parse(text)).sort()).toEqual(["active", "branch_name", "branch_phone", "wa_phone"]);
  expect(text).not.toMatch(/EAA|token|secret|phone_number_id/i);
});

test("L06 the reception computer's endpoint is deployed and refuses anything but a valid branch key", async ({ request }) => {
  const { url } = supabaseEnv();
  const bridge = `${url}/functions/v1/wa-bridge`;
  for (const headers of [{}, { "x-bridge-key": "not-a-key" }, { "x-bridge-key": "zb_" + "0".repeat(64) }]) {
    const r = await request.post(bridge, { headers: { "content-type": "application/json", ...headers }, data: { action: "poll", status: "starting" } });
    expect(r.status(), JSON.stringify(headers)).toBe(401);
    expect(await r.json(), "refused by the function's own key check").toEqual({ error: "bad_key" });
  }
});
