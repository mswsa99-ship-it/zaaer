/**
 * The bank's messages through the UI (A6/A7, migration 0066) — the UI facet of tests/sql/accounting_a6_tests.sql and the
 * demo test BK01–BK05: the owner sets the mailbox (the password never shown back), makes the relay key (shown once), adds
 * a word and reads an unread message again; the movements show with their kind, amount and account; the manager sees
 * the movements but not the raw messages. And matching them (A8, migration 0067; tests/sql/accounting_a8_tests.sql): a
 * movement turned into income and undone, a deposit matched with the card vouchers it covers, a fee recorded as the
 * bank's fees and shown in the ledger.
 */
import { test, expect, createReservation } from "./fixtures";

test.describe("bank messages", () => {
  test("BK30 the owner sets the bank mailbox: not connected until complete, the password kept hidden, the relay key shown once", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/bank-mail");
    await expect(page.getByTestId("bank-mail-state")).toHaveText("غير مربوط بعد");
    await page.getByRole("button", { name: "تعديل" }).first().click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("البريد المخصّص").fill("relay@example.com");
    await dlg.getByLabel("اسم الدخول").fill("relay@example.com");
    await dlg.getByLabel("كلمة مرور البريد").fill("app-pass-e2e");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText("محفوظة مشفّرة")).toBeVisible();
    await expect(page.locator("body")).not.toContainText("app-pass-e2e");
    await page.getByRole("button", { name: "إنشاء المفتاح" }).click();
    const key = page.getByTestId("relay-key");
    await expect(key).toHaveText(/^[0-9a-f]{48}$/);
    const value = await key.textContent();
    await page.getByRole("button", { name: "نسخته" }).click();
    await expect(page.locator("body")).not.toContainText(value!);
    await expect(page.getByText(`ينتهي بـ ${value!.slice(-4)}`)).toBeVisible();
    await page.getByLabel("قراءة البريد تلقائيًا").check();
    await expect(page.getByTestId("bank-mail-state")).toHaveText("يعمل");
  });

  test("RL13 the owner gets the phone app's setup text: with the new key once, then without it; the mailbox password is never in it", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/bank-mail");
    await expect(page.getByTestId("relay-app").getByRole("button", { name: "نص الإعداد" })).toBeDisabled();
    await page.getByRole("button", { name: "تعديل" }).first().click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("البريد المخصّص").fill("relay@example.com");
    await dlg.getByLabel("اسم الدخول").fill("relay@example.com");
    await dlg.getByLabel("كلمة مرور البريد").fill("app-pass-rl13");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg).toBeHidden();
    await page.getByRole("button", { name: "إنشاء المفتاح" }).click();
    const key = (await page.getByTestId("relay-key").textContent())!;
    const withKey = page.getByTestId("relay-setup-with-key");
    await expect(withKey).toContainText("FIVEHOURS-SETUP 1");
    await expect(withKey).toContainText("mailbox: relay@example.com");
    await expect(withKey).toContainText("smtp: smtp.gmail.com:465");
    await expect(withKey).toContainText("account: 605…4321");
    await expect(withKey).toContainText(`key: ${key}`);
    await expect(withKey).not.toContainText("app-pass-rl13");
    await page.getByRole("button", { name: "نسخته" }).click();
    await page.getByTestId("relay-app").getByRole("button", { name: "نص الإعداد" }).click();
    const plain = page.getByTestId("relay-setup");
    await expect(plain).toContainText("account: 605…4321");
    await expect(plain).not.toContainText("key:");
    await expect(page.locator("body")).not.toContainText(key);
    await expect(page.locator("body")).not.toContainText("app-pass-rl13");
  });

  test("BK31 the owner reads an unread message again after adding its word; the SMS and the notification are one movement; an unassigned movement gets its branch account", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/bank");
    await page.getByRole("tab", { name: "الرسائل كما وصلت" }).click();
    const unread = page.getByTestId("bank-message").filter({ hasText: "قيد عكسي" });
    await expect(unread).toContainText("لم تُفهم");
    await expect(page.getByTestId("bank-message").filter({ hasText: "مرفوضة" })).toContainText("ليست من بريد التطبيق");
    await go("/admin/bank-mail");
    await page.getByRole("button", { name: "كلمة", exact: true }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("الكلمة").fill("قيد عكسي");
    await dlg.getByLabel("نوع الحركة").selectOption({ label: "دخل آخر" });
    await dlg.getByLabel("الأولوية").fill("5");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(page.getByTestId("bank-rule").filter({ hasText: "قيد عكسي" })).toContainText("داخل");
    await go("/staff/bank");
    await page.getByRole("tab", { name: "الرسائل كما وصلت" }).click();
    await page.getByTestId("bank-message").filter({ hasText: "قيد عكسي" }).getByRole("button", { name: "اقرأها من جديد" }).click();
    await expect(page.getByTestId("bank-message").filter({ hasText: "قيد عكسي" })).toContainText("قُرئت");
    await expect(page.getByTestId("bank-message").filter({ hasText: "مكررة لحركة سابقة" })).toHaveCount(1);
    // a movement of no known account: the owner gives it its branch account with a reason
    await page.getByRole("tab", { name: "غير المنسوبة" }).click();
    const un = page.getByTestId("bank-movement").filter({ hasText: "777****555" });
    await un.getByRole("button", { name: "نسبتها لحساب فرع" }).click();
    const d2 = page.getByRole("dialog");
    await d2.locator("textarea").fill("الحساب الوحيد لدينا بهذه الرسوم");
    await d2.getByRole("button", { name: "نسبتها", exact: true }).click();
    await expect(d2).toBeHidden();
    await expect(page.getByTestId("bank-movement").filter({ hasText: "777****555" })).toHaveCount(0);
  });

  test("BK32 the manager sees the branch's movements, not the raw messages nor the mailbox", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/staff/bank");
    await expect(page.getByRole("tab", { name: "حركات الفرع" })).toBeVisible();
    await expect(page.getByRole("tab", { name: "الرسائل كما وصلت" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "بريد البنك" })).toHaveCount(0);
  });

  test("BK33 the owner gives a movement its branch account, records it as income, and undoes that with a reason (A8)", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/bank");
    await page.getByRole("tab", { name: "غير المنسوبة" }).click();
    await page.getByTestId("bank-movement").filter({ hasText: "777****555" }).getByRole("button", { name: "نسبتها لحساب فرع" }).click();
    const d1 = page.getByRole("dialog");
    const select = d1.getByLabel("حساب الفرع");
    const value = await select.locator("option", { hasText: "الرياض" }).first().getAttribute("value");
    await select.selectOption(value!);
    await d1.locator("textarea").fill("حساب فرع الرياض");
    await d1.getByRole("button", { name: "نسبتها", exact: true }).click();
    await expect(d1).toBeHidden();
    await page.getByRole("tab", { name: "حركات الفرع" }).click();
    const mv = page.getByTestId("bank-movement").filter({ hasText: "+2.00" });
    await expect(mv).toContainText("بانتظار المطابقة");
    await mv.getByRole("button", { name: "تسجيلها إيرادًا" }).click();
    const d2 = page.getByRole("dialog");
    await d2.getByLabel("الوصف").fill("فرق من البنك");
    await d2.getByRole("button", { name: "تسجيل الإيراد" }).click();
    await expect(d2).toBeHidden();
    await expect(mv.getByTestId("bank-match")).toContainText("حُوّلت إلى: إيراد");
    await mv.getByRole("button", { name: "فك المطابقة" }).click();
    const d3 = page.getByRole("dialog");
    await d3.locator("textarea").fill("ليست إيرادًا");
    await d3.getByRole("button", { name: "فك المطابقة", exact: true }).click();
    await expect(d3).toBeHidden();
    await expect(mv).toContainText("بانتظار المطابقة");
  });

  test("BK34 the owner matches a deposit with the card vouchers it covers: a day's vouchers are ticked in one tap, the total is shown, and a total that differs asks for the reason (A8)", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await createReservation(page, "ضيف المطابقة", "0501117788");
    for (const [amount, trx] of [["1.20", "TRX-MT-1"], ["0.80", "TRX-MT-2"]]) {
      await page.getByRole("button", { name: "سند قبض إقامة" }).click();
      const dlg = page.getByRole("dialog");
      await dlg.getByRole("radio", { name: "شبكة" }).click();
      await dlg.locator("input[data-money]").first().fill(amount);
      await dlg.getByLabel("رقم العملية").fill(trx);
      await dlg.getByRole("button", { name: "حفظ السند" }).click();
      await expect(dlg).toBeHidden();
    }
    await go("/staff/bank");
    await page.getByRole("tab", { name: "غير المنسوبة" }).click();
    await page.getByTestId("bank-movement").filter({ hasText: "777****555" }).getByRole("button", { name: "نسبتها لحساب فرع" }).click();
    const d1 = page.getByRole("dialog");
    const select = d1.getByLabel("حساب الفرع");
    await select.selectOption((await select.locator("option", { hasText: "الرياض" }).first().getAttribute("value"))!);
    await d1.locator("textarea").fill("حساب فرع الرياض");
    await d1.getByRole("button", { name: "نسبتها", exact: true }).click();
    await expect(d1).toBeHidden();
    await page.getByRole("tab", { name: "حركات الفرع" }).click();
    const mv = page.getByTestId("bank-movement").filter({ hasText: "+2.00" });
    await mv.getByRole("button", { name: "مطابقة", exact: true }).click();
    const d = page.getByRole("dialog");
    // nothing equals the deposit alone, so nothing is ticked yet; the card vouchers are also offered a day at a time
    const total = d.getByTestId("bank-match-total");
    await expect(total).toContainText("0.00");
    await d.getByText("سندات الشبكة حسب اليوم").click();
    const today = new Date(Date.now() + 3 * 3600_000).toISOString().slice(0, 10);
    const day = d.getByTestId("bank-pos-days").getByRole("button").filter({ hasText: today });
    await day.click();
    await expect(day).toHaveAttribute("aria-pressed", "true");
    // the whole day is more than the deposit: the difference is named and the server asks for its reason
    await expect(d.getByTestId("bank-match-diff")).toContainText("المحدّد أكثر من الحركة");
    await d.getByRole("button", { name: "مطابقة", exact: true }).click();
    await expect(d.getByText(/اكتب سبب الفرق/)).toBeVisible();
    await day.click();
    await expect(day).toHaveAttribute("aria-pressed", "false");
    // the two card payments this deposit covers (the nearest amounts come first)
    const boxes = d.getByTestId("bank-candidates").getByRole("checkbox");
    await boxes.nth(0).check();
    await boxes.nth(1).check();
    await expect(total).toContainText("2.00");
    await expect(d.getByTestId("bank-match-diff")).toHaveCount(0);
    await d.getByRole("button", { name: "مطابقة", exact: true }).click();
    await expect(d).toBeHidden();
    await expect(mv.getByTestId("bank-match")).toContainText("طوبقت مع: السجلات (2)");
    await expect(mv).not.toContainText("بانتظار المطابقة");
  });

  test("BK35 the owner records a fee movement as the bank's fees in one step, and it becomes a line of the bank account's ledger (A8)", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/bank");
    await page.getByLabel("الفرع النشط").selectOption("00000000-0000-0000-0000-000000000012");
    const fee = page.getByTestId("bank-movement").filter({ hasText: "9.60" });
    await expect(fee).toContainText("بانتظار المطابقة");
    await fee.getByRole("button", { name: "تحويلها لسند" }).click();
    const d = page.getByRole("dialog");
    await expect(d.getByRole("radio", { name: /رسوم بنكية/ })).toBeChecked();
    await d.getByRole("button", { name: "تسجيل الرسوم" }).click();
    await expect(d).toBeHidden();
    await expect(fee.getByTestId("bank-match")).toContainText("حُوّلت إلى: رسوم بنكية: رسوم نقاط البيع");
    await go("/staff/ledger");
    const account = page.getByLabel("الحساب");
    await account.selectOption((await account.locator("option", { hasText: "البنكي" }).first().getAttribute("value"))!);
    const line = page.getByTestId("ledger-line").filter({ hasText: "تسوية بنكية" });
    await expect(line).toContainText("9.60");
    await expect(line).toContainText("رسوم بنكية من حركة: رسوم نقاط البيع");
  });
});
