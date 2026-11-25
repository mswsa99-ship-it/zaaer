/**
 * 6.5 for editing an EXISTING record (services, room categories): an unsaved edit survives a reload, is offered back on a
 * click only, is tied to the record's version, and is cleared by a successful save. Synthetic demo data.
 */
import { test, expect } from "./fixtures";
const SHOT_DIR = process.env.E2E_SHOT_DIR ?? "test-results/screens"; // CI has no /downloads folder

const FORMS = [
  { name: "service", path: "/admin/services", edit: /^تعديل الخدمة$/, field: "الوصف", key: "zaaer:service-edit:", banner: "تعديل لم يُحفظ على هذه الخدمة" },
  { name: "room category", path: "/admin/room-categories", edit: /^تعديل /, field: "الوصف", key: "zaaer:room-category-edit:", banner: "تعديل لم يُحفظ على هذا النوع" },
];
for (const f of FORMS) {
  test.describe(`edit-record draft: ${f.name}`, () => {
    test(`${f.name}: edit, reload, reopen the same record, restore; save clears it`, async ({ page, loginAs, go }) => {
      await loginAs("owner");
      await go(f.path);
      await page.getByRole("button", { name: f.edit }).first().click();
      let dlg = page.getByRole("dialog");
      const before = await dlg.getByLabel(f.field).inputValue();
      await dlg.getByLabel(f.field).fill("تعديل غير محفوظ للاختبار");
      await page.waitForTimeout(700);
      await page.reload({ waitUntil: "networkidle" });
      await page.getByRole("button", { name: f.edit }).first().click();
      dlg = page.getByRole("dialog");
      // offered, not applied: the form shows the saved record until the user clicks restore
      await expect(dlg.getByTestId("form-draft-restore")).toContainText(f.banner);
      await expect(dlg.getByLabel(f.field)).toHaveValue(before);
      await page.waitForTimeout(700);   // waiting must not delete the offered edit
      await expect(dlg.getByTestId("form-draft-restore")).toBeVisible();
      await dlg.getByRole("button", { name: "استعادة المسودة" }).click();
      await expect(dlg.getByLabel(f.field)).toHaveValue("تعديل غير محفوظ للاختبار");
      await dlg.getByRole("button", { name: /^حفظ/ }).first().click();
      await expect(page.getByRole("dialog")).toHaveCount(0);
      expect(await page.evaluate((k) => Object.keys(sessionStorage).filter((x) => x.startsWith(k)), f.key)).toEqual([]);
      await page.getByRole("button", { name: f.edit }).first().click();
      await expect(page.getByRole("dialog").getByTestId("form-draft-restore")).toHaveCount(0);
    });

    test(`${f.name}: an untouched edit stores nothing; the stored edit holds form values and the record version only`, async ({ page, loginAs, go }) => {
      await loginAs("owner");
      await go(f.path);
      await page.getByRole("button", { name: f.edit }).first().click();
      await page.waitForTimeout(700);
      expect(await page.evaluate((k) => Object.keys(sessionStorage).filter((x) => x.startsWith(k)), f.key)).toEqual([]);
      await page.getByRole("dialog").getByLabel(f.field).fill("x");
      await page.waitForTimeout(700);
      const env = await page.evaluate((k) => { const key = Object.keys(sessionStorage).find((x) => x.startsWith(k)); return key ? JSON.parse(sessionStorage.getItem(key)!) : null; }, f.key);
      expect(env).not.toBeNull();
      expect(Object.keys(env).sort()).toEqual(["value", "version"]);
    });

    test(`${f.name}: when the SAME record's version moved on, the stored edit is dropped and never offered`, async ({ page, loginAs, go }) => {
      await loginAs("owner");
      await go(f.path);
      const nameField = "الاسم العربي (مطلوب)";
      // the second record, identified by its own name, so the same record is reopened after the reload
      await page.getByRole("button", { name: f.edit }).nth(1).click();
      let dlg = page.getByRole("dialog");
      const recordName = await dlg.getByLabel(nameField).inputValue();
      await dlg.getByLabel(f.field).fill("تعديل قديم");
      await page.waitForTimeout(700);
      // control: with the version unchanged the same record DOES get the offer
      await page.reload({ waitUntil: "networkidle" });
      await page.getByRole("button", { name: f.edit }).nth(1).click();
      dlg = page.getByRole("dialog");
      await expect(dlg.getByLabel(nameField)).toHaveValue(recordName);
      await expect(dlg.getByTestId("form-draft-restore")).toBeVisible();
      await page.keyboard.press("Escape");
      // the record's version moves on (tampered envelope), same record reopened: no offer, key removed
      await page.evaluate((k) => { const key = Object.keys(sessionStorage).find((x) => x.startsWith(k))!; const e = JSON.parse(sessionStorage.getItem(key)!); e.version = 99999; sessionStorage.setItem(key, JSON.stringify(e)); }, f.key);
      await page.reload({ waitUntil: "networkidle" });
      await page.getByRole("button", { name: f.edit }).nth(1).click();
      dlg = page.getByRole("dialog");
      await expect(dlg.getByLabel(nameField)).toHaveValue(recordName);   // same record as before
      if (f.name === "service") await page.screenshot({ path: `${SHOT_DIR}/editdraft-same-record-stale-dropped.png` });
      await expect(dlg.getByTestId("form-draft-restore")).toHaveCount(0);
      expect(await page.evaluate((k) => Object.keys(sessionStorage).filter((x) => x.startsWith(k)), f.key)).toEqual([]);
    });
  });
}

