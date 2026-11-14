/**
 * Products and orders through the UI (W1, migration 0068) — the UI facet of tests/sql/products_w1_tests.sql and the
 * demo tests PD20–PD26: the owner keeps the catalogue and what each branch offers; the reception orders for a guest in
 * their room, takes the payment (the voucher and the delivery task with it), and the order is delivered when the task
 * is done in «خدمة الغرف»; a waiting order is cancelled with a reason; housekeeping has no orders screen.
 */
import { test, expect } from "./fixtures";
import type { Page } from "@playwright/test";

async function signOut(page: Page) {
  await page.locator('[title="تسجيل الخروج"]:visible, [aria-label="تسجيل الخروج"]:visible').first().click();
  await expect(page).toHaveURL(/#\/staff\/login/);
}

test.describe("products and orders", () => {
  test("PD40 the owner sees the example catalogue, adds a product with its price and makes it available in a branch", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/products");
    await expect(page.getByTestId("product-category")).toHaveCount(3);
    await expect(page.getByTestId("product-card")).toHaveCount(12);
    await page.getByRole("button", { name: "منتج جديد" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("اسم المنتج").fill("حليب");
    await dlg.getByLabel("السعر").fill("3.50");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg).toBeHidden();
    const card = page.getByTestId("product-card").filter({ hasText: "حليب" });
    await expect(card).toContainText("3.50");
    // not offered anywhere until made available
    const sw = card.getByRole("switch").first();
    await expect(sw).toHaveAttribute("aria-checked", "false");
    await sw.click();
    await expect(card.getByRole("switch").first()).toHaveAttribute("aria-checked", "true");
    // a duplicate name is refused with its reason
    await page.getByRole("button", { name: "منتج جديد" }).click();
    await dlg.getByLabel("اسم المنتج").fill("حليب");
    await dlg.getByLabel("السعر").fill("1");
    await dlg.getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(dlg.getByRole("alert")).toContainText("الاسم مستخدم مسبقًا");
  });

  test("PD43 the owner pastes a list: it is read line by line first, a bad line says why, then the new products are added and made available", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/admin/products");
    await page.getByRole("button", { name: "استيراد قائمة" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("القائمة").fill(["حلويات، كعك، 6.50", "حلويات، معمول، ٤", "مشروبات، ماء صغير، 2", "حلويات، بلا سعر"].join("\n"));
    await expect(dlg.getByTestId("import-preview")).toContainText("سيُضاف منتجان. وتُنشأ فئة: حلويات.");
    await expect(dlg.getByTestId("import-line").filter({ hasText: "ماء صغير" })).toContainText("موجود — يُترك");
    await expect(dlg.getByTestId("import-line").filter({ hasText: "بلا سعر" })).toContainText("السعر غير مقروء");
    await dlg.getByRole("button", { name: "استيراد (2)" }).click();
    await expect(dlg).toBeHidden();
    const cat = page.getByTestId("product-category").filter({ hasText: "حلويات" });
    await expect(cat.getByTestId("product-card")).toHaveCount(2);
    await expect(cat.getByTestId("product-card").filter({ hasText: "معمول" })).toContainText("4.00");
    // made available in the branches ticked (all of the owner's by default)
    for (const sw of await cat.getByTestId("product-card").first().getByRole("switch").all()) await expect(sw).toHaveAttribute("aria-checked", "true");
  });

  test("PD41 the reception orders for a guest in their room, takes the payment, and the order is delivered when its task is done", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/orders");
    await expect(page.getByText("لا طلبات مفتوحة")).toBeVisible();
    await page.getByRole("button", { name: "طلب لنزيل" }).click();
    const dlg = page.getByRole("dialog");
    // the guests in their rooms, by room: room 101 first
    await expect(dlg.getByLabel("النزيل").locator("option:checked")).toHaveText(/^غرفة 101 — /);
    await dlg.getByRole("button", { name: "زيادة ماء صغير" }).click();
    await dlg.getByRole("button", { name: "زيادة ماء صغير" }).click();
    await dlg.getByRole("button", { name: "زيادة شاحن جوال" }).click();
    await expect(dlg.getByTestId("order-subtotal")).toContainText("29.00");
    await dlg.getByRole("button", { name: "إنشاء الطلب" }).click();
    await expect(dlg).toBeHidden();
    const order = page.getByTestId("product-order").first();
    await expect(order.getByTestId("order-status")).toHaveText("بانتظار الدفع");
    await expect(order.getByTestId("order-lines")).toContainText("2 × ماء صغير");
    await order.getByRole("button", { name: "تسلّم الدفع" }).click();
    await expect(dlg.getByRole("radio", { name: "آجل عبر المنصة" })).toHaveCount(0);   // paid at the hotel only
    await dlg.getByRole("button", { name: /^تسلّم .* وإنشاء مهمة التسليم$/ }).click();
    await expect(dlg).toBeHidden();
    await expect(order.getByTestId("order-status")).toHaveText("بانتظار التسليم");
    await expect(order).toContainText("سند القبض RCP-");
    await expect(order).toContainText("مهمة التسليم: لم تبدأ");
    // the delivery task is in «خدمة الغرف» for room 101; done → the order is delivered
    await go("/staff/housekeeping");
    const task = page.getByTestId("hk-task").filter({ hasText: "تسليم طلب منتجات" }).first();
    await expect(task).toContainText("وحدة 101");
    await expect(task).toContainText("2 × ماء صغير");
    await task.getByRole("button", { name: "إتمام" }).click();
    await task.getByRole("button", { name: "لم تبدأ بعد — تأكيد الإتمام" }).click();
    await expect(page.getByText("سُلِّم الطلب للغرفة.")).toBeVisible();
    await go("/staff/orders");
    await page.getByRole("tab", { name: "سُلِّمت" }).click();
    await expect(page.getByTestId("product-order").first().getByTestId("order-status")).toHaveText("سُلِّم");
  });

  test("PD42 a waiting order is cancelled with a reason; housekeeping has no orders screen", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/orders");
    await page.getByRole("button", { name: "طلب لنزيل" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByRole("button", { name: "زيادة بسكويت" }).click();
    await dlg.getByRole("button", { name: "إنشاء الطلب" }).click();
    await expect(dlg).toBeHidden();
    const order = page.getByTestId("product-order").first();
    await order.getByRole("button", { name: "إلغاء الطلب" }).click();
    await dlg.getByRole("button", { name: "إلغاء الطلب" }).click();
    await expect(dlg.getByRole("alert")).toContainText("سبب");
    await dlg.getByLabel(/السبب/).fill("طلبه النزيل بالخطأ");
    await dlg.getByRole("button", { name: "إلغاء الطلب" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByText("لا طلبات مفتوحة")).toBeVisible();
    await page.getByRole("tab", { name: "ملغاة" }).click();
    await expect(page.getByTestId("product-order").first()).toContainText("سبب الإلغاء: طلبه النزيل بالخطأ");

    await signOut(page);
    await loginAs("housekeeping");
    await go("/staff/orders");
    await expect(page.getByTestId("product-orders")).toHaveCount(0);
    await expect(page.getByRole("link", { name: "طلبات المنتجات" })).toHaveCount(0);
  });
});
