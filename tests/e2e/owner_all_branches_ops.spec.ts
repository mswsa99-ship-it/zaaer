/** Owner «جميع الفروع» on the operational staff pages: Tickets, Inbox, Housekeeping (invented demo data only). Other accounts keep one branch. */
import { test, expect } from "./fixtures";

const picker = (page: import("@playwright/test").Page) => page.locator('select[aria-label="الفرع النشط"]').first();

test.describe("owner all branches: tickets, inbox, housekeeping", () => {
  test("AB-T1 tickets: the choice exists, rows keep their branch, a new report names its unit's branch", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/tickets", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await expect(page.getByTestId("ticket-branch")).toHaveCount(0);
    await picker(page).selectOption({ label: "جميع الفروع" });
    await page.getByRole("button", { name: "بلاغ جديد" }).click();
    const opts = await page.locator("select.input").first().locator("option").allTextContents();
    expect(opts.filter((o) => o.includes(" — ")).length).toBeGreaterThan(0);   // every unit option carries its branch
  });
  test("AB-H1 housekeeping: all branches show branch badges; a new task needs a branch and then offers only that branch's units", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
    await picker(page).selectOption({ label: "جميع الفروع" });
    await page.getByRole("button", { name: "حالة الوحدات" }).click();
    const names = new Set(await page.getByTestId("hk-branch").allTextContents());
    expect(names.size).toBeGreaterThanOrEqual(2);
    await page.getByRole("button", { name: "مهمة جديدة" }).click();
    const br = page.getByTestId("hk-new-branch");
    await expect(br).toBeVisible();
    expect(await br.evaluate((e: HTMLSelectElement) => e.value)).toBe("");
    const roomSel = page.getByRole("dialog").locator("select").nth(1);
    await br.selectOption({ index: 1 });
    const first = await roomSel.locator("option").allTextContents();
    await br.selectOption({ index: 2 });
    const second = await roomSel.locator("option").allTextContents();
    expect(first.length).toBeGreaterThan(1);
    expect(second.length).toBeGreaterThan(1);
    expect(first[0]).toBe("اختر الوحدة");                       // no unit is chosen for the owner: the choice is deliberate
    expect(await roomSel.evaluate((e: HTMLSelectElement) => e.value)).toBe("");
  });
  test("AB-I1 inbox: the owner gets the all-branches choice and the page loads", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/inbox", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await picker(page).selectOption({ label: "جميع الفروع" });
    await expect(page.getByText("الوارد الموحّد")).toBeVisible();
  });
  test("AB-M1 mixed rows: the owner's all-branches Tickets and Inbox hold rows of both branches with their branch; one branch alone shows only its own; a supervisor never sees the other branch's rows", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/tickets", { waitUntil: "networkidle" });
    await picker(page).selectOption({ label: "جميع الفروع" });
    await expect(page.getByText("تسريب في حمام الغرفة").first()).toBeVisible();
    await expect(page.getByText("مكيف J-2").first()).toBeVisible();
    const badges = new Set(await page.getByTestId("ticket-branch").allTextContents());
    expect(badges.size).toBeGreaterThanOrEqual(2);
    await page.goto("/#/staff/inbox", { waitUntil: "networkidle" });
    await picker(page).selectOption({ label: "جميع الفروع" });
    await expect(page.getByText("فرع جدة — الكورنيش").first()).toBeVisible();
    await expect(page.getByText("فرع الرياض — طريق الملك فهد").first()).toBeVisible();
    await picker(page).selectOption({ index: 0 });
    await expect(page.getByRole("button", { name: /فرع جدة/ })).toHaveCount(0);   // no conversation row of the other branch (the picker option is not a button)
  });
  test("AB-M2 a supervisor of the first branch sees none of the second branch's tickets, inbox rows or codes", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    for (const [u, text] of [["/#/staff/tickets", "مكيف J-2"], ["/#/staff/inbox", "فرع جدة"], ["/#/staff/codes", "J-1"]] as const) {
      await page.goto(u, { waitUntil: "networkidle" });
      await expect(page.getByText(text)).toHaveCount(0);
    }
  });
  test("AB-J1 guest journey: the owner's all-branches board merges the departures of both branches and tags each row with its branch; a supervisor has none (see AB-N1)", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/journey", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await picker(page).selectOption({ label: "جميع الفروع" });
    await expect(page.getByTestId("journey-departing")).toBeVisible();
    const names = new Set(await page.getByTestId("journey-branch").allTextContents());
    expect(names.size).toBeGreaterThanOrEqual(2);
    await expect(page.getByTestId("journey-branch-settings")).toContainText("جدة");   // per-branch settings stay reachable, not merged away
    const rows = await page.getByTestId("journey-branch-settings").innerText();
    expect(rows).toContain("10:00 صباحًا");  expect(rows).toContain("11:00 صباحًا");      // Riyadh and Jeddah keep their own morning-message times, said as the admin settings say them (12-hour, Arabic)
    expect(rows).toContain("1:00 عصرًا");  expect(rows).toContain("2:00 عصرًا");
    await page.getByTestId("journey-tab-reviews").click();                                // each branch's own rating and count stay visible beside the merged mark
    await expect(page.getByTestId("journey-reviews-branches")).toContainText("جدة");
    await expect(page.getByTestId("journey-reviews-approx")).toHaveCount(0);               // raw rows complete: exact, not labelled approximate
    await page.getByTestId("journey-open-branch").last().click();                          // a direct switch to that branch's own board
    await expect(page.getByTestId("journey-branch")).toHaveCount(0);
    await page.getByTestId("journey-tab-reviews").click();                                // one branch: no cross-branch rating table left over from the merged view
    await expect(page.getByTestId("journey-reviews")).toBeVisible();
    await expect(page.getByTestId("journey-reviews-branches")).toHaveCount(0);
    await expect(picker(page)).toHaveValue(/.+/);
  });
  test("AB-R1 admin units: the owner's all-branches list merges both branches' units with a branch tag, offers no add, and each row opens its own branch for editing", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/rooms", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await picker(page).selectOption({ label: "جميع الفروع" });
    await expect(page.getByTestId("admin-unit-card").first()).toBeVisible();
    const tags = new Set(await page.getByTestId("admin-unit-branch").allTextContents());
    expect(tags.size).toBeGreaterThanOrEqual(2);
    await expect(page.getByRole("button", { name: /وحدة جديدة/ })).toHaveCount(0);       // a new unit needs one branch: no add in the merged list
    await expect(page.getByRole("button", { name: /^تعديل الوحدة/ })).toHaveCount(0);      // no edit bound to a guessed branch
    await page.locator('[data-testid="admin-unit-card"][data-room="J-1"]').getByTestId("admin-unit-open-branch").click();
    await expect(page.getByTestId("admin-unit-branch")).toHaveCount(0);                    // now the one branch: plain list again
    await expect(page.locator('[data-testid="admin-unit-card"][data-room="J-1"]')).toBeVisible();
    await expect(page.getByRole("button", { name: /^تعديل الوحدة J-1/ })).toBeVisible();   // edit is back, on that branch
  });

  for (const [route, noAdd, editName, label] of [["/#/admin/services", /خدمة جديدة/, /^تعديل الخدمة$/, "services"], ["/#/admin/facilities", /مرفق جديد/, /^تعديل المرفق$/, "facilities"], ["/#/admin/room-categories", /نوع جديد/, /^تعديل (?!فرع)/, "room categories"], ["/#/admin/task-types", /نوع جديد/, /^تعديل نوع المهمة$/, "task types"]] as const) {
    test(`AB-R2 admin ${label}: the owner's all-branches list merges both branches with a branch tag, offers no add or edit, and a row opens its own branch`, async ({ page, loginAs }) => {
      await loginAs("owner");
      await page.goto(route, { waitUntil: "networkidle" });
      await picker(page).selectOption({ label: "جميع الفروع" });
      if (label === "facilities") await page.getByText("إظهار المؤرشف").click();   // the seeded Jeddah facility is archived, so Jeddah's active list stays empty (U04)
      await expect(page.getByTestId("admin-row-branch").first()).toBeVisible();
      expect(new Set(await page.getByTestId("admin-row-branch").allTextContents()).size).toBeGreaterThanOrEqual(2);
      await expect(page.getByRole("button", { name: noAdd })).toHaveCount(0);
      await expect(page.getByRole("button", { name: editName })).toHaveCount(0);
      await page.getByTestId("admin-row-open-branch").last().click();                      // the Jeddah row (sorted after Riyadh's)
      await expect(page.getByTestId("admin-row-branch")).toHaveCount(0);
      await expect(page.getByRole("button", { name: editName }).first()).toBeVisible();   // edit is back, on that branch
    });
  }

  test("AB-N1 a supervisor keeps single-branch pages (no «جميع الفروع» anywhere on them)", async ({ page, loginAs }) => {
    await loginAs("supervisor");
    for (const u of ["/#/staff/tickets", "/#/staff/housekeeping", "/#/staff/inbox", "/#/staff/codes", "/#/staff/journey", "/#/admin/rooms", "/#/admin/services", "/#/admin/facilities", "/#/admin/room-categories", "/#/admin/task-types"]) {
      await page.goto(u, { waitUntil: "networkidle" });
      await expect(page.getByText("جميع الفروع")).toHaveCount(0);
    }
  });
});