test("unit: an edit survives a reload and is restored on a click; the licence number is never stored", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/admin/rooms");
  await page.getByRole("button", { name: /^تعديل الوحدة/ }).first().click();
  let dlg = page.getByRole("dialog");
  const before = await dlg.getByLabel("ملاحظات", { exact: true }).inputValue();
  await dlg.getByLabel("ملاحظات", { exact: true }).fill("ملاحظة غير محفوظة");
  const lic = dlg.getByLabel("رقم الترخيص");
  if (await lic.count()) await lic.fill("LIC-SYNTH-0001");
  await page.waitForTimeout(700);
  const stored = await page.evaluate(() => Object.entries(sessionStorage).filter(([k]) => k.includes("room-edit")).map(([, v]) => v));
  expect(stored.length).toBe(1);
  expect(stored[0]).not.toContain("LIC-SYNTH-0001");
  expect(stored[0]).not.toContain("license");
  await page.reload({ waitUntil: "networkidle" });
  await page.getByRole("button", { name: /^تعديل الوحدة/ }).first().click();
  dlg = page.getByRole("dialog");
  await expect(dlg.getByTestId("form-draft-restore")).toContainText("تعديل لم يُحفظ على هذه الوحدة");
  await expect(dlg.getByLabel("ملاحظات", { exact: true })).toHaveValue(before);
  await dlg.getByRole("button", { name: "استعادة المسودة" }).click();
  await expect(dlg.getByLabel("ملاحظات", { exact: true })).toHaveValue("ملاحظة غير محفوظة");
});

