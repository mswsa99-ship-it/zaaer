import { test, expect, type Page } from "./fixtures";

// the demo's test hook, driven through sessionStorage so it survives a reload
const installFailHook = (page: Page) => page.addInitScript(() => {
  (window as unknown as { __demoFail: unknown }).__demoFail = (t: string) => { try { const f = JSON.parse(sessionStorage.getItem("e2e-fail") ?? "null"); return f && t === `rpc:${f.rpc}` ? f.msg : null; } catch { return null; } };
});
const failRpc = (page: Page, rpc: string, message: string) => page.evaluate(([r, m]) => sessionStorage.setItem("e2e-fail", JSON.stringify({ rpc: r, msg: m })), [rpc, message] as const);
const clearFail = (page: Page) => page.evaluate(() => sessionStorage.removeItem("e2e-fail"));
const reload = async (page: Page) => { await page.reload({ waitUntil: "networkidle" }); await page.waitForTimeout(300); };

for (const width of [390, 1280]) {
  test(`policies ${width}: server failure shows a retryable notice and never looks like "no hotel policies"; a refusal stays quiet; old CRUD works`, async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width, height: 900 });
    await installFailHook(page);
    await loginAs("owner"); await go("/admin/policies");
    await failRpc(page, "fn_policy_masters_list", "network down"); await reload(page);
    await expect(page.getByTestId("masters-error")).toBeVisible();
    await page.getByRole("combobox").first().selectOption({ label: "جميع الفروع" });
    await expect(page.getByTestId("hotel-policies")).toHaveCount(0);                 // hidden, not an empty list
    await clearFail(page);
    await page.getByTestId("masters-error").getByRole("button", { name: "إعادة المحاولة" }).click();
    await expect(page.getByTestId("masters-error")).toHaveCount(0);                  // retry recovers
    await failRpc(page, "fn_policy_masters_list", "permission denied for function"); await reload(page);
    await expect(page.getByTestId("masters-error")).toHaveCount(0);                  // refusal: inheritance quietly absent
    const pk = page.getByRole("combobox").first();
    const o = await pk.locator("option").evaluateAll((l) => (l as HTMLOptionElement[]).map((x) => ({ v: x.value, t: x.textContent ?? "" })));
    await pk.selectOption(o.find((x) => x.t !== "جميع الفروع")!.v);
    await expect(page.getByRole("button", { name: "سياسة جديدة" }).first()).toBeVisible();   // old branch CRUD still usable
  });
  test(`knowledge ${width}: effective-origin failure shows a notice, answers stay editable; a refusal stays quiet`, async ({ page, loginAs, go }) => {
    await page.setViewportSize({ width, height: 900 });
    await installFailHook(page);
    await loginAs("owner"); await go("/admin/knowledge");
    const picker = page.getByRole("combobox").first();
    const opts = await picker.locator("option").evaluateAll((l) => (l as HTMLOptionElement[]).map((x) => ({ v: x.value, t: x.textContent ?? "" })));
    await picker.selectOption(opts.find((x) => x.t !== "جميع الفروع")!.v);
    await failRpc(page, "fn_knowledge_effective", "network down");
    await picker.selectOption(opts.filter((x) => x.t !== "جميع الفروع")[1]?.v ?? opts[0].v);
    await page.waitForTimeout(500);
    await expect(page.getByTestId("origins-error")).toBeVisible();
    await expect(page.getByRole("button", { name: "سؤال وجواب" })).toBeVisible();      // old CRUD not blocked
    await failRpc(page, "fn_knowledge_effective", "permission denied for function");
    await picker.selectOption(opts.filter((x) => x.t !== "جميع الفروع")[0].v);
    await page.waitForTimeout(500);
    await expect(page.getByTestId("origins-error")).toHaveCount(0);
  });
  test(`policies ${width}: hotel policy preview, keep own text, overwrite only the chosen branch`, async ({ page, loginAs, go }) => {
    test.setTimeout(60_000);
    await page.setViewportSize({ width, height: 900 });
    await loginAs("owner"); await go("/admin/policies");
    const picker = page.getByRole("combobox").first();
    await picker.selectOption({ label: "جميع الفروع" });
    await expect(page.getByTestId("masters-error")).toHaveCount(0);
    // 1) create a hotel-level policy for a topic every demo branch already has: branches keep their own existing text
    await page.getByRole("button", { name: "سياسة للفندق" }).click();
    let dlg = page.getByRole("dialog");
    await dlg.getByLabel("العنوان").fill("سياسة الفندق الموحدة");
    await dlg.getByLabel("النص").fill("نص الفندق الأول");
    await dlg.getByRole("button", { name: /معاينة/ }).click();
    const pv = page.getByTestId("inheritance-preview");
    await expect(pv).toBeVisible();
    await page.screenshot({ path: `${process.env.E2E_SHOT_DIR ?? "test-results/screens"}/hotel-preview-1-${width}.png` });
    for (const b of await pv.locator('[data-testid^="overwrite-"]').all()) await expect(b).not.toBeChecked();   // never selected by default
    await page.getByTestId("inheritance-confirm").click();
    const master = page.locator('[data-testid^="master-"]').first();
    await expect(master).toContainText("نص الفندق الأول");
    // 2) change the hotel text; branches with their own text keep it unless chosen
    await master.getByRole("button", { name: /^تعديل .* للفندق$/ }).click();
    dlg = page.getByRole("dialog");
    await dlg.getByLabel("النص").fill("نص الفندق الثاني");
    await dlg.getByRole("button", { name: /معاينة/ }).click();
    await expect(pv).toBeVisible();
    const boxes = pv.locator('[data-testid^="overwrite-"]');
    const n = await boxes.count();
    await page.screenshot({ path: `${process.env.E2E_SHOT_DIR ?? "test-results/screens"}/hotel-preview-2-${width}.png` });
    expect(n).toBe(1);                                    // only the branch that kept its own text is offered
    for (const b of await boxes.all()) await expect(b).not.toBeChecked();
    await page.getByTestId("inheritance-confirm").click();   // unchecked: that branch keeps its text
    await expect(page.getByTestId("inheritance-preview")).toHaveCount(0);
    const pick = async (name: RegExp) => { const o = await picker.locator("option").evaluateAll((l) => (l as HTMLOptionElement[]).map((x) => ({ v: x.value, t: x.textContent ?? "" }))); await picker.selectOption(o.find((x) => name.test(x.t))!.v); await page.waitForTimeout(500); };
    await pick(/الرياض/); await expect(page.locator("main")).not.toContainText("نص الفندق الثاني");
    await pick(/جدة/); await expect(page.locator("main")).toContainText("نص الفندق الثاني");
    // 3) choose the branch that kept its own text: now it follows the hotel
    await picker.selectOption({ label: "جميع الفروع" });
    await page.locator('[data-testid^="master-"]').first().getByRole("button", { name: /^تعديل .* للفندق$/ }).click();
    dlg = page.getByRole("dialog");
    await dlg.getByLabel("النص").fill("نص الفندق الثالث");
    await dlg.getByRole("button", { name: /معاينة/ }).click();
    await page.locator('[data-testid^="overwrite-"]').first().check();
    await page.getByTestId("inheritance-confirm").click();
    await expect(page.getByTestId("inheritance-preview")).toHaveCount(0);
    await pick(/الرياض/); await expect(page.locator("main")).toContainText("نص الفندق الثالث");
    await pick(/جدة/); await expect(page.locator("main")).toContainText("نص الفندق الثالث");
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
}

for (const width of [390, 1280]) test(`knowledge ${width}: override and revert a shared answer; the shared one is not listed beside the override`, async ({ page, loginAs, go }) => {
  test.setTimeout(60_000);
  await page.setViewportSize({ width, height: 900 });
  await loginAs("owner"); await go("/admin/knowledge");
  const picker = page.getByRole("combobox").first();
  const opts = await picker.locator("option").evaluateAll((l) => (l as HTMLOptionElement[]).map((x) => ({ v: x.value, t: x.textContent ?? "" })));
  await picker.selectOption(opts.find((x) => x.t !== "جميع الفروع")!.v);
  await expect(page.getByTestId("origins-error")).toHaveCount(0);
  // a hotel-wide answer ("كل الفروع"), created from inside the branch
  const question = "هل يوجد موقف سيارات مجاني للضيوف؟";
  await page.getByRole("button", { name: "سؤال وجواب" }).click();
  const dlg = page.getByRole("dialog");
  await dlg.getByLabel("السؤال كما يطرحه النزيل (مطلوب)").fill(question);
  await dlg.getByLabel("الإجابة التي تُرسل للنزيل حرفيًا (مطلوب)").fill("نعم، الموقف مجاني.");
  await dlg.getByLabel("النطاق").selectOption("org");
  await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
  await expect(page.getByRole("heading", { name: question, exact: true })).toHaveCount(1);
  const shared = page.getByTestId("kb-override");
  await shared.first().click();
  await expect(page.getByTestId("kb-override-badge")).toHaveCount(1);
  await expect(page.getByRole("heading", { name: question, exact: true })).toHaveCount(1);   // override shown, shared hidden
  // the all-branches editor still reaches the shared (hotel-level) answer even though this branch has its own version
  await picker.selectOption({ label: "جميع الفروع" });
  await expect(page.getByRole("heading", { name: question, exact: true })).toHaveCount(2);   // editor: hotel master AND the branch's own version
  await expect(page.getByTestId("admin-row-branch").filter({ hasText: "كل الفروع" })).toHaveCount(1);
  await picker.selectOption(opts.find((x) => x.t !== "جميع الفروع")!.v);
  await expect(page.getByTestId("kb-override-badge")).toHaveCount(1);
  await page.getByTestId("kb-revert").first().click();
  await expect(page.getByTestId("kb-override-badge")).toHaveCount(0);
  await expect(page.getByRole("heading", { name: question, exact: true })).toHaveCount(1);
});

// --- knowledge: hotel-wide edit goes through the server preview; limited managers see a name-free note; supervisor is refused
const Q = "هل يوجد مسبح للأطفال؟";
async function createSharedAnswer(page: Page, go: (p: string) => Promise<void>) {
  await go("/admin/knowledge");
  const picker = page.getByRole("combobox").first();
  const opts = await picker.locator("option").evaluateAll((l) => (l as HTMLOptionElement[]).map((x) => ({ v: x.value, t: x.textContent ?? "" })));
  await picker.selectOption(opts.find((x) => x.t !== "جميع الفروع")!.v);
  await page.getByRole("button", { name: "سؤال وجواب" }).click();
  const dlg = page.getByRole("dialog");
  await dlg.getByLabel("السؤال كما يطرحه النزيل (مطلوب)").fill(Q);
  await dlg.getByLabel("الإجابة التي تُرسل للنزيل حرفيًا (مطلوب)").fill("نعم، المسبح مفتوح.");
  await dlg.getByLabel("النطاق").selectOption("org");
  await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
  await expect(page.getByRole("heading", { name: Q, exact: true })).toHaveCount(1);
  return { picker, opts };
}
for (const width of [390, 1280]) {
  test(`knowledge ${width}: hotel-wide answer edit previews, keeps a branch override unless chosen, applies`, async ({ page, loginAs, go }) => {
    test.setTimeout(60_000);
    await page.setViewportSize({ width, height: 900 });
    await loginAs("owner");
    const { picker, opts } = await createSharedAnswer(page, go);
    const branches = opts.filter((x) => x.t !== "جميع الفروع");
    // branch A makes its own version
    await page.getByTestId("kb-override").first().click();
    await expect(page.getByTestId("kb-override-badge")).toHaveCount(1);
    // edit the hotel-wide answer from branch B (a branch without its own version)
    await picker.selectOption(branches[1].v);
    await page.getByRole("button", { name: `تعديل: ${Q}` }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("الإجابة التي تُرسل للنزيل حرفيًا (مطلوب)").fill("المسبح مفتوح من 8 إلى 10.");
    await dlg.getByLabel("سبب التعديل (يُسجَّل في سجل العمليات)").fill("تحديث الساعات");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    const pv = page.getByTestId("inheritance-preview");
    await expect(pv).toBeVisible();
    await page.screenshot({ path: `${process.env.E2E_SHOT_DIR ?? "test-results/screens"}/kb-hotel-preview-${width}.png` });
    const boxes = pv.locator('[data-testid^="overwrite-"]');
    expect(await boxes.count()).toBe(1);                       // only the branch with its own version
    await expect(boxes.first()).not.toBeChecked();
    await page.getByTestId("inheritance-confirm").click();     // unchecked: branch A keeps its own version
    await expect(pv).toHaveCount(0);
    await expect(page.getByText("المسبح مفتوح من 8 إلى 10.")).toBeVisible();   // branch B inherited the update
    await picker.selectOption(branches[0].v);
    await expect(page.getByText("المسبح مفتوح من 8 إلى 10.")).toHaveCount(0);   // branch A kept its own
    await expect(page.getByTestId("kb-override-badge")).toHaveCount(1);
  });
  test(`knowledge ${width}: supervisor is refused a hotel-wide edit by the server and the page says so`, async ({ page, loginAs, go }) => {
    test.setTimeout(60_000);
    await page.setViewportSize({ width, height: 900 });
    await loginAs("owner");
    await createSharedAnswer(page, go);
    await page.getByRole("button", { name: "تسجيل الخروج" }).click();
    await loginAs("supervisor"); await go("/admin/knowledge");
    const editBtn = page.getByRole("button", { name: `تعديل: ${Q}` });
    test.skip((await editBtn.count()) === 0, "supervisor sees no edit button for the hotel-wide answer (UI already blocks it)");
    await editBtn.click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("الإجابة التي تُرسل للنزيل حرفيًا (مطلوب)").fill("محاولة تعديل غير مسموحة");
    await dlg.getByLabel("سبب التعديل (يُسجَّل في سجل العمليات)").fill("اختبار");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(page.getByTestId("inheritance-preview")).toHaveCount(0);   // no preview, nothing applied
    await expect(dlg.getByRole("alert")).toBeVisible();                     // the refusal is shown, not swallowed
  });
}

for (const width of [390, 1280]) test(`knowledge ${width}: a manager who sees fewer branches gets a name-free note about the others`, async ({ page, loginAs, go }) => {
  test.setTimeout(60_000);
  await page.setViewportSize({ width, height: 900 });
  await loginAs("owner");
  const { opts } = await createSharedAnswer(page, go);
  const total = opts.filter((x) => x.t !== "جميع الفروع").length;
  // controlled fixture (demo data only): the manager keeps access to one branch, so the others are hidden from them
  await page.waitForTimeout(400);
  await page.evaluate(() => {
    const key = Object.keys(localStorage).find((k) => (localStorage.getItem(k) ?? "").includes('"branch_memberships"'))!;
    const st = JSON.parse(localStorage.getItem(key)!);
    const mgr = st.staff_profiles.find((x: { email: string }) => x.email === "manager@demo.sa");
    const mine = st.branch_memberships.filter((m: { staff_id: string; removed_at: string | null }) => m.staff_id === mgr.id && !m.removed_at);
    mine.slice(1).forEach((m: { removed_at: string | null }) => { m.removed_at = new Date().toISOString(); });
    localStorage.setItem(key, JSON.stringify(st));
  });
  await page.reload({ waitUntil: "networkidle" });
  await page.getByRole("button", { name: "تسجيل الخروج" }).click();
  await loginAs("manager"); await go("/admin/knowledge");
  const visible = 1;   // the fixture left the manager one branch (a single-branch user gets no picker)
  expect(total).toBeGreaterThan(visible);
  await page.getByRole("button", { name: `تعديل: ${Q}` }).click();
  const dlg = page.getByRole("dialog");
  await dlg.getByLabel("الإجابة التي تُرسل للنزيل حرفيًا (مطلوب)").fill("إجابة محدثة من مدير فرع");
  await dlg.getByLabel("سبب التعديل (يُسجَّل في سجل العمليات)").fill("اختبار");
  await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
  const note = page.getByTestId("plan-hidden");
  await expect(note).toBeVisible();
  await expect(note).toContainText("فروع أخرى خارج صلاحيتك لرؤيتها");
  await expect(page.locator('li[data-testid^="plan-"]')).toHaveCount(visible);   // only the branches the manager may see are listed, hidden ones are only counted
  await expect(note).toContainText(`${total - visible} ستتحدّث`);
});