test.describe("owner all branches: product orders and accounts", () => {
  test("AB-P1 product orders: the owner's all-branches list labels each order with its branch; a new order asks for the branch first", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/orders", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await picker(page).selectOption({ label: "جميع الفروع" });
    await page.getByRole("button", { name: "طلب لنزيل" }).click();
    await expect(page.getByTestId("po-new-branch")).toBeVisible();
    expect(await page.getByTestId("po-new-branch").evaluate((e: HTMLSelectElement) => e.value)).toBe("");
  });
  test("AB-A1 accounts: the owner can pick «جميع الفروع»; a supervisor-level account has no such option", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/accounts", { waitUntil: "networkidle" });
    await expect(picker(page).locator("option").last()).toHaveText("جميع الفروع");
    await picker(page).selectOption({ label: "جميع الفروع" });
    await expect(page.getByText("الحسابات").first()).toBeVisible();
  });
});

test("AB-K1 all-branches keybox alert covers every branch and names each room's branch; a branch view names only its own", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/housekeeping", { waitUntil: "networkidle" });
  const banner = page.getByTestId("keybox-alert");
  await expect(banner).toBeVisible();
  const single = (await banner.innerText()).replace(/\s+/g, " ");
  expect(single).not.toMatch(/\(فرع/);
  await picker(page).selectOption({ label: "جميع الفروع" });
  await expect.poll(async () => (await banner.innerText()).replace(/\s+/g, " "), { timeout: 8000 }).toMatch(/\(فرع/);
});

test("AB-S1 accounts: the visible scope always matches the effective one (picker «جميع الفروع» hides the redundant checkbox; ticking «كل فروعي» says so)", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/accounts", { waitUntil: "networkidle" });
  const box = page.getByRole("checkbox", { name: /كل فروعي/ });
  await expect(box).toBeVisible();
  await expect(page.getByTestId("acc-scope")).toHaveCount(0);
  await box.check();
  await expect(page.getByTestId("acc-scope")).toContainText("كل فروعك");
  await box.uncheck();
  await picker(page).selectOption({ label: "جميع الفروع" });
  await expect(page.getByRole("checkbox", { name: /كل فروعي/ })).toHaveCount(0);
  await expect(page.getByTestId("acc-scope")).toHaveText("النطاق: جميع الفروع");
});