test("sign-out removes every draft of the tab; the next person is offered nothing, and another user's key is never offered", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/admin/services");
  await page.getByRole("button", { name: /^تعديل الخدمة$/ }).first().click();
  await page.getByRole("dialog").getByLabel("الوصف").fill("نص لا يجوز أن يبقى بعد الخروج");
  await page.waitForTimeout(700);
  expect(await page.evaluate(() => Object.keys(sessionStorage).filter((k) => k.includes("service-edit")).length)).toBe(1);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "تسجيل الخروج" }).first().click();
  await page.waitForURL(/#\/login(?:[?]|$)/);
  expect(await page.evaluate(() => Object.keys(sessionStorage).filter((k) => /^zaaer:[a-z-]+-(draft|edit):/.test(k)))).toEqual([]);
  await loginAs("manager");
  await go("/admin/services");
  // a key written under some OTHER user id for the same record is not offered to this user
  await page.getByRole("button", { name: /^تعديل الخدمة$/ }).first().click();
  const existing = await page.getByRole("dialog").getByLabel("الوصف").inputValue();
  await page.keyboard.press("Escape");
  await page.evaluate(() => sessionStorage.setItem("zaaer:service-edit:other-user-id:other-record", JSON.stringify({ version: 1, value: { description: "x" } })));
  await page.reload({ waitUntil: "networkidle" });
  await page.getByRole("button", { name: /^تعديل الخدمة$/ }).first().click();
  await expect(page.getByRole("dialog").getByTestId("form-draft-restore")).toHaveCount(0);
  await expect(page.getByRole("dialog").getByLabel("الوصف")).toHaveValue(existing);
});

for (const f of [{ name: "service", path: "/admin/services", open: "خدمة جديدة", field: "الاسم العربي (مطلوب)", prefix: "zaaer:service-draft:" },
                 { name: "room category", path: "/admin/room-categories", open: "نوع جديد", field: "الاسم العربي (مطلوب)", prefix: "zaaer:room-category-draft:" },
                 { name: "branch", path: "/admin/branches", open: "فرع جديد", field: "الاسم العربي (مطلوب)", prefix: "zaaer:branch-draft:" }]) {
  test(`new-record draft (${f.name}) is scoped to the user: a different login in the same tab, without any sign-out, is never offered it`, async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go(f.path);
    await page.getByRole("button", { name: new RegExp(`^${f.open}`) }).first().click();
    await page.getByRole("dialog").getByLabel(f.field).fill("نص المالك غير المحفوظ");
    await page.waitForTimeout(700);
    const keys = await page.evaluate((p) => Object.keys(sessionStorage).filter((k) => k.startsWith(p)), f.prefix);
    expect(keys.length).toBe(1);
    expect(keys[0].split(":").length, "user, organisation (and branch) are in the key").toBeGreaterThanOrEqual(f.name === "branch" ? 4 : 5);
    // session expiry / revocation / another person signing in: the first user never signed out through the menu
    await page.evaluate(() => sessionStorage.removeItem("zaaer_demo_session"));   // the demo session ends; the drafts stay in the tab
    expect(await page.evaluate((p) => Object.keys(sessionStorage).some((k) => k.startsWith(p)), f.prefix), "the draft is still in the tab").toBe(true);
    await page.reload({ waitUntil: "networkidle" });   // reset in-memory auth after the demo session is removed
    await loginAs("manager");
    await go(f.path);
    if (f.name === "branch") {
      // branch creation is owner-only: preserve that rule, do not force the manager into its form
      await expect(page.getByRole("button", { name: new RegExp(`^${f.open}`) })).toHaveCount(0);
      expect(await page.evaluate((p) => Object.keys(sessionStorage).filter((k) => k.startsWith(p)), f.prefix)).toEqual(keys);
      return;
    }
    await page.getByRole("button", { name: new RegExp(`^${f.open}`) }).first().click();
    await expect(page.getByRole("dialog").getByTestId("form-draft-restore")).toHaveCount(0);
    await expect(page.getByRole("dialog").getByLabel(f.field)).toHaveValue("");
  });
}
test("an unscoped draft left by an older build is discarded, never moved into a user's key", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await page.evaluate(() => { sessionStorage.setItem("zaaer:service-draft:legacy-branch-id", JSON.stringify({ name_ar: "قديم" })); });
  await go("/admin/services");
  await page.waitForTimeout(500);
  const all = await page.evaluate(() => Object.entries(sessionStorage).filter(([k]) => k.startsWith("zaaer:service-draft:")));
  expect(all).toEqual([]);
});
