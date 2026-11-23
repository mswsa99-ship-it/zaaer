/**
 * The accounts (0074, owner's decisions of 23 Nov 2026) through the staff UI — the UI facet of tests/sql/accounts_tests.sql
 * and the unit tests AU20–AU27: «نسيت كلمة المرور؟» with the same answer for any address, «تعيين كلمة المرور» (the page
 * every e-mailed link opens) with the rule of 6 characters, letters and digits, «حسابي» (change the password, the link
 * to one's own e-mail, signing out every device), the colleague's link and the owner's invitation, and the owner's
 * «security» log that records each of them. The demo sends no e-mail; the screens and the log are the same.
 */
import { test, expect } from "./fixtures";

test.describe("user accounts", () => {
  test("AU30 «نسيت كلمة المرور؟» answers the same for any address, and leads back to signing in", async ({ page, errors }) => {
    void errors;
    await page.goto("/#/staff/login", { waitUntil: "networkidle" });
    await page.getByTestId("forgot-password").click();
    await expect(page.getByLabel("كلمة المرور")).toHaveCount(0);
    await page.getByLabel("البريد الإلكتروني").fill("nobody@example.com");
    await page.getByRole("button", { name: "إرسال رابط التعيين" }).click();
    await expect(page.getByTestId("login-notice")).toContainText("إن كان هذا البريد مسجّلًا");
    await page.getByRole("button", { name: "رجوع إلى تسجيل الدخول" }).click();
    await expect(page.getByLabel("كلمة المرور")).toBeVisible();
    await expect(page.getByTestId("forgot-password")).toBeVisible();
  });

  test("AU31 «تعيين كلمة المرور» opened by hand, or from an expired link, says so and offers a new link", async ({ page, go, errors }) => {
    void errors;
    await go("/staff/reset-password");
    await expect(page.getByTestId("reset-invalid")).toContainText("افتح هذه الصفحة من الرابط", { timeout: 8000 });
    // a link always opens a fresh page (a hash change on the open page would not reload it)
    await page.goto("about:blank");
    await page.goto("/#/staff/reset-password#error=access_denied&error_code=otp_expired", { waitUntil: "networkidle" });
    await expect(page.getByTestId("reset-invalid")).toContainText("انتهت صلاحية الرابط");
  });

  test("AU32 with the link's session the new password keeps the rule, must be typed twice, and then leads into the system", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/reset-password");
    await expect(page.getByTestId("reset-password")).toBeVisible();
    await page.getByLabel("كلمة المرور الجديدة").fill("abcdef");
    await page.getByLabel("أعد كتابتها").fill("abcdef");
    await page.getByTestId("reset-submit").click();
    await expect(page.getByTestId("reset-password")).toContainText("رقمًا");
    await page.getByLabel("كلمة المرور الجديدة").fill("room2026");
    await page.getByLabel("أعد كتابتها").fill("room2027");
    await page.getByTestId("reset-submit").click();
    await expect(page.getByTestId("reset-password")).toContainText("غير متطابقتين");
    await page.getByLabel("أعد كتابتها").fill("room2026");
    await page.getByTestId("reset-submit").click();
    await expect(page.getByTestId("reset-done")).toBeVisible();
    await page.getByRole("button", { name: "متابعة إلى النظام" }).click();
    await page.waitForURL(/#\/(staff|admin)\/(?!reset-password)/);
  });

  test("AU33 «حسابي»: the password changed, the link to one's own e-mail, each in the owner's «security» log in Arabic", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await page.getByTestId("my-account-link").first().click();
    await expect(page.getByTestId("account-page")).toBeVisible();
    await page.getByLabel("كلمة المرور الجديدة").fill("123456");
    await page.getByLabel("أعد كتابتها").fill("123456");
    await page.getByTestId("account-save-password").click();
    await expect(page.getByTestId("account-page")).toContainText("حرفًا إنجليزيًا");
    await page.getByLabel("كلمة المرور الجديدة").fill("hotel99");
    await page.getByLabel("أعد كتابتها").fill("hotel99");
    await page.getByTestId("account-save-password").click();
    await expect(page.getByTestId("account-notice")).toBeVisible();
    await page.getByTestId("account-email-link").click();
    await expect(page.getByTestId("account-notice")).toContainText("owner@demo.sa");
    await go("/admin/audit-logs");
    const table = page.getByTestId("audit-table");
    for (const label of ["تسجيل دخول", "تغيير كلمة المرور", "إرسال رابط تعيين كلمة المرور"]) {
      await expect(table.locator("tr", { hasText: label }).first(), label).toContainText("أمني");
    }
  });

  test("AU34 «تسجيل الخروج من كل الأجهزة» ends this session too and returns to the sign-in page", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/account");
    await page.getByTestId("account-sign-out-everywhere").click();
    await page.waitForURL(/#\/staff\/login/);
    await expect(page.getByTestId("forgot-password")).toBeVisible();
  });

  test("AU35 the owner sends a colleague a reset link and invites a new person by e-mail; the person without an account gets «دعوة بالبريد»", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/staff");
    const reception = page.locator("[data-testid=staff-card][data-email='reception@demo.sa']");
    await expect(reception.getByTestId("staff-invite-email")).toHaveCount(0);
    await reception.getByTestId("staff-reset-link").click();
    await expect(page.getByTestId("staff-notice")).toContainText("أُرسل رابط تعيين كلمة المرور إلى reception@demo.sa");
    await expect(page.locator("[data-testid=staff-card][data-email='owner@demo.sa']").getByTestId("staff-reset-link")).toHaveCount(0);   // one's own is in «حسابي»
    // a new owner-level person (no branch needed): the invitation e-mail follows at once
    await page.getByLabel("البريد الإلكتروني").first().fill("partner@demo.sa");
    await page.getByLabel("الاسم الكامل").first().fill("شريك جديد");
    await page.getByLabel("الدور").first().selectOption("owner");
    await page.getByRole("button", { name: /^دعوة$|إرسال الدعوة|دعوة الموظف/ }).first().click();
    await expect(page.getByTestId("staff-notice")).toContainText("أُرسلت الدعوة إلى partner@demo.sa");
    const partner = page.locator("[data-testid=staff-card][data-email='partner@demo.sa']");
    await expect(partner.getByTestId("staff-reset-link")).toHaveCount(0);
    await partner.getByTestId("staff-invite-email").click();
    await expect(page.getByTestId("staff-notice")).toContainText("أُرسلت الدعوة إلى partner@demo.sa.");
  });

  test("AU36 a manager sends a link to a supervisor but not to the owner, and sends no invitations", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await go("/admin/staff");
    await expect(page.locator("[data-testid=staff-card][data-email='reception@demo.sa']").getByTestId("staff-reset-link")).toBeVisible();
    await expect(page.locator("[data-testid=staff-card][data-email='owner@demo.sa']").getByTestId("staff-reset-link")).toHaveCount(0);
    await expect(page.getByTestId("staff-invite-email")).toHaveCount(0);
  });
});