test("KB-R1 the rooms board never says «must change» for a unit that simply has no ready box (it says «not ready»); Codes keeps the three states", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/staff/rooms", { waitUntil: "networkidle" });
  await picker(page).selectOption({ label: "فرع جدة — الكورنيش" });
  await expect(page.getByText("J-1").first()).toBeVisible();
  const text = (await page.locator("main").innerText()).replace(/\s+/g, " ");
  expect(text).toContain("الرمز غير جاهز");
  expect(text).not.toContain("يجب تغيير الرمز");
});

test("AB-R3 rates: the owner's all-branches calendar stacks both branches read-only with a branch tag, and a row opens its own branch for editing", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/rates", { waitUntil: "networkidle" });
  const pick = page.locator(`select[aria-label="الفرع النشط"]`).first();
  await pick.selectOption({ label: "جميع الفروع" });
  await page.getByTestId("rates-branch").first().waitFor();
  const tags = await page.getByTestId("rates-branch").allInnerTexts();
  expect(new Set(tags).size).toBe(2);
  await expect(page.getByTestId("rates-cell").first()).toHaveAttribute("aria-disabled", "true");
  await expect(page.getByRole("button", { name: "تعديل المحدد" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /تعديل مجموعة/ })).toHaveCount(0);
  await page.getByTestId("rates-open-branch").first().click();
  await expect(page.getByTestId("rates-branch")).toHaveCount(0);
  expect(await page.getByTestId("rates-cell").first().isDisabled()).toBe(false);
});

