/**
 * Plan 3.3 — the gallery renders every approved base component and its states on the demo build, at desktop and
 * phone width (لقطات مقارنة مرئية على المقاسين). Descriptive names, no test codes: the prefix registration is
 * reported to the integrator with the work package.
 */
import { test, expect } from "./fixtures";

const SIZES = [
  { name: "سطح المكتب 1366", width: 1366, height: 900 },
  { name: "الجوال 390", width: 390, height: 844 },
];

for (const size of SIZES) {
  test(`المعرض يعرض كل مكوّن معتمد وحالته على ${size.name}`, async ({ page, go }) => {
    await page.setViewportSize({ width: size.width, height: size.height });
    await go("/design-gallery");
    await expect(page.getByRole("heading", { name: "معرض مكوّنات RoomAI" })).toBeVisible();
    for (const section of ["buttons", "fields", "pills", "stats", "ai", "notices", "table", "guest"]) {
      await expect(page.getByTestId(`gallery-${section}`)).toBeVisible();
    }
    // the button variants, including the assistant's own one and the disabled state with its words
    await expect(page.getByRole("button", { name: "سجّل الوصول" })).toBeVisible();
    await expect(page.getByRole("button", { name: "اسأل المساعد" })).toBeVisible();
    await expect(page.getByRole("button", { name: "يُحفظ…" })).toBeDisabled();
    // the five unit states, each with its word — colour never carries the meaning alone
    for (const word of ["متاحة", "محجوزة", "مشغولة", "قيد التنظيف", "خارج الخدمة"]) {
      await expect(page.getByText(word, { exact: true }).first()).toBeVisible();
    }
    // the assistant proposes in its own card; a person decides; the error notice is an alert
    await expect(page.getByText("اقتراح من المساعد")).toBeVisible();
    await expect(page.getByRole("alert")).toHaveCount(2); // the danger notice and the field error
    // the guest base: the hotel speaks first, RoomAI only in the footer line
    await expect(page.getByText("فايف اورز")).toBeVisible();
    await expect(page.getByText("يعمل بـ RoomAI")).toBeVisible();
    // acting on the suggestion is the reader's choice
    await page.getByTestId("gallery-ai").getByRole("button", { name: "تجاهل" }).click();
    await expect(page.getByText("تم تجاهل الاقتراح. يبقى القرار للموظف دائمًا.")).toBeVisible();
  });
}
