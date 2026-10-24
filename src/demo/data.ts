/**
 * Demo dataset (synthetic, in-browser). Built relative to "today" so arrivals / departures /
 * overstays are always meaningful. Nothing here comes from a real property.
 */
export type Row = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
export type Store = Record<string, Row[]>;

export const ORG = "00000000-0000-0000-0000-000000000001";
export const BRANCH_A = "00000000-0000-0000-0000-000000000010";
export const BRANCH_B = "00000000-0000-0000-0000-000000000012";
/** Branch A's default cash box and bank account (0028). */
export const CASH_A = "00000000-0000-0000-0000-000000000700";
export const BANK_A = "00000000-0000-0000-0000-000000000701";

let counter = 1000;
export const uid = () => {
  counter += 1;
  const h = counter.toString(16).padStart(12, "0");
  return `d${Math.random().toString(16).slice(2, 8).padEnd(7, "0")}-${Math.random().toString(16).slice(2, 6).padEnd(4, "0")}-4000-8000-${h}`;
};
const fixed = (n: number) => `00000000-0000-0000-0000-${n.toString().padStart(12, "0")}`;

export const todayISO = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
export const addDays = (d: string, n: number) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
export const nowISO = () => new Date().toISOString();
const ts = (dayOffset: number, hour = 10) => { const d = new Date(); d.setDate(d.getDate() + dayOffset); d.setHours(hour, 0, 0, 0); return d.toISOString(); };

export const STAFF = {
  owner: { id: fixed(1), auth: "a0000000-0000-0000-0000-000000000001", email: "owner@demo.sa", name: "عبدالله المالك", role: "owner" },
  manager: { id: fixed(8), auth: "a0000000-0000-0000-0000-000000000008", email: "manager@demo.sa", name: "سلطان مدير الفرع", role: "manager" },
  supervisor: { id: fixed(2), auth: "a0000000-0000-0000-0000-000000000002", email: "reception@demo.sa", name: "فهد الاستقبال", role: "supervisor" },
  finance: { id: fixed(4), auth: "a0000000-0000-0000-0000-000000000004", email: "finance@demo.sa", name: "نورة المالية", role: "finance" },
  housekeeping: { id: fixed(3), auth: "a0000000-0000-0000-0000-000000000003", email: "housekeeping@demo.sa", name: "محمد خدمة الغرف", role: "housekeeping" },
};