test("AB-P2 payment providers: the owner's all-branches view lists each branch read-only without key values, and a row opens its own branch form", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/payment-providers", { waitUntil: "networkidle" });
  await page.getByLabel("الفرع", { exact: true }).selectOption({ label: "جميع الفروع" });
  await expect(page.getByTestId("payment-branch-row")).toHaveCount(2);
  await expect(page.getByTestId("save-payment-settings")).toHaveCount(0);
  await expect(page.locator("input")).toHaveCount(0);
  await page.getByRole("button", { name: /فتح فرع .* لتعديل مزوّد الدفع/ }).first().click();
  await expect(page.getByTestId("payment-all")).toHaveCount(0);
  await expect(page.getByTestId("save-payment-settings")).toBeVisible();
});

test("AB-P3 payment providers: a populated branch and an empty branch keep their own status in the all-branches view; the stored key is only a yes/no", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/payment-providers", { waitUntil: "networkidle" });
  const pick = page.getByLabel("الفرع", { exact: true });
  await pick.selectOption({ label: "فرع الرياض — طريق الملك فهد" });
  const inputs = page.locator("input");
  await page.locator("select.input").nth(1).selectOption("moyasar");
  await inputs.nth(0).fill("MERCH-RIY-1");
  await inputs.nth(1).fill("pk_test_synthetic_riyadh");
  await inputs.nth(2).fill("sk_test_synthetic_9876");
  await page.getByTestId("save-payment-settings").click();
  await expect(page.getByText("حُفظت إعدادات الدفع.")).toBeVisible();
  await pick.selectOption({ label: "جميع الفروع" });
  const rows = page.getByTestId("payment-branch-row");
  await expect(rows).toHaveCount(2);
  const riy = page.getByTestId("payment-all").locator("> div").filter({ hasText: "الرياض" }).first();
  const jed = page.getByTestId("payment-all").locator("> div").filter({ hasText: "الكورنيش" }).first();
  await expect(riy).toContainText("MERCH-RIY-1");
  await expect(riy).toContainText("ميسّر");
  await expect(riy).toContainText("محفوظ ومشفّر");
  await expect(riy).toContainText("البيانات مكتملة");
  await expect(jed).not.toContainText("MERCH-RIY-1");
  await expect(jed).toContainText("لم يُختر");
  await expect(jed).toContainText("غير مُدخل");
  await expect(jed).toContainText("البيانات غير مكتملة");
  const body = await page.locator("body").innerText();
  expect(body).not.toContain("pk_test_synthetic_riyadh");
  expect(body).not.toContain("sk_test_synthetic_9876");
  expect(body).not.toContain("9876");
});

test("AB-C1 cash accounts: the owner's all-branches view lists both branches' accounts with a branch tag, read-only, and opens a branch to edit", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/cash-accounts", { waitUntil: "networkidle" });
  await page.locator(`select[aria-label="الفرع النشط"]`).first().selectOption({ label: "جميع الفروع" });
  await page.getByTestId("cash-branch").first().waitFor();
  const tags = await page.getByTestId("cash-branch").allInnerTexts();
  expect(new Set(tags).size).toBe(2);
  await expect(page.getByRole("button", { name: "تعديل", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /إضافة/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /أرشفة|استعادة/ })).toHaveCount(0);
  await page.getByTestId("cash-open-branch").first().click();
  await expect(page.getByTestId("cash-branch")).toHaveCount(0);
});

test("AB-C2 cash accounts: each bank row's guide link opens that row's own branch form", async ({ page, loginAs }) => {
  await loginAs("owner");
  for (const [city, expected] of [["الكورنيش", /جدة|الكورنيش/], ["الملك فهد", /الرياض|الملك/]] as const) {
    await page.goto("/#/admin/cash-accounts", { waitUntil: "networkidle" });
    await page.locator(`select[aria-label="الفرع النشط"]`).first().selectOption({ label: "جميع الفروع" });
    await page.getByTestId("cash-branch").first().waitFor();
    const card = page.getByTestId("cash-account").filter({ hasText: city }).filter({ has: page.getByRole("link", { name: /دليل الفرع/ }) }).first();
    await card.getByRole("link", { name: /دليل الفرع/ }).click();
    const dlg = page.getByRole("dialog");
    await expect(dlg).toBeVisible();
    await expect(dlg.locator("input").first()).toHaveValue(expected);
    await page.keyboard.press("Escape");
  }
});

