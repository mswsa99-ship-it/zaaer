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

  put("organizations", [{ id: ORG, name_ar: "فايف اورز", name_en: "Five Hours", license_number: "HSP-DEMO-001", license_status: "active", created_at: ts(-400) }]);
  put("branches", [
    { id: BRANCH_A, organization_id: ORG, name_ar: "فرع الرياض — طريق الملك فهد", name_en: "Riyadh - King Fahd Rd", city: "الرياض", address: "طريق الملك فهد، حي العليا", map_url: "https://maps.app.goo.gl/demo-riyadh", booking_platform_url: "https://www.booking.com/hotel/sa/demo-riyadh.html", country_code: "SA", default_language: "ar", phone: "+966500000000", email: "riyadh@demo.sa", check_in_time: "16:00:00", check_out_time: "12:00:00", logo_url: null, is_active: true, timezone: "Asia/Riyadh", tax_rate_bp: 0, prices_include_tax: false, default_deposit_halalas: 5000, supervisor_max_discount_bp: 1000, tax_number: null, commercial_register: "1010000000", archived_at: null, archived_by: null, archive_reason: null, version: 3, created_at: ts(-400), updated_at: ts(-30) },
    { id: BRANCH_B, organization_id: ORG, name_ar: "فرع جدة — الكورنيش", name_en: "Jeddah - Corniche", city: "جدة", address: "طريق الكورنيش", map_url: null, booking_platform_url: null, country_code: "SA", default_language: "ar", phone: "+966500000001", email: "jeddah@demo.sa", check_in_time: "15:00:00", check_out_time: "12:00:00", logo_url: null, is_active: true, timezone: "Asia/Riyadh", tax_rate_bp: 0, prices_include_tax: false, default_deposit_halalas: 5000, supervisor_max_discount_bp: 0, tax_number: null, commercial_register: null, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-200), updated_at: ts(-200) },
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
  put("staff_profiles", Object.values(STAFF).map((x) => ({ id: x.id, auth_user_id: x.auth, organization_id: ORG, full_name: x.name, email: x.email, phone: null, role: x.role, is_active: true, created_at: ts(-300), sessions_ended_at: null, updated_at: null })));
  // memberships are retired, never erased (0040, decision 35): removed_at marks one taken away
  const member = (staff_id: string, branch_id: string) => ({ id: uid(), staff_id, branch_id, created_at: ts(-300), removed_at: null, removed_by: null });
  put("branch_memberships", [
    member(STAFF.manager.id, BRANCH_A), member(STAFF.supervisor.id, BRANCH_A),
    member(STAFF.finance.id, BRANCH_A), member(STAFF.housekeeping.id, BRANCH_A),
    member(STAFF.manager.id, BRANCH_B),
  ]);
  // the twelve sources of decision 22 (0038): a code, a kind, whether the platform's number is needed; Booking Engine off (decision 23)
  const src = (id: string, code: string, name: string, kind: "direct" | "external", ref: boolean, active = true) => ({ id, organization_id: ORG, name, code, kind, external_reference_required: ref, booking_url: null, is_active: active, archived_at: null, created_at: ts(-400), commission_bp: code === "agoda" || code === "jathr_inn" ? 1500 : 0 });
  put("booking_sources", [
    src(fixed(21), "reception", "الاستقبال", "direct", false), src(fixed(20), "booking_com", "Booking.com", "external", true), src(fixed(22), "airbnb", "Airbnb", "external", true),
    src(fixed(523), "almosafer", "Almosafer Web", "external", true), src(fixed(524), "airport", "المطار", "external", false), src(fixed(525), "agoda", "Agoda.com", "external", true),
    src(fixed(526), "hotels_com", "Hotels.com", "external", true), src(fixed(527), "expedia", "Expedia", "external", true), src(fixed(528), "jathr_inn", "جذر إن", "external", true),
    src(fixed(529), "booking_engine", "Booking Engine", "direct", true, false), src(fixed(530), "trip_com", "Trip.Com", "external", true), src(fixed(531), "gathern", "Gathern", "external", true),
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
  R["203"] = mk("203", cat.one, blockMain, fl.one, "reserved", "clean");
  R["204"] = mk("204", cat.one, blockMain, fl.one, "occupied", "clean");
  R["205"] = mk("205", cat.two, blockMain, fl.one, "ready", "clean");
  R["206"] = mk("206", cat.two, blockMain, fl.one, "cleaning", "dirty");
  // the annex (U) has ordinary keys handed at reception, no key boxes: clean and out of maintenance is ready (decision 7)
  R["U1"] = mk("U-1", cat.studio, blockU, fl.uG, "ready", "clean");
  R["U2"] = mk("U-2", cat.studio, blockU, fl.uG, "occupied", "clean");
  R["U3"] = mk("U-3", cat.one, blockU, fl.uG, "ready", "clean");
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
  // Key boxes of branch A's main building (the annex and Jeddah have ordinary keys). The demo keeps a synthetic code in the
  // browser (code_plain) so «الرموز» can show and change it; the real system keeps it encrypted on the server only. Units
  // left by a guest wait for a new code (red) since then.
  put("keyboxes", rooms.filter((r) => r.branch_id === BRANCH_A && r.block_id === blockMain).map((r, i) => {
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
    { id: svc.breakfast, organization_id: ORG, branch_id: BRANCH_A, name_ar: "إفطار", name_en: "Breakfast", description: "لكل شخص لكل يوم", billing_unit: "person", price_halalas: 3500, is_free: false, taxable: true, task_type_id: null, late_checkout_until: null, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-300), updated_at: ts(-300) },
    { id: svc.late, organization_id: ORG, branch_id: BRANCH_A, name_ar: "مغادرة متأخرة حتى 4 عصرًا", name_en: "Late check-out", description: "تنقل موعد المغادرة إلى 4:00 عصرًا", billing_unit: "once", price_halalas: 10000, is_free: false, taxable: true, task_type_id: null, late_checkout_until: "16:00:00", is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-300), updated_at: ts(-300) },
    { id: svc.extraClean, organization_id: ORG, branch_id: BRANCH_A, name_ar: "تنظيف إضافي أثناء الإقامة", name_en: "Extra cleaning", description: null, billing_unit: "once", price_halalas: 8000, is_free: false, taxable: true, task_type_id: tt.clean, late_checkout_until: null, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: ts(-300), updated_at: ts(-300) },
  ]);

  // reservations
  const res: Row[] = []; const guests: Row[] = []; const allocs: Row[] = []; const charges: Row[] = []; const vouchers: Row[] = []; const audits: Row[] = [];
  let vnum = 100; let rnum = 1;
  const nextNum = (prefix: string) => `${prefix}-2026-${String(++vnum).padStart(6, "0")}`;
  const money = (resId: string, kind: string, amount: number, method: string, dayOff: number, reference: string | null = null, status = "approved") => {
    const account_id = method === "cash" ? CASH_A : method === "pos" || method === "bank_transfer" ? BANK_A : null;
    vouchers.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: resId, number: nextNum(kind === "receipt" ? "RCP" : kind === "deposit" ? "DEP" : kind === "refund" ? "RFD" : "DRF"), kind, amount_halalas: amount, method, account_id, payout_id: null, status, reference, note: null, reason: kind.includes("refund") ? "تسوية" : null, original_voucher_id: null, payment_transaction_id: null, idempotency_key: uid(), content_hash: "x", occurred_at: ts(dayOff, 14), created_by: STAFF.supervisor.id, created_at: ts(dayOff, 14), cancelled_by: null, cancelled_at: null, cancel_reason: null });
  };
  interface MkRes { guest: string; phone: string; nat?: string; cat: string; room?: string; ci: number; co: number; status: string; source?: string; ext?: string | null; adults?: number; comp?: number; identity?: string; access?: string; gov?: boolean; receipts?: number[]; otaPaid?: boolean; deposit?: number; depositRefund?: number; discount?: number; addon?: { d: string; a: number } | null; actualIn?: boolean; actualOut?: boolean; createdDays?: number; bookedDays?: number; keyboxDelivered?: boolean }
  const profileOf = new Map<string, string>();   // one profile per phone (decision 2: never merged by name)
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
    const platform = !!o.source && o.source !== fixed(21);
    const r = { id, organization_id: ORG, branch_id: BRANCH_A, internal_ref: `R-26A${String(rnum++).padStart(4, "0")}`, external_ref: o.ext ?? null, source_id: o.source ?? fixed(21), status: o.status,
      platform_booked_on: platform ? addDays(T, o.bookedDays ?? Math.min(o.createdDays ?? o.ci - 5, -1)) : null, platform_collects: platform ? !!o.otaPaid : null, platform_verified_at: null, platform_verified_by: null, cancel_reference: o.status === "cancelled" && platform ? "CXL-" + String(o.ext ?? "").slice(-5) : null, security_hold_by: null, security_hold_at: null, booking_type: "individual", company_name: null, visit_purpose: "سياحة", check_in: ci, check_out: co, adults: o.adults ?? 2, companions: o.comp ?? 0, room_category_id: o.cat, room_id: roomId,
      rent_amount_halalas: rent, discount_halalas: disc, addons_halalas: addon, taxes_halalas: tax, total_halalas: total, paid_halalas: paid, payment_status, identity_status: o.identity ?? "verified", government_registration: o.gov ?? (o.status === "checked_in" || o.status === "checked_out"), access_status: o.access ?? (o.status === "checked_in" ? "delivered" : o.status === "checked_out" ? "delivered" : "locked"), keybox_delivered: o.keyboxDelivered ?? (o.status === "checked_in"),
      checkin_approved_by: null, checkin_approved_at: null, actual_check_in: o.actualIn || o.status === "checked_in" || o.status === "checked_out" ? ts(o.ci, 17) : null, actual_check_out: o.actualOut || o.status === "checked_out" ? ts(o.co, 11) : null, notes: null, created_at: ts(o.createdDays ?? o.ci - 5), created_by: STAFF.supervisor.id, security_hold: false, security_hold_reason: null, gov_registration_ref: null, gov_registration_by: null, gov_registration_at: null, updated_at: ts(-1),
      version: 1, rate_type: "daily", price_basis: "daily", nightly_rate_halalas: rate, tax_rate_bp: 0, prices_include_tax: false, cancelled_at: null, cancel_reason: null, cancel_source: null, no_show_at: null, deposit_balance_halalas: dep - depRef, refunded_halalas: 0, balance_due_halalas: due };
    res.push(r);
    if (!profileOf.has(o.phone)) profileOf.set(o.phone, uid());
    const verified = (o.identity ?? "verified") === "verified"; const last4 = String(1000 + Math.floor(Math.random() * 8999));
    guests.push({ id: uid(), reservation_id: id, guest_profile_id: profileOf.get(o.phone)!, is_primary: true, full_name: o.guest, identity_type: "national_id", identity_number_encrypted: null, identity_number_last4: last4, identity_issue_number: null, nationality: o.nat ?? "سعودي", birth_date: "1990-05-05", phone: o.phone, phone_verified: false, relationship: null, verification_status: o.identity ?? "verified",
      identity_fingerprint: verified ? "fp_sa_demo_" + o.phone.slice(-4) + last4 : null, entry_path: (o.identity ?? "verified") !== "not_started" ? "guest" : null, entered_by: null, entered_at: (o.identity ?? "verified") !== "not_started" ? ts(o.ci - 2) : null, verified_by: verified ? STAFF.supervisor.id : null, verified_at: verified ? ts(o.ci - 1) : null,
      data_submitted: (o.identity ?? "verified") !== "not_started", created_at: r.created_at });
    if (roomId) allocs.push({ id: uid(), reservation_id: id, room_id: roomId, branch_id: BRANCH_A, from_date: ci, to_date: co, status: ["cancelled", "no_show", "rejected"].includes(o.status) ? "cancelled" : o.status === "checked_out" ? "closed" : "active", reason: "create", created_by: STAFF.supervisor.id, created_at: r.created_at, closed_at: null });
    charges.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: id, kind: "rent", description: `إيجار ${nights} ليلة × ${(rate / 100).toFixed(2)} ر.س`, quantity: nights, unit_price_halalas: rate, total_halalas: rent, taxable: true, service_definition_id: null, invoice_id: null, reason: null, created_by: STAFF.supervisor.id, created_at: r.created_at, service_from: ci, service_to: co, base_charge_id: null });
    if (disc) charges.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: id, kind: "discount", description: "خصم ضيف دائم", quantity: 1, unit_price_halalas: disc, total_halalas: -disc, taxable: true, service_definition_id: null, invoice_id: null, reason: "ضيف دائم", created_by: STAFF.manager.id, created_at: r.created_at, service_from: ci, service_to: co, base_charge_id: null });
    if (o.addon) charges.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: id, kind: "addon", description: o.addon.d, quantity: 1, unit_price_halalas: o.addon.a, total_halalas: o.addon.a, taxable: true, service_definition_id: svc.breakfast, invoice_id: null, reason: null, created_by: STAFF.supervisor.id, created_at: r.created_at, service_from: ci, service_to: ci, base_charge_id: null });
    if (tax) charges.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: id, kind: "tax", description: "ضريبة القيمة المضافة", quantity: 1, unit_price_halalas: tax, total_halalas: tax, taxable: false, service_definition_id: null, invoice_id: null, reason: null, created_by: STAFF.supervisor.id, created_at: r.created_at, service_from: ci, service_to: co, base_charge_id: null });
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
  // ready to arrive except the deposit: the arrival screen takes it (or records why not)
  const rArr3 = mkRes({ guest: "تركي عبدالعزيز المطيري", phone: "0501110008", cat: cat.one, room: "203", ci: 0, co: 5, status: "confirmed", adults: 1, receipts: [230000], identity: "verified", access: "locked", gov: true });
  // overdue arrival
  mkRes({ guest: "بدر راشد العنزي", phone: "0501110009", cat: cat.studio, ci: -1, co: 2, status: "confirmed", receipts: [], identity: "not_started", access: "locked", gov: false });
  // future
  mkRes({ guest: "لطيفة حمد السبيعي", phone: "0501110010", cat: cat.two, room: "205", ci: 2, co: 6, status: "confirmed", receipts: [69000], identity: "not_started", access: "locked", gov: false, createdDays: -4 });
  // taken by the platform six days ago and entered here two days ago: the late-entry report's one row (decision 4)
  mkRes({ guest: "Yusuf Demir", phone: "0501110011", nat: "تركي", cat: cat.one, ci: 5, co: 9, status: "confirmed", receipts: [], identity: "not_started", access: "locked", gov: false, otaPaid: true, source: fixed(20), ext: "BK-4489931", createdDays: -2, bookedDays: -6 });
  mkRes({ guest: "ريم فهد الغامدي", phone: "0501110012", cat: cat.studio, room: "U1", ci: 1, co: 2, status: "confirmed", receipts: [28750], identity: "verified", access: "locked", gov: false, createdDays: -1 });
  // checked out with deposit to settle
  const rOut1 = mkRes({ guest: "ماجد سلمان الزهراني", phone: "0501110013", cat: cat.two, room: "206", ci: -4, co: 0, status: "checked_out", receipts: [276000], deposit: 40000, actualOut: true });
  const rHassan = mkRes({ guest: "Hassan Karim", phone: "0501110014", nat: "مصري", cat: cat.studio, room: "103", ci: -3, co: 0, status: "checked_out", receipts: [86250], deposit: 20000, depositRefund: 20000, actualOut: true });
  const rNawaf = mkRes({ guest: "نواف خالد الشمري", phone: "0501110015", cat: cat.one, room: "202", ci: -5, co: -1, status: "checked_out", receipts: [184000], deposit: 30000, depositRefund: 20000, actualOut: true });
  // cancelled / no-show
  mkRes({ guest: "هند عبدالله القرني", phone: "0501110016", cat: cat.studio, ci: -2, co: 0, status: "cancelled", receipts: [], identity: "not_started", source: fixed(20), ext: "BK-4432100", createdDays: -8 });
  mkRes({ guest: "Rami Nasser", phone: "0501110017", nat: "لبناني", cat: cat.one, ci: -1, co: 1, status: "no_show", receipts: [], identity: "not_started", createdDays: -6 });
  // history
  const history: string[] = [];
  for (let i = 1; i <= 6; i++) history.push(mkRes({ guest: ["عمر الحربي", "Sara Khan", "ياسر العمري", "Mohammed Ali", "دلال الراشد", "Noura Fahad"][i - 1], phone: "05011100" + (20 + i), cat: [cat.studio, cat.one, cat.two][i % 3], room: ["101", "203", "205", "U1", "102", "204"][i - 1], ci: -10 - i * 3, co: -7 - i * 3, status: "checked_out", receipts: [[86250, 138000, 207000][i % 3]], deposit: 20000, depositRefund: 20000, actualOut: true }));
  // a returning guest with a second, later stay (WhatsApp lists both bookings of her number)
  mkRes({ guest: "لطيفة حمد السبيعي", phone: "0501110010", cat: cat.one, ci: 20, co: 23, status: "confirmed", receipts: [], identity: "not_started", access: "locked", gov: false, createdDays: -1 });
  // mark cancelled/no_show rows
  for (const r of res) { if (r.status === "cancelled") { r.cancelled_at = ts(-3); r.cancel_reason = "إلغاء من المنصة"; r.cancel_source = "ota"; } if (r.status === "no_show") { r.no_show_at = ts(0, 9); r.cancel_reason = "لم يحضر ولم يرد"; } }
  // the stay cycle (0033): who registered each arrival and departure; Shomoos registered with every guest and accepted;
  // the annex's units take their key at reception (no code to deliver)
  const at = (iso: string, minutes: number) => new Date(Date.parse(iso) + minutes * 60_000).toISOString();
  const annex = new Set(rooms.filter((x) => x.block_id === blockU).map((x) => x.id));
  let shm = 480120;
  for (const r of res) {
    Object.assign(r, { checked_in_by: r.actual_check_in ? STAFF.supervisor.id : null, checkin_approved_by: r.actual_check_in ? STAFF.supervisor.id : null, checkin_approved_at: r.actual_check_in,
      checked_out_by: r.actual_check_out ? STAFF.supervisor.id : null, closed_at: null, deposit_waiver_reason: null, deposit_waiver_by: null, deposit_waiver_at: null,
      shomoos_guest_count: null, shomoos_accepted_at: null, shomoos_accepted_by: null, late_checkout_until: null, status_before_cancel: r.status === "cancelled" ? "confirmed" : null });
    if (r.government_registration) {
      const reg = r.actual_check_in ? at(r.actual_check_in, -25) : new Date(Date.now() - 50 * 60_000).toISOString();
      Object.assign(r, { gov_registration_ref: `SHM-${shm += 7}`, gov_registration_by: STAFF.supervisor.id, gov_registration_at: reg, shomoos_guest_count: r.adults + r.companions, shomoos_accepted_at: at(reg, 12), shomoos_accepted_by: STAFF.supervisor.id });
    }
    if (r.room_id && annex.has(r.room_id) && ["checked_in", "checked_out"].includes(r.status)) Object.assign(r, { access_status: "key_handed", keybox_delivered: false });
  }
  for (const a of allocs) if (a.status === "closed") a.closed_at = res.find((r) => r.id === a.reservation_id)?.actual_check_out ?? null;
  // a code delivered to a guest in house is that guest's (fn_staff_deliver_access_code sets it)
  for (const r of res) if (r.status === "checked_in" && r.access_status === "delivered") { const kb = s.keyboxes.find((k) => k.room_id === r.room_id); if (kb) Object.assign(kb, { last_reservation_id: r.id, last_delivered_at: r.actual_check_in }); }
  put("reservations", res); put("reservation_guests", guests); put("reservation_allocations", allocs); put("reservation_charges", charges); put("financial_vouchers", vouchers);
  // invoices: the first checked-out stay, and every stay of the history — whose stays are «مغلق» (decision 59: departed, nothing
  // owed either way, the deposit settled, every line invoiced)
  const invoices: Row[] = []; let invNo = 34;
  const invoice = (resId: string, issuedAt: string) => {
    const r = res.find((x) => x.id === resId)!; const lines = charges.filter((c) => c.reservation_id === resId); const id = uid(); lines.forEach((c) => (c.invoice_id = id));
    const name = guests.find((g) => g.reservation_id === resId && g.is_primary)?.full_name ?? null; const bill_to = name ? { name } : {};
    const shares = lines.map((c) => ({ charge_id: c.id, kind: c.kind, description: c.description, quantity: c.quantity, unit_price_halalas: c.unit_price_halalas, total_halalas: c.total_halalas, amount_halalas: c.total_halalas, service_from: c.service_from, service_to: c.service_to }));
    const sub = lines.filter((c) => c.kind !== "tax").reduce((a, c) => a + c.total_halalas, 0), tax = lines.filter((c) => c.kind === "tax").reduce((a, c) => a + c.total_halalas, 0);
    const branch = s.branches.find((b) => b.id === BRANCH_A)!;
    const inv: Row = { id, organization_id: ORG, branch_id: BRANCH_A, reservation_id: resId, number: `INV-2026-${String(++invNo).padStart(6, "0")}`, period_from: r.check_in, period_to: r.check_out, scope: "remaining", origin: "checkout", version: 1, versions: [], bill_to, status: "issued",
      snapshot: { property: { name: branch.name_ar, tax_number: branch.tax_number ?? null, commercial_register: branch.commercial_register ?? null, address: branch.address ?? null }, guest: { name }, bill_to,
        reservation: { internal_ref: r.internal_ref, external_ref: r.external_ref, check_in: r.check_in, check_out: r.check_out, room: rooms.find((x) => x.id === r.room_id)?.room_number ?? null },
        period: { from: r.check_in, to: r.check_out, scope: "remaining", requested: false }, origin: "checkout", charge_ids: shares.map((x) => x.charge_id), lines: shares, tax_rate_bp: 0 },
      subtotal_halalas: sub, tax_halalas: tax, total_halalas: sub + tax, issued_by: STAFF.supervisor.id, issued_at: issuedAt, updated_at: null, updated_by: null, cancelled_by: null, cancelled_at: null, cancel_reason: null };
    invoices.push(inv); return inv;
  };
  for (const id of history) { const r = res.find((x) => x.id === id)!; invoice(id, at(r.actual_check_out, 40)); Object.assign(r, { status: "closed", closed_at: at(r.actual_check_out, 40) }); }
  invoice(rOut1, ts(0, 11));
  // an invoice edited the day after (decision 26): the company the guest asked for on it; the version before is kept, and the
  // edit waits in the owner's review list «بحاجة لمراجعة وتدقيق»
  const edited = invoices[0]; const editedAt = at(edited.issued_at, 18 * 60);
  const v1 = { version: 1, period_from: edited.period_from, period_to: edited.period_to, bill_to: edited.bill_to, subtotal_halalas: edited.subtotal_halalas, tax_halalas: edited.tax_halalas, total_halalas: edited.total_halalas,
    lines: edited.snapshot.lines, since: edited.issued_at, by: STAFF.supervisor.name, replaced_at: editedAt, replaced_by: STAFF.manager.name, reason: "طلب الضيف إصدارها باسم جهة عمله" };
  const company = { name: "شركة الأفق للتجارة", note: "مرجع الطلب PO-2231" };
  Object.assign(edited, { version: 2, versions: [v1], bill_to: company, snapshot: { ...edited.snapshot, bill_to: company }, updated_at: editedAt, updated_by: STAFF.manager.id });
  const editedRes = res.find((x) => x.id === edited.reservation_id)!;
  put("invoices", invoices);
  // the check-out inspections (decision 5): sound for the history and Hassan (their deposits went back after it); notes with a
  // suggested deduction for نواف (half his deposit is still held); none yet for ماجد, so his deposit waits for one
  const inspection = (resId: string, result: string, notes: string | null, suggested: number) => { const r = res.find((x) => x.id === resId)!;
    return { id: uid(), organization_id: ORG, branch_id: BRANCH_A, reservation_id: resId, room_id: r.room_id, result, notes, suggested_deduction_halalas: suggested, status: "active", inspected_by: STAFF.housekeeping.id, inspected_at: at(r.actual_check_out, 25), superseded_at: null, superseded_by: null }; };
  put("checkout_inspections", [...history.map((id) => inspection(id, "ok", null, 0)), inspection(rHassan, "ok", null, 0), inspection(rNawaf, "notes", "بقعة على قماش الأريكة تحتاج تنظيفًا خاصًا", 2500)]);
  put("stay_payment_exceptions", []);
  put("review_items", [{ id: uid(), organization_id: ORG, branch_id: BRANCH_A, kind: "invoice_edited", entity_type: "invoice", entity_id: edited.id, reservation_id: editedRes.id,
    summary: `تعديل الفاتورة ${edited.number} (الإصدار 2)`, reason: v1.reason, details: { number: edited.number, version: 2, before_total_halalas: v1.total_halalas, after_total_halalas: edited.total_halalas, before_period: [v1.period_from, v1.period_to], after_period: [edited.period_from, edited.period_to] },
    created_by: STAFF.manager.id, created_at: editedAt, reviewed_at: null, reviewed_by: null, review_note: null }]);
  put("monitor_runs", []);
  // one profile per phone; a verified document gives the profile its fingerprint; one guest rated, one banned (decision 21)
  const profiles: Row[] = []; const seenProfile = new Set<string>();
  for (const g of guests) {
    if (!g.is_primary || seenProfile.has(g.guest_profile_id)) continue; seenProfile.add(g.guest_profile_id);
    const first = guests.find((x) => x.guest_profile_id === g.guest_profile_id && x.identity_fingerprint);
    profiles.push({ id: g.guest_profile_id, organization_id: ORG, full_name: g.full_name, phone: g.phone, nationality: g.nationality, email: null, notes: null, identity_fingerprint: first?.identity_fingerprint ?? null, identity_type: first ? "national_id" : null, identity_last4: first?.identity_number_last4 ?? null, rating: null, rating_note: null, rated_by: null, rated_at: null, created_at: g.created_at, updated_at: g.created_at });
  }
  const rated = profiles.find((p) => p.phone === "0501110004"); if (rated) Object.assign(rated, { rating: 2, rating_note: "تأخرت في المغادرة مرتين وتركت الوحدة غير مرتبة", rated_by: STAFF.supervisor.id, rated_at: ts(-1) });
  const good = profiles.find((p) => p.phone === "0501110001"); if (good) Object.assign(good, { rating: 5, rating_note: "ضيف دائم ومنتظم", rated_by: STAFF.manager.id, rated_at: ts(-10) });
  put("guest_profiles", profiles);
  const banned = profiles.find((p) => p.phone === "0501110017");
  put("guest_bans", banned ? [{ id: uid(), organization_id: ORG, guest_profile_id: banned.id, name_snapshot: banned.full_name, phones: ["966501110017"], fingerprints: [banned.identity_fingerprint].filter(Boolean), reason: "لم يحضر مرتين دون إشعار وأساء للموظفين", created_by: STAFF.manager.id, created_at: ts(-1), lifted_at: null, lifted_by: null, lift_reason: null }] : []);
  put("stay_acknowledgements", []);
  put("branch_media", []);
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
  put("code_rotation_events", [{ id: uid(), room_id: R["102"], from_version: 2, to_version: 3, field_tested: true, created_at: ts(-1, 13) }, { id: uid(), room_id: R["203"], from_version: 2, to_version: 3, field_tested: true, created_at: ts(-1, 14) }]);
  put("access_delivery_events", res.filter((r) => r.status === "checked_in" && r.access_status === "delivered").map((r) => ({ id: uid(), reservation_id: r.id, keybox_id: s.keyboxes.find((k) => k.room_id === r.room_id)?.id ?? null, channel: "screen", delivered_by: STAFF.supervisor.id, acknowledged: true, created_at: at(r.actual_check_in, 5) })));
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
  audits.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, actor_id: STAFF.supervisor.id, action: "reservation.checked_out", entity_type: "reservation", entity_id: rOut1, details: { before: { status: "checked_in" }, after: { status: "checked_out", deposit_balance_halalas: 5000, credit_halalas: 0 } }, created_at: ts(0, 11) });
  audits.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, actor_id: STAFF.owner.id, action: "facility.archived", entity_type: "facility", entity_id: fixed(434), details: { reason: "لم يعد مستخدمًا" }, created_at: ts(-20) });
  for (const id of [rIn1, rIn3, rIn4, rIn5, rArr3]) audits.push({ id: uid(), organization_id: ORG, branch_id: BRANCH_A, actor_id: STAFF.supervisor.id, action: "voucher.receipt_created", entity_type: "voucher", entity_id: id, details: { after: { amount_halalas: 1 } }, created_at: ts(-1, 10) });
  // the trace columns of 0026 as the migration back-fills them (a staff member at a screen, a successful business row)
  put("audit_events", audits.sort((a, b) => (a.created_at < b.created_at ? 1 : -1)).map((a) => ({ correlation_id: "legacy-" + a.id, source: "screen", actor_type: "staff", result: "success", category: "business", ...a })));
  void rArr2;
  return s;
}