export function seed(): Store {
  const T = todayISO();
  const s: Store = {};
  const put = (table: string, rows: Row[]) => { s[table] = rows; return rows; };

  put("organizations", [{ id: ORG, name_ar: "منازل الراحة", name_en: "Comfort Homes", license_number: "HSP-DEMO-001", license_status: "active", created_at: ts(-400) }]);
  put("branches", [
    { id: BRANCH_A, organization_id: ORG, name_ar: "فرع الرياض — طريق الملك فهد", name_en: "Riyadh - King Fahd Rd", city: "الرياض", address: "طريق الملك فهد، حي العليا", map_url: null, phone: "+966500000000", email: "riyadh@demo.sa", check_in_time: "16:00:00", check_out_time: "12:00:00", logo_url: null, is_active: true, timezone: "Asia/Riyadh", tax_rate_bp: 0, prices_include_tax: false, default_deposit_halalas: 5000, supervisor_max_discount_bp: 1000, tax_number: null, commercial_register: "1010000000", archived_at: null, archived_by: null, archive_reason: null, version: 3, created_at: ts(-400), updated_at: ts(-30) },
    { id: BRANCH_B, organization_id: ORG, name_ar: "فرع جدة — الكورنيش", name_en: "Jeddah - Corniche", city: "جدة", address: "طريق الكورنيش", map_url: null, phone: "+966500000001", email: "jeddah@demo.sa", check_in_time: "15:00:00", check_out_time: "12:00:00", logo_url: null, is_active: true, timezone: "Asia/Riyadh", tax_rate_bp: 0, prices_include_tax: false, default_deposit_halalas: 5000, supervisor_max_discount_bp: 0, tax_number: null, commercial_register: null, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-200), updated_at: ts(-200) },
  ]);
  // WhatsApp per branch (0021, 0023): Riyadh answers from the reception computer (a demo number and key — nothing is
  // sent; the WhatsApp simulator plays the program), Jeddah is not set up yet
  put("branch_whatsapp_channels", [
    { branch_id: BRANCH_A, organization_id: ORG, mode: "web_bridge", enabled: true, display_phone: "966500000100", phone_number_id: null, waba_id: null, has_token: false, token_last4: null, has_app_secret: false, verify_token: "demo-verify-token-0000000000000000", otp_template: null, template_lang: "ar", status: "configured", last_error: null, last_checked_at: null, verified_name: null,
      auto_reply: true, human_pause_minutes: 60, has_bridge_key: true, bridge_key: "zb_" + "d3m0".repeat(16).replace(/m/g, "e"), bridge_key_last4: "d3e0", bridge_key_created_at: ts(-2), bridge_status: null, bridge_phone: null, bridge_name: null, bridge_version: null, bridge_last_seen: null, updated_at: ts(-1), created_at: ts(-30) },
  ]);
  put("whatsapp_outbox", []);
  // cash boxes and bank accounts per branch, a default for each kind (0028, decision 25)
  const acct = (id: string, branch: string, kind: string, name: string, bank: string | null, last4: string | null) => ({ id, organization_id: ORG, branch_id: branch, kind, name, bank_name: bank, account_last4: last4, is_default: true, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: null, created_at: ts(-400), updated_at: ts(-400) });
  put("cash_accounts", [
    acct(CASH_A, BRANCH_A, "cash_box", "صندوق الاستقبال", null, null),
    acct(BANK_A, BRANCH_A, "bank_account", "حساب الشبكة والتحويل", "البنك (للتجربة)", "4321"),
    acct(fixed(702), BRANCH_B, "cash_box", "الصندوق الرئيسي", null, null),
    acct(fixed(703), BRANCH_B, "bank_account", "الحساب البنكي الرئيسي", null, null),
  ]);
  put("pos_settlements", []);
  put("platform_payouts", []);
  put("staff_profiles", Object.values(STAFF).map((x) => ({ id: x.id, auth_user_id: x.auth, organization_id: ORG, full_name: x.name, email: x.email, phone: null, role: x.role, is_active: true, created_at: ts(-300) })));
  put("branch_memberships", [
    { id: uid(), staff_id: STAFF.manager.id, branch_id: BRANCH_A }, { id: uid(), staff_id: STAFF.supervisor.id, branch_id: BRANCH_A },
    { id: uid(), staff_id: STAFF.finance.id, branch_id: BRANCH_A }, { id: uid(), staff_id: STAFF.housekeeping.id, branch_id: BRANCH_A },
    { id: uid(), staff_id: STAFF.manager.id, branch_id: BRANCH_B },
  ]);
  put("booking_sources", [
    { id: fixed(21), organization_id: ORG, name: "مباشر (استقبال)", code: "reception", kind: "direct", external_reference_required: false, booking_url: null, is_active: true, archived_at: null, created_at: ts(-400) },
    { id: fixed(20), organization_id: ORG, name: "Booking.com", code: "booking_com", kind: "external", external_reference_required: true, booking_url: "https://www.booking.com/", is_active: true, archived_at: null, created_at: ts(-400) },
    { id: fixed(22), organization_id: ORG, name: "Airbnb", code: "airbnb", kind: "external", external_reference_required: true, booking_url: "https://www.airbnb.com/", is_active: true, archived_at: null, created_at: ts(-400) },
  ]);

  // structure
  const blockMain = fixed(400), blockU = fixed(401);
  put("blocks", [
    { id: blockMain, organization_id: ORG, branch_id: BRANCH_A, name: "المبنى الرئيسي (B)", description: "15 وحدة على طابقين", sort_order: 1, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: STAFF.owner.id, created_at: ts(-400), updated_at: ts(-400) },
    { id: blockU, organization_id: ORG, branch_id: BRANCH_A, name: "الملحق (U)", description: "9 وحدات", sort_order: 2, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: STAFF.owner.id, created_at: ts(-400), updated_at: ts(-400) },
    { id: fixed(402), organization_id: ORG, branch_id: BRANCH_B, name: "المبنى الوحيد", description: null, sort_order: 1, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: STAFF.owner.id, created_at: ts(-200), updated_at: ts(-200) },
  ]);
  const fl = { g: fixed(410), one: fixed(411), uG: fixed(412), bG: fixed(413) };
  put("floors", [
    { id: fl.g, organization_id: ORG, branch_id: BRANCH_A, block_id: blockMain, name: "الأرضي", sort_order: 0, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-400), updated_at: ts(-400) },
    { id: fl.one, organization_id: ORG, branch_id: BRANCH_A, block_id: blockMain, name: "1", sort_order: 1, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-400), updated_at: ts(-400) },
    { id: fl.uG, organization_id: ORG, branch_id: BRANCH_A, block_id: blockU, name: "U", sort_order: 0, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-400), updated_at: ts(-400) },
    { id: fl.bG, organization_id: ORG, branch_id: BRANCH_B, block_id: fixed(402), name: "G", sort_order: 0, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-200), updated_at: ts(-200) },
  ]);
  const cat = { studio: fixed(30), one: fixed(31), two: fixed(32), jed: fixed(39) };
  put("room_categories", [
    { id: cat.studio, branch_id: BRANCH_A, organization_id: ORG, name_ar: "استوديو مريح", name_en: "Cozy Studio", description: "استوديو 35م² مع مطبخ مجهز", base_capacity: 2, max_capacity: 3, base_price_halalas: 25000, weekly_price_halalas: 157500, monthly_price_halalas: 600000, min_nightly_halalas: 20000, price_mode: "by_channel", amenities: ["واي فاي", "تكييف", "مطبخ"], is_public: true, is_active: true, sort_order: 1, archived_at: null, archived_by: null, archive_reason: null, version: 2, images: [], created_at: ts(-400), updated_at: ts(-60) },
    { id: cat.one, branch_id: BRANCH_A, organization_id: ORG, name_ar: "شقة بغرفة نوم", name_en: "One Bedroom", description: "غرفة نوم وصالة ومطبخ وحمامين", base_capacity: 3, max_capacity: 5, base_price_halalas: 40000, weekly_price_halalas: 252000, monthly_price_halalas: 960000, min_nightly_halalas: 32000, price_mode: "unified", amenities: ["واي فاي", "تكييف", "مطبخ", "غسالة"], is_public: true, is_active: true, sort_order: 2, archived_at: null, archived_by: null, archive_reason: null, version: 1, images: [], created_at: ts(-400), updated_at: ts(-400) },
    { id: cat.two, branch_id: BRANCH_A, organization_id: ORG, name_ar: "شقة بغرفتين", name_en: "Two Bedroom", description: "غرفتا نوم وصالة واسعة", base_capacity: 4, max_capacity: 6, base_price_halalas: 60000, weekly_price_halalas: 378000, monthly_price_halalas: 1440000, min_nightly_halalas: 48000, price_mode: "unified", amenities: ["واي فاي", "تكييف", "مطبخ", "غسالة", "جلسة خارجية"], is_public: true, is_active: true, sort_order: 3, archived_at: null, archived_by: null, archive_reason: null, version: 1, images: [], created_at: ts(-400), updated_at: ts(-400) },
    { id: cat.jed, branch_id: BRANCH_B, organization_id: ORG, name_ar: "غرفة فندقية", name_en: "Hotel Room", description: null, base_capacity: 2, max_capacity: 3, base_price_halalas: 30000, weekly_price_halalas: null, monthly_price_halalas: null, min_nightly_halalas: null, price_mode: "unified", amenities: ["واي فاي"], is_public: true, is_active: true, sort_order: 1, archived_at: null, archived_by: null, archive_reason: null, version: 1, images: [], created_at: ts(-200), updated_at: ts(-200) },
  ]);
  const rooms: Row[] = [];
  const mk = (n: string, c: string, block: string, floor: string, status: string, clean: string, extra: Row = {}) => { const r = { id: uid(), branch_id: BRANCH_A, organization_id: ORG, category_id: c, room_number: n, floor: floor === fl.one ? 2 : 1, status, cleanliness: clean, is_active: true, notes: null, block_id: block, floor_id: floor, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-400), updated_at: ts(-1), ...extra }; rooms.push(r); return r.id; };
  const R: Record<string, string> = {};
  R["101"] = mk("101", cat.studio, blockMain, fl.g, "occupied", "clean");
  R["102"] = mk("102", cat.studio, blockMain, fl.g, "ready", "clean");
  R["103"] = mk("103", cat.studio, blockMain, fl.g, "cleaning", "dirty");
  R["104"] = mk("104", cat.studio, blockMain, fl.g, "occupied", "clean");
  R["105"] = mk("105", cat.studio, blockMain, fl.g, "reserved", "clean");
  R["106"] = mk("106", cat.one, blockMain, fl.g, "maintenance", "clean");
  R["201"] = mk("201", cat.one, blockMain, fl.one, "occupied", "clean");
  R["202"] = mk("202", cat.one, blockMain, fl.one, "cleaning", "in_progress");
  R["203"] = mk("203", cat.one, blockMain, fl.one, "ready", "clean");
  R["204"] = mk("204", cat.one, blockMain, fl.one, "occupied", "clean");
  R["205"] = mk("205", cat.two, blockMain, fl.one, "ready", "clean");
  R["206"] = mk("206", cat.two, blockMain, fl.one, "cleaning", "dirty");
  R["U1"] = mk("U-1", cat.studio, blockU, fl.uG, "ready", "clean");
  R["U2"] = mk("U-2", cat.studio, blockU, fl.uG, "occupied", "clean");
  R["U3"] = mk("U-3", cat.one, blockU, fl.uG, "available", "clean");
  R["U4"] = mk("U-4", cat.two, blockU, fl.uG, "out_of_service", "clean", { is_active: false, notes: "تجديد كامل" });
  rooms.push({ id: fixed(199), branch_id: BRANCH_B, organization_id: ORG, category_id: cat.jed, room_number: "J-1", floor: 1, status: "ready", cleanliness: "clean", is_active: true, notes: null, block_id: fixed(402), floor_id: fl.bG, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-200), updated_at: ts(-1) });
  rooms.push({ id: fixed(198), branch_id: BRANCH_B, organization_id: ORG, category_id: cat.jed, room_number: "J-2", floor: 1, status: "available", cleanliness: "clean", is_active: true, notes: null, block_id: fixed(402), floor_id: fl.bG, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-200), updated_at: ts(-1) });
  put("rooms", rooms);
  // the price calendar (decision 33): Thursday and Friday nights dearer for two types over the next 60 days, and the
  // platforms' own price of the studio (priced by channel) over the next 30
  const rates: Row[] = [];
  const rate = (category_id: string, night: string, price: number | null, platform: number | null) =>
    rates.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, category_id, night, price_halalas: price, platform_price_halalas: platform, updated_by: STAFF.manager.id, updated_at: ts(-3), created_at: ts(-3) });
  for (let i = 0; i < 60; i++) {
    const night = addDays(T, i); const dow = new Date(night + "T00:00:00Z").getUTCDay(); const weekend = dow === 4 || dow === 5;
    if (weekend) { rate(cat.studio, night, 30000, i < 30 ? 32500 : null); rate(cat.one, night, 48000, null); }
    else if (i < 30) rate(cat.studio, night, null, 27500);
  }
  put("rate_calendar", rates);
  put("reservation_nights", []);
  // Key boxes of branch A. The demo keeps a synthetic code in the browser (code_plain) so «الرموز» can show and change it;
  // the real system keeps it encrypted on the server only. Units left by a guest wait for a new code (red) since then.
  put("keyboxes", rooms.filter((r) => r.branch_id === BRANCH_A).map((r, i) => {
    const change = r.cleanliness !== "clean" || r.room_number === "103";
    return { id: uid(), room_id: r.id, branch_id: BRANCH_A, code_encrypted: null, code_plain: String(2000 + ((i * 7919) % 7000)), code_version: 3,
      code_status: change ? "needs_change" : "active", needs_change_since: change ? new Date(Date.now() - (35 + i * 15) * 60_000).toISOString() : null,
      last_changed_at: ts(-2), last_changed_by: STAFF.supervisor.id, field_tested: r.cleanliness === "clean", last_reservation_id: null, requires_rotation: true,
      last_delivered_at: r.status === "occupied" ? ts(-1, 17) : null, created_at: ts(-400) };
  }));
  put("facilities", [
    { id: fixed(430), organization_id: ORG, branch_id: BRANCH_A, block_id: blockMain, floor_id: fl.g, name: "الممر الرئيسي", description: "ممر الطابق الأرضي", images: [], is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: STAFF.owner.id, created_at: ts(-400), updated_at: ts(-400) },
    { id: fixed(431), organization_id: ORG, branch_id: BRANCH_A, block_id: blockMain, floor_id: null, name: "البوابة الرئيسية", description: null, images: [], is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: STAFF.owner.id, created_at: ts(-400), updated_at: ts(-400) },
    { id: fixed(432), organization_id: ORG, branch_id: BRANCH_A, block_id: blockU, floor_id: fl.uG, name: "الجلسة الخارجية", description: "جلسة مظللة بجانب الملحق", images: [], is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: STAFF.owner.id, created_at: ts(-400), updated_at: ts(-400) },
    { id: fixed(433), organization_id: ORG, branch_id: BRANCH_A, block_id: blockMain, floor_id: fl.one, name: "دورات المياه المشتركة — الطابق 1", description: null, images: [], is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: STAFF.owner.id, created_at: ts(-400), updated_at: ts(-400) },
    { id: fixed(434), organization_id: ORG, branch_id: BRANCH_A, block_id: blockMain, floor_id: fl.g, name: "مكتب الأعمال", description: "أُغلق مؤقتًا", images: [], is_active: false, archived_at: ts(-20), archived_by: STAFF.owner.id, archive_reason: "لم يعد مستخدمًا", version: 2, created_by: STAFF.owner.id, created_at: ts(-400), updated_at: ts(-20) },
  ]);
  const tt = { clean: fixed(420), wc: fixed(421), corridors: fixed(422), deep: fixed(423), cleanB: fixed(424) };
  put("task_types", [
    { id: tt.clean, organization_id: ORG, branch_id: BRANCH_A, code: "room_cleaning", name: "تنظيف الوحدة وتعقيمها", description: "يُنشأ تلقائيًا بعد المغادرة", is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-400), updated_at: ts(-400) },
    { id: tt.wc, organization_id: ORG, branch_id: BRANCH_A, code: null, name: "تنظيف دورات المياه وتعقيمها", description: null, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-400), updated_at: ts(-400) },
    { id: tt.corridors, organization_id: ORG, branch_id: BRANCH_A, code: null, name: "تنظيف الجلسة والممرات", description: null, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-400), updated_at: ts(-400) },
    { id: tt.deep, organization_id: ORG, branch_id: BRANCH_A, code: null, name: "تنظيف عميق", description: "بعد الإقامات الطويلة", is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-100), updated_at: ts(-100) },
    { id: tt.cleanB, organization_id: ORG, branch_id: BRANCH_B, code: "room_cleaning", name: "تنظيف الوحدة وتعقيمها", description: null, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-200), updated_at: ts(-200) },
  ]);
  const svc = { breakfast: fixed(440), late: fixed(441), extraClean: fixed(442) };
  put("service_definitions", [
    { id: svc.breakfast, organization_id: ORG, branch_id: BRANCH_A, name_ar: "إفطار", name_en: "Breakfast", description: "لكل شخص لكل يوم", billing_unit: "person", price_halalas: 3500, is_free: false, taxable: true, task_type_id: null, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-300), updated_at: ts(-300) },
    { id: svc.late, organization_id: ORG, branch_id: BRANCH_A, name_ar: "مغادرة متأخرة حتى 4 عصرًا", name_en: "Late check-out", description: null, billing_unit: "once", price_halalas: 10000, is_free: false, taxable: true, task_type_id: null, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-300), updated_at: ts(-300) },
    { id: svc.extraClean, organization_id: ORG, branch_id: BRANCH_A, name_ar: "تنظيف إضافي أثناء الإقامة", name_en: "Extra cleaning", description: null, billing_unit: "once", price_halalas: 8000, is_free: false, taxable: true, task_type_id: tt.clean, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-300), updated_at: ts(-300) },
  ]);

  // reservations
  const res: Row[] = []; const guests: Row[] = []; const allocs: Row[] = []; const charges: Row[] = []; const vouchers: Row[] = []; const audits: Row[] = [];
  let vnum = 100; let rnum = 1;
  const nextNum = (prefix: string) => `${prefix}-2026-${String(++vnum).padStart(6, "0")}`;
  const money = (resId: string, kind: string, amount: number, method: string, dayOff: number, reference: string | null = null, status = "approved") => {
    const account_id = method === "cash" ? CASH_A : method === "pos" || method === "bank_transfer" ? BANK_A : null;
    vouchers.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: resId, number: nextNum(kind === "receipt" ? "RCP" : kind === "deposit" ? "DEP" : kind === "refund" ? "RFD" : "DRF"), kind, amount_halalas: amount, method, account_id, payout_id: null, status, reference, note: null, reason: kind.includes("refund") ? "تسوية" : null, original_voucher_id: null, payment_transaction_id: null, idempotency_key: uid(), content_hash: "x", occurred_at: ts(dayOff, 14), created_by: STAFF.supervisor.id, created_at: ts(dayOff, 14), cancelled_by: null, cancelled_at: null, cancel_reason: null });
  };
  interface MkRes { guest: string; phone: string; nat?: string; cat: string; room?: string; ci: number; co: number; status: string; source?: string; ext?: string | null; adults?: number; comp?: number; identity?: string; access?: string; gov?: boolean; receipts?: number[]; otaPaid?: boolean; deposit?: number; depositRefund?: number; discount?: number; addon?: { d: string; a: number } | null; actualIn?: boolean; actualOut?: boolean; createdDays?: number; keyboxDelivered?: boolean }
  const mkRes = (o: MkRes) => {
    const id = uid(); const ci = addDays(T, o.ci); const co = addDays(T, o.co); const nights = o.co - o.ci;
    const rate = s.room_categories.find((c) => c.id === o.cat)!.base_price_halalas as number;
    const rent = rate * nights; const disc = o.discount ?? 0; const addon = o.addon?.a ?? 0;
    // tax zero (decision 68); the receipt amounts below were written with 15% tax, so they are scaled to the stay
    const taxable = rent - disc + addon; const tax = 0;
    const total = taxable + tax;
    const receipts = o.otaPaid ? [total] : (o.receipts ?? []).map((a) => Math.round(a / 1.15));   // a platform-paid stay: the platform owes the whole of it
    const received = receipts.reduce((a, b) => a + b, 0);
    // the deposit is 50 SAR per unit (decisions 33, 69); a partial return stays partial
    const dep = o.deposit ? 5000 : 0; const depRef = o.depositRefund ? (o.depositRefund >= (o.deposit ?? 0) ? 5000 : 2500) : 0;
    const paid = received; const due = Math.max(total - paid, 0);
    const payment_status = paid === 0 ? "pending" : paid < total ? "partially_paid" : "paid";
    const roomId = o.room ? R[o.room] : null;
    const r = { id, organization_id: ORG, branch_id: BRANCH_A, internal_ref: `R-26A${String(rnum++).padStart(4, "0")}`, external_ref: o.ext ?? null, source_id: o.source ?? fixed(21), status: o.status, booking_type: "individual", company_name: null, visit_purpose: "سياحة", check_in: ci, check_out: co, adults: o.adults ?? 2, companions: o.comp ?? 0, room_category_id: o.cat, room_id: roomId,
      rent_amount_halalas: rent, discount_halalas: disc, addons_halalas: addon, taxes_halalas: tax, total_halalas: total, paid_halalas: paid, payment_status, identity_status: o.identity ?? "verified", government_registration: o.gov ?? (o.status === "checked_in" || o.status === "checked_out"), access_status: o.access ?? (o.status === "checked_in" ? "delivered" : o.status === "checked_out" ? "delivered" : "locked"), keybox_delivered: o.keyboxDelivered ?? (o.status === "checked_in"),
      checkin_approved_by: null, checkin_approved_at: null, actual_check_in: o.actualIn || o.status === "checked_in" || o.status === "checked_out" ? ts(o.ci, 17) : null, actual_check_out: o.actualOut || o.status === "checked_out" ? ts(o.co, 11) : null, notes: null, created_at: ts(o.createdDays ?? o.ci - 5), created_by: STAFF.supervisor.id, security_hold: false, security_hold_reason: null, gov_registration_ref: null, gov_registration_by: null, gov_registration_at: null, updated_at: ts(-1),
      version: 1, rate_type: "daily", nightly_rate_halalas: rate, tax_rate_bp: 0, prices_include_tax: false, cancelled_at: null, cancel_reason: null, cancel_source: null, no_show_at: null, deposit_balance_halalas: dep - depRef, refunded_halalas: 0, balance_due_halalas: due };
    res.push(r);
    guests.push({ id: uid(), reservation_id: id, guest_profile_id: null, is_primary: true, full_name: o.guest, identity_type: "national_id", identity_number_encrypted: null, identity_number_last4: String(1000 + Math.floor(Math.random() * 8999)), identity_issue_number: null, nationality: o.nat ?? "سعودي", birth_date: "1990-05-05", phone: o.phone, phone_verified: false, relationship: null, verification_status: o.identity ?? "verified", data_submitted: (o.identity ?? "verified") !== "not_started", created_at: r.created_at });
    if (roomId) allocs.push({ id: uid(), reservation_id: id, room_id: roomId, branch_id: BRANCH_A, from_date: ci, to_date: co, status: ["cancelled", "no_show", "rejected"].includes(o.status) ? "cancelled" : o.status === "checked_out" ? "closed" : "active", reason: "create", created_by: STAFF.supervisor.id, created_at: r.created_at, closed_at: null });
    charges.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: id, kind: "rent", description: `إيجار ${nights} ليلة × ${(rate / 100).toFixed(2)} ر.س`, quantity: nights, unit_price_halalas: rate, total_halalas: rent, taxable: true, service_definition_id: null, invoice_id: null, reason: null, created_by: STAFF.supervisor.id, created_at: r.created_at });
    if (disc) charges.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: id, kind: "discount", description: "خصم ضيف دائم", quantity: 1, unit_price_halalas: disc, total_halalas: -disc, taxable: true, service_definition_id: null, invoice_id: null, reason: "ضيف دائم", created_by: STAFF.manager.id, created_at: r.created_at });
    if (o.addon) charges.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: id, kind: "addon", description: o.addon.d, quantity: 1, unit_price_halalas: o.addon.a, total_halalas: o.addon.a, taxable: true, service_definition_id: svc.breakfast, invoice_id: null, reason: null, created_by: STAFF.supervisor.id, created_at: r.created_at });
    if (tax) charges.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: id, kind: "tax", description: "ضريبة القيمة المضافة", quantity: 1, unit_price_halalas: tax, total_halalas: tax, taxable: false, service_definition_id: null, invoice_id: null, reason: null, created_by: STAFF.supervisor.id, created_at: r.created_at });
    // a platform collects when the guest books (never later than yesterday here); it pays the property later, monthly
    receipts.forEach((amt, i) => (o.otaPaid ? money(id, "receipt", amt, "ota_deferred", Math.min(o.createdDays ?? o.ci - 5, -1), o.ext ?? null) : money(id, "receipt", amt, i === 0 ? "pos" : "cash", o.ci - 1 + i, i === 0 ? "TRX-" + (7000 + rnum) : null)));
    if (dep) money(id, "deposit", dep, "cash", o.ci);
    if (depRef) money(id, "deposit_refund", depRef, "cash", o.co);
    audits.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, actor_id: STAFF.supervisor.id, action: "reservation.created", entity_type: "reservation", entity_id: id, details: { after: { internal_ref: r.internal_ref, check_in: ci, check_out: co } }, created_at: r.created_at });
    return id;
  };
  // in-house
  const rIn1 = mkRes({ guest: "خالد بن سعد العتيبي", phone: "0501110001", cat: cat.studio, room: "101", ci: -2, co: 1, status: "checked_in", receipts: [50000], deposit: 20000, discount: 0 });
  const rIn2 = mkRes({ guest: "Omar Haddad", phone: "0501110002", nat: "أردني", cat: cat.studio, room: "104", ci: -1, co: 2, status: "checked_in", receipts: [86250], deposit: 20000 });
  const rIn3 = mkRes({ guest: "عبدالرحمن محمد القحطاني", phone: "0501110003", cat: cat.one, room: "201", ci: -3, co: 0, status: "checked_in", receipts: [100000], deposit: 30000, addon: { d: "إفطار × 2 × 3 أيام", a: 21000 } });
  const rIn4 = mkRes({ guest: "سارة علي الشهري", phone: "0501110004", cat: cat.one, room: "204", ci: -6, co: -1, status: "checked_in", receipts: [138000, 92000], deposit: 30000 }); // overstay
  const rIn5 = mkRes({ guest: "فيصل ناصر الدوسري", phone: "0501110005", cat: cat.studio, room: "U2", ci: -1, co: 0, status: "checked_in", receipts: [28750], deposit: 10000 });
  // arrivals today
  const rArr1 = mkRes({ guest: "منيرة سعود الحربي", phone: "0501110006", cat: cat.studio, room: "105", ci: 0, co: 3, status: "confirmed", receipts: [], deposit: 0, identity: "data_submitted", access: "locked", gov: false, otaPaid: true, source: fixed(20), ext: "BK-4471029" });
  const rArr2 = mkRes({ guest: "Ahmed Al Mansoori", phone: "0501110007", nat: "إماراتي", cat: cat.two, ci: 0, co: 2, status: "pending_verification", receipts: [], identity: "not_started", access: "locked", gov: false, otaPaid: true, source: fixed(22), ext: "HMABC123" });
  const rArr3 = mkRes({ guest: "تركي عبدالعزيز المطيري", phone: "0501110008", cat: cat.one, room: "203", ci: 0, co: 5, status: "confirmed", receipts: [230000], identity: "verified", access: "locked", gov: true });
  // overdue arrival
  mkRes({ guest: "بدر راشد العنزي", phone: "0501110009", cat: cat.studio, ci: -1, co: 2, status: "confirmed", receipts: [], identity: "not_started", access: "locked", gov: false });
  // future
  mkRes({ guest: "لطيفة حمد السبيعي", phone: "0501110010", cat: cat.two, room: "205", ci: 2, co: 6, status: "confirmed", receipts: [69000], identity: "not_started", access: "locked", gov: false, createdDays: -4 });
  mkRes({ guest: "Yusuf Demir", phone: "0501110011", nat: "تركي", cat: cat.one, ci: 5, co: 9, status: "confirmed", receipts: [], identity: "not_started", access: "locked", gov: false, otaPaid: true, source: fixed(20), ext: "BK-4489931", createdDays: -2 });
  mkRes({ guest: "ريم فهد الغامدي", phone: "0501110012", cat: cat.studio, room: "U1", ci: 1, co: 2, status: "confirmed", receipts: [28750], identity: "verified", access: "locked", gov: false, createdDays: -1 });
  // checked out with deposit to settle
  const rOut1 = mkRes({ guest: "ماجد سلمان الزهراني", phone: "0501110013", cat: cat.two, room: "206", ci: -4, co: 0, status: "checked_out", receipts: [276000], deposit: 40000, actualOut: true });
  mkRes({ guest: "Hassan Karim", phone: "0501110014", nat: "مصري", cat: cat.studio, room: "103", ci: -3, co: 0, status: "checked_out", receipts: [86250], deposit: 20000, depositRefund: 20000, actualOut: true });
  mkRes({ guest: "نواف خالد الشمري", phone: "0501110015", cat: cat.one, room: "202", ci: -5, co: -1, status: "checked_out", receipts: [184000], deposit: 30000, depositRefund: 20000, actualOut: true });
  // cancelled / no-show
  mkRes({ guest: "هند عبدالله القرني", phone: "0501110016", cat: cat.studio, ci: -2, co: 0, status: "cancelled", receipts: [], identity: "not_started", source: fixed(20), ext: "BK-4432100", createdDays: -8 });
  mkRes({ guest: "Rami Nasser", phone: "0501110017", nat: "لبناني", cat: cat.one, ci: -1, co: 1, status: "no_show", receipts: [], identity: "not_started", createdDays: -6 });
  // history
  for (let i = 1; i <= 6; i++) mkRes({ guest: ["عمر الحربي", "Sara Khan", "ياسر العمري", "Mohammed Ali", "دلال الراشد", "Noura Fahad"][i - 1], phone: "05011100" + (20 + i), cat: [cat.studio, cat.one, cat.two][i % 3], room: ["101", "203", "205", "U1", "102", "204"][i - 1], ci: -10 - i * 3, co: -7 - i * 3, status: "checked_out", receipts: [[86250, 138000, 207000][i % 3]], deposit: 20000, depositRefund: 20000, actualOut: true });
  // a returning guest with a second, later stay (WhatsApp lists both bookings of her number)
  mkRes({ guest: "لطيفة حمد السبيعي", phone: "0501110010", cat: cat.one, ci: 20, co: 23, status: "confirmed", receipts: [], identity: "not_started", access: "locked", gov: false, createdDays: -1 });
  // mark cancelled/no_show rows
  for (const r of res) { if (r.status === "cancelled") { r.cancelled_at = ts(-3); r.cancel_reason = "إلغاء من المنصة"; r.cancel_source = "ota"; } if (r.status === "no_show") { r.no_show_at = ts(0, 9); r.cancel_reason = "لم يحضر ولم يرد"; } }
  put("reservations", res); put("reservation_guests", guests); put("reservation_allocations", allocs); put("reservation_charges", charges); put("financial_vouchers", vouchers);
  // an invoice for the first checked-out stay
  const invRes = res.find((r) => r.id === rOut1)!; const invLines = charges.filter((c) => c.reservation_id === rOut1);
  const invId = uid(); invLines.forEach((c) => (c.invoice_id = invId));
  put("invoices", [{ id: invId, organization_id: ORG, branch_id: BRANCH_A, reservation_id: rOut1, number: "INV-2026-000041", period_from: invRes.check_in, period_to: invRes.check_out, status: "issued", snapshot: { lines: invLines.map((c) => ({ ...c })) }, subtotal_halalas: invLines.filter((c) => c.kind !== "tax").reduce((a, c) => a + c.total_halalas, 0), tax_halalas: invLines.filter((c) => c.kind === "tax").reduce((a, c) => a + c.total_halalas, 0), total_halalas: invLines.reduce((a, c) => a + c.total_halalas, 0), issued_by: STAFF.finance.id, issued_at: ts(0, 11), cancelled_by: null, cancelled_at: null, cancel_reason: null }]);
  put("guest_profiles", guests.map((g) => ({ id: uid(), organization_id: ORG, full_name: g.full_name, phone: g.phone, nationality: g.nationality, email: null, notes: null, created_at: g.created_at, updated_at: g.created_at })));
  put("payment_transactions", []);

  // housekeeping tasks
  const roomBy = (n: string) => rooms.find((r) => r.room_number === n)!;
  const task = (target: { room?: string; facility?: string }, type: string, status: string, priority: string, assignee: string | null, dayOff: number, resId: string | null = null, desc: string | null = null) => ({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, room_id: target.room ? roomBy(target.room).id : null, facility_id: target.facility ?? null, task_type_id: type, task_type_name_snapshot: s.task_types.find((t) => t.id === type)!.name, reservation_id: resId, priority, status, assignee_id: assignee, scheduled_start: ts(dayOff, 9), scheduled_end: null, started_at: status === "in_progress" || status === "completed" ? ts(dayOff, 10) : null, completed_at: status === "completed" ? ts(dayOff, 12) : null, completed_by: status === "completed" ? assignee : null, cancelled_at: null, cancel_reason: null, description: desc, result_note: status === "completed" ? "تم" : null, images: [], version: 1, created_by: STAFF.supervisor.id, created_at: ts(dayOff, 9), updated_at: ts(dayOff, 12) });
  put("housekeeping_tasks", [
    task({ room: "103" }, tt.clean, "pending", "high", null, 0, res.find((r) => r.room_id === R["103"])?.id ?? null, "تنظيف بعد المغادرة"),
    task({ room: "206" }, tt.clean, "pending", "high", STAFF.housekeeping.id, 0, rOut1, "تنظيف بعد المغادرة"),
    task({ room: "202" }, tt.clean, "in_progress", "medium", STAFF.housekeeping.id, 0, null, "تنظيف بعد المغادرة"),
    task({ facility: fixed(433) }, tt.wc, "pending", "medium", null, 0),
    task({ facility: fixed(430) }, tt.corridors, "completed", "low", STAFF.housekeeping.id, 0),
    task({ room: "102" }, tt.clean, "completed", "high", STAFF.housekeeping.id, -1),
    task({ room: "U-1" }, tt.clean, "completed", "medium", STAFF.housekeeping.id, -1),
    task({ facility: fixed(432) }, tt.corridors, "completed", "low", STAFF.housekeeping.id, -2),
  ]);
  put("maintenance_tickets", [{ id: uid(), room_id: R["106"], branch_id: BRANCH_A, title: "تسريب في حمام الغرفة", description: "صيانة السباكة مطلوبة قبل إعادة التسكين", status: "open", created_by: STAFF.supervisor.id, created_at: ts(-1, 15) }]);
  put("code_rotation_events", [{ id: uid(), room_id: R["102"], from_version: 2, to_version: 3, field_tested: true, created_at: ts(-1, 13) }, { id: uid(), room_id: R["U1"], from_version: 1, to_version: 2, field_tested: true, created_at: ts(-1, 14) }]);
  put("access_delivery_events", res.filter((r) => r.status === "checked_in").map((r) => ({ id: uid(), reservation_id: r.id, keybox_id: null, channel: "screen", delivered_by: STAFF.supervisor.id, acknowledged: true, created_at: r.actual_check_in })));
  put("access_release_requests", []);
  put("notifications", [{ id: uid(), branch_id: BRANCH_A, audience: "supervisor", title: "مغادرة — تنظيف وتغيير رمز مطلوب", body: "غرفة 206", link: "/staff/housekeeping", read_at: null, created_at: ts(0, 11) }]);

  // conversations / tickets
  const conv1 = uid(); const conv2 = uid();
  put("conversations", [
    { id: conv1, reservation_id: rArr1, channel: "screen", status: "handed_off", branch_id: BRANCH_A, guest_token: null, client_fingerprint: "fp1", created_at: ts(0, 8), last_message_at: ts(0, 8), handed_off_at: ts(0, 8), handoff_reason: "طلب صريح من النزيل" },
    { id: conv2, reservation_id: null, channel: "screen", status: "active", branch_id: BRANCH_A, guest_token: null, client_fingerprint: "fp2", created_at: ts(-1, 20), last_message_at: ts(-1, 20), handed_off_at: null, handoff_reason: null },
  ]);
  put("conversation_messages", [
    { id: uid(), conversation_id: conv1, sender: "guest", content: "أبغى أعرف متى أقدر أدخل الشقة؟", meta: { mode: "ai" }, created_at: ts(0, 8) },
    { id: uid(), conversation_id: conv1, sender: "assistant", content: "الوصول يبدأ من الساعة 4:00 عصرًا. بعد اكتمال تسجيل بيانات النزلاء ومطابقة الهوية يُسلَّم رمز الدخول عبر الصفحة الآمنة.", meta: { mode: "ai" }, created_at: ts(0, 8) },
    { id: uid(), conversation_id: conv1, sender: "guest", content: "أبغى أكلم موظف", meta: { mode: "ai" }, created_at: ts(0, 8) },
    { id: uid(), conversation_id: conv1, sender: "assistant", content: "تم تحويل محادثتك إلى مشرف الاستقبال وسيرد عليك هنا قريبًا.", meta: { mode: "scripted" }, created_at: ts(0, 8) },
    { id: uid(), conversation_id: conv2, sender: "guest", content: "هل توجد مواقف سيارات؟", meta: { mode: "ai" }, created_at: ts(-1, 20) },
    { id: uid(), conversation_id: conv2, sender: "assistant", content: "نعم، مواقف مجانية أمام المبنى لنزلاء المنشأة.", meta: { mode: "ai" }, created_at: ts(-1, 20) },
  ]);
  put("human_handoff_tickets", [
    { id: uid(), organization_id: ORG, branch_id: BRANCH_A, conversation_id: conv1, reservation_id: rArr1, kind: "guest_request", external_ref: "BK-4471029", source_name: "Booking.com", details: "طلب صريح من النزيل", status: "open", resolved_by: null, resolved_at: null, created_at: ts(0, 8) },
    { id: uid(), organization_id: ORG, branch_id: BRANCH_A, conversation_id: null, reservation_id: null, kind: "unmatched_reservation", external_ref: "BK-9999999", source_name: "Booking.com", details: "رقم حجز غير مطابق", status: "open", resolved_by: null, resolved_at: null, created_at: ts(-1, 21) },
  ]);
  put("registration_sessions", []);
  put("guest_lookup_attempts", []);

  // AI settings & usage
  put("ai_settings", [{ organization_id: ORG, enabled: false, provider: "gemini", model: "gemini-3.8-flash", fallback_models: ["gemini-3.6-flash", "gemini-3.5-flash-lite"], temperature: 0.2, max_output_tokens: 400, timeout_ms: 12000, daily_request_limit: 2000, daily_token_budget: 500000, per_session_message_limit: 40, strict_scope: true, extra_instructions: "", ops_enabled: true, ops_daily_request_limit: 500, briefing_with_insights: true, updated_by: null, updated_at: ts(-10) }]);
  put("ai_usage_daily", Array.from({ length: 14 }, (_, i) => ({ organization_id: ORG, day: addDays(T, -13 + i), requests: 20 + Math.round(Math.sin(i) * 8 + 10), tokens_in: 42000 + i * 900, tokens_out: 9000 + i * 300, fallbacks: i % 4 === 0 ? 2 : 0, guardrail_blocks: i % 5 === 0 ? 1 : 0 })));
  put("ai_tool_executions", [{ id: uid(), conversation_id: conv2, tool_name: "get_public_property_policies", args_redacted: {}, result_status: "ok", latency_ms: 120, created_at: ts(-1, 20) }]);
  put("ai_guardrail_events", [{ id: uid(), conversation_id: conv2, stage: "input", rule: "off_scope:general", detail: "…", created_at: ts(-1, 20) }]);
  put("system_settings", [{ key: "demo_mode", value: "true" }]);
  put("property_policies", [
    { id: uid(), organization_id: ORG, branch_id: BRANCH_A, topic: "checkin", title: "مواعيد الوصول والمغادرة", content_ar: "الوصول من الساعة 4:00 عصرًا، والمغادرة حتى 12:00 ظهرًا.", content_en: null, is_public: true, sort_order: 1, updated_by: null, updated_at: ts(-30), created_at: ts(-300) },
    { id: uid(), organization_id: ORG, branch_id: BRANCH_A, topic: "wifi", title: "الإنترنت", content_ar: "إنترنت لاسلكي مجاني في جميع الوحدات.", content_en: null, is_public: true, sort_order: 2, updated_by: null, updated_at: ts(-30), created_at: ts(-300) },
    { id: uid(), organization_id: ORG, branch_id: BRANCH_A, topic: "parking", title: "المواقف", content_ar: "مواقف مجانية أمام المبنى.", content_en: null, is_public: true, sort_order: 3, updated_by: null, updated_at: ts(-30), created_at: ts(-300) },
    { id: uid(), organization_id: ORG, branch_id: BRANCH_A, topic: "cancellation", title: "سياسة الإلغاء", content_ar: "إلغاء مجاني حتى 48 ساعة قبل الوصول للحجز المباشر.", content_en: null, is_public: true, sort_order: 4, updated_by: null, updated_at: ts(-30), created_at: ts(-300) },
  ]);
  put("inventory_periods", [cat.studio, cat.one, cat.two].flatMap((c) => Array.from({ length: 14 }, (_, i) => ({ id: uid(), branch_id: BRANCH_A, category_id: c, date: addDays(T, i), total_units: c === cat.studio ? 7 : c === cat.one ? 5 : 3, publicly_visible_units: c === cat.studio ? 3 : 2, blocked_units: c === cat.one ? 1 : 0, created_at: ts(-30) }))));
  put("release_rules", [cat.studio, cat.one, cat.two].map((c) => ({ id: uid(), branch_id: BRANCH_A, category_id: c, enabled: c !== cat.two, initial_public_release: 1, release_increment: 1, release_trigger: "access_delivered", created_at: ts(-300) })));
  put("released_slots", [{ id: uid(), branch_id: BRANCH_A, category_id: cat.studio, date: T, released_count: 2, updated_at: ts(0, 9) }]);
  put("integration_events", []);
  put("document_sequences", [{ organization_id: ORG, kind: "voucher", year: 2026, last_value: vnum }, { organization_id: ORG, kind: "invoice", year: 2026, last_value: 41 }]);
  put("ai_ops_conversations", []); put("ai_ops_messages", []); put("ai_action_proposals", []);
  // audit extras
  audits.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, actor_id: STAFF.manager.id, action: "reservation.departure_changed", entity_type: "reservation", entity_id: rIn2, details: { before: { check_out: addDays(T, 1) }, after: { check_out: addDays(T, 2), delta_nights: 1 }, reason: "طلب الضيف" }, created_at: ts(-1, 12) });
  audits.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, actor_id: STAFF.supervisor.id, action: "checkout", entity_type: "reservation", entity_id: rOut1, details: { deposit_balance_halalas: 40000 }, created_at: ts(0, 11) });
  audits.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, actor_id: STAFF.owner.id, action: "facility.archived", entity_type: "facility", entity_id: fixed(434), details: { reason: "لم يعد مستخدمًا" }, created_at: ts(-20) });
  for (const id of [rIn1, rIn3, rIn4, rIn5, rArr3]) audits.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, actor_id: STAFF.supervisor.id, action: "voucher.receipt_created", entity_type: "voucher", entity_id: id, details: { after: { amount_halalas: 1 } }, created_at: ts(-1, 10) });
  put("audit_events", audits.sort((a, b) => (a.created_at < b.created_at ? 1 : -1)));
  void rArr2;
  return s;
}