test("AB-Y1 policies: the owner's all-branches list tags each policy with its branch, is read-only, and opens a branch to edit", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/policies", { waitUntil: "networkidle" });
  await page.locator(`select[aria-label="الفرع النشط"]`).first().selectOption({ label: "جميع الفروع" });
  await page.getByTestId("admin-row-branch").first().waitFor();
  await expect(page.getByRole("button", { name: /سياسة جديدة/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^(تعديل|أرشفة) / })).toHaveCount(0);
  await page.getByTestId("admin-row-open-branch").first().click();
  await expect(page.getByTestId("admin-row-branch")).toHaveCount(0);
  await expect(page.getByRole("button", { name: /سياسة جديدة/ })).toBeVisible();
});

test("AB-K2 knowledge: the owner's all-branches view shows each answer once with its branch or «كل الفروع», read-only, and opens a branch to edit", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/knowledge", { waitUntil: "networkidle" });
  const perBranch = await page.getByRole("heading", { level: 3 }).allInnerTexts();
  await page.locator(`select[aria-label="الفرع النشط"]`).first().selectOption({ label: "جميع الفروع" });
  await page.getByTestId("kb-readonly-note").waitFor();
  const titles = await page.getByRole("heading", { level: 3 }).allInnerTexts();
  expect(new Set(titles).size).toBe(titles.length);
  expect(titles.length).toBeGreaterThanOrEqual(perBranch.length);
  await expect(page.getByRole("button", { name: /سؤال وجواب/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^(تعديل|أرشفة): / })).toHaveCount(0);
  await expect(page.getByTestId("admin-row-branch").first()).toBeVisible();
});

test("AB-K3 knowledge: an answer written for Jeddah only is tagged Jeddah, and an all-branches answer shows once, in the owner's all-branches view", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/knowledge", { waitUntil: "networkidle" });
  const pick = page.locator(`select[aria-label="الفرع النشط"]`).first();
  await pick.selectOption({ label: "فرع جدة — الكورنيش" });
  for (const [q, a, scope] of [["سؤال جدة فقط؟", "جواب جدة فقط", "branch"], ["سؤال كل الفروع؟", "جواب كل الفروع", "org"]] as const) {
    await page.getByRole("button", { name: /سؤال وجواب/ }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByRole("textbox").nth(0).fill(q);
    await dlg.locator("textarea").first().fill(a);
    await dlg.locator("select").nth(1).selectOption(scope);
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg).toBeHidden();
  }
  await pick.selectOption({ label: "جميع الفروع" });
  await page.getByTestId("kb-readonly-note").waitFor();
  const jed = page.getByRole("heading", { level: 3, name: "سؤال جدة فقط؟" });
  await expect(jed).toHaveCount(1);
  await expect(page.locator("div.card, [class*=card]").filter({ has: jed }).first()).toContainText("الكورنيش");
  await expect(page.getByRole("heading", { level: 3, name: "سؤال كل الفروع؟" })).toHaveCount(1);
  await expect(page.locator("div.card, [class*=card]").filter({ has: page.getByRole("heading", { level: 3, name: "سؤال كل الفروع؟" }) }).first()).toContainText("كل الفروع");
});

test("AB-S2 structure: the owner's all-branches view tags each block with its branch, is read-only, and opens the block's own branch", async ({ page, loginAs }) => {
  await loginAs("owner");
  await page.goto("/#/admin/structure", { waitUntil: "networkidle" });
  await page.locator(`select[aria-label="الفرع النشط"]`).first().selectOption({ label: "جميع الفروع" });
  await page.getByTestId("admin-row-branch").first().waitFor();
  const tags = await page.getByTestId("admin-row-branch").allInnerTexts();
  expect(new Set(tags).size).toBe(2);
  await expect(page.getByRole("button", { name: /بلوك جديد/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^تعديل$|تعديل الطابق/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^طابق$/ })).toHaveCount(0);
  await page.getByTestId("admin-row-open-branch").last().click();
  await expect(page.getByTestId("admin-row-branch")).toHaveCount(0);
  await expect(page.getByRole("button", { name: /بلوك جديد/ })).toBeVisible();
});
