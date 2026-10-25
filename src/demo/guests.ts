/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0038 (phase 5: guests, platforms and the website). The same rules as the SQL functions:
 *  - guest data on two paths (decision 2): the guest's own form, or the office from the original document («طابقتُ
 *    الوثيقة الأصلية»), which verifies at once; a correction needs a reason and leaves masked values before and after;
 *    a verified document links a guest profile (never merged; duplicates by phone or document are flagged);
 *  - bans by profile, phone or document, holds on one booking, a rating 1–5 with an internal note (decision 21);
 *  - platform fields, the platform's receipt «آجل عبر المنصات», cancelling by the platform's number (decision 4),
 *    one platform number per booking or group (decision 69);
 *  - «ملخص الإقامة» and its acceptance, electronic or on paper (decision 19);
 *  - the branch's fields, logo and image (decision 31).
 * A document's fingerprint here is a plain hash of the number (the demo keeps no secret); the number itself is never stored.
 */
import { uid, nowISO, ORG, type Row } from "./data";

export interface GuestCtx {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  myBranches: () => string[];
  hasRole: (...roles: string[]) => boolean;
  requireRole: (...roles: string[]) => void;
  requireBranch: (b: string | null | undefined) => void;
  staffId: () => string | null;
  staffName: (id: string | null | undefined) => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string, details: Row) => void;
  addReview: (branch: string, kind: string, entityType: string, entityId: string, resId: string | null, summary: string, reason: string | null, details: Row) => void;
  emit: (table: string) => void;
  normPhone: (p: unknown) => string | null;
  financeOf: (resId: string) => Row;
  stayDue: (resId: string) => Row;
  branchToday: (b?: string) => string;
  roomNo: (roomId: string | null) => string | null;
  releaseAllocations: (resId: string, mode: "cancel" | "close", at?: string) => void;
  createVoucher: (p: Row) => Row;
  atomically: <V>(fn: () => V) => V;
}

/** A document's fingerprint: the same number → the same string, nothing recoverable (a keyed hash on the server). */
export function fingerprint(type: string | null | undefined, number: string | null | undefined): string | null {
  const n = String(number ?? "").replace(/\s/g, "").toUpperCase();
  if (!n || !type) return null;
  const space = type === "national_id" || type === "iqama" ? "sa" : type === "gcc_id" ? "gcc" : "pp";
  let h = 2166136261;
  for (const ch of `fp|${space}|${n}`) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619) >>> 0; }
  let h2 = 5381;
  for (const ch of n) h2 = (Math.imul(h2, 33) + ch.charCodeAt(0)) >>> 0;
  return `fp_${space}_${h.toString(16).padStart(8, "0")}${h2.toString(16).padStart(8, "0")}`;
}

export function checkIdentity(type: string, number: string) {
  if (["national_id", "iqama"].includes(type) && !/^[12]\d{9}$/.test(number)) throw new Error("VALIDATION: identity_number_format");
  if (type === "gcc_id" && !/^[A-Za-z0-9]{6,15}$/.test(number)) throw new Error("VALIDATION: identity_number_format");
  if (type === "passport" && !/^[A-Za-z0-9]{5,12}$/.test(number)) throw new Error("VALIDATION: identity_number_format");
}

/** the branch's calendar day of a moment (the demo's branches keep Riyadh time, like todayISO) */
const localDay = (iso: string) => new Date(iso).toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
const maskPhone = (p: unknown) => { const d = String(p ?? "").replace(/\D/g, ""); return d ? "••••" + d.slice(-4) : null; };
const VALID_MAP = /^https:\/\/((www\.)?google\.[a-z.]{2,10}\/maps|maps\.google\.[a-z.]{2,10}\/|maps\.app\.goo\.gl\/|goo\.gl\/maps\/)[^\s<>"]*$/i;
const VALID_HTTPS = /^https:\/\/[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]{2,5})?(\/[^\s<>"]*)?$/i;
export const validMapUrl = (u: string) => VALID_MAP.test(u) && u.length <= 500;
export const validHttpsUrl = (u: string) => VALID_HTTPS.test(u) && u.length <= 500;

const sar = (h: number, lang: string) => (lang === "en" ? `SAR ${(h / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}` : `${(h / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ر.س`);

/** A short, stable hash of the summary's text (the server uses sha256; the demo only needs "the same text → the same hash"). */
export function textHash(s: string): string {
  let a = 0x811c9dc5, b = 0x12345678;
  for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i); a = Math.imul(a ^ c, 16777619) >>> 0; b = (Math.imul(b, 31) + c + i) >>> 0; }
  return `${a.toString(16).padStart(8, "0")}${b.toString(16).padStart(8, "0")}${s.length.toString(16).padStart(6, "0")}`;
}

/** The two image types by their first bytes (the server reads the same magic numbers). */
function sniffImage(bytes: Uint8Array): string | null {
  const hex = Array.from(bytes.slice(0, 12), (x) => x.toString(16).padStart(2, "0")).join("");
  if (hex.startsWith("89504e470d0a1a0a")) return "image/png";
  if (hex.startsWith("ffd8ff")) return "image/jpeg";
  if (hex.startsWith("52494646") && hex.slice(16, 24) === "57454250") return "image/webp";
  return null;
}
function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64.replace(/\s/g, ""));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function guestRpcs(c: GuestCtx): Record<string, (a: any) => any> {
  const { T, byId, myBranches, hasRole, requireRole, requireBranch, staffId, staffName, audit, addReview, emit, normPhone, financeOf, branchToday, roomNo } = c;
  const res = (id: string) => { const r = byId("reservations", id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); return r; };
  const guestsOf = (resId: string) => T("reservation_guests").filter((g) => g.reservation_id === resId);
  const primary = (resId: string) => guestsOf(resId).find((g) => g.is_primary) ?? null;
  const masked = (g: Row | undefined) => g ? Object.fromEntries(Object.entries({
    guest_id: g.id, full_name: g.full_name, identity_type: g.identity_type, identity_number: g.identity_number_last4 ? "••••" + g.identity_number_last4 : null,
    identity_issue_number: g.identity_issue_number ? "••" + String(g.identity_issue_number).slice(-2) : null, nationality: g.nationality,
    birth_year: g.birth_date ? Number(String(g.birth_date).slice(0, 4)) : null, phone: maskPhone(g.phone), relationship: g.relationship,
    verification_status: g.verification_status, entry_path: g.entry_path ?? null }).filter(([, v]) => v != null)) : null;
  const rollup = (r: Row) => {
    const g = guestsOf(r.id); const req = r.adults + r.companions;
    const v = g.filter((x) => x.verification_status === "verified").length, s = g.filter((x) => x.data_submitted).length, rj = g.filter((x) => x.verification_status === "rejected").length;
    const st = v >= req && v === g.length && g.length > 0 ? "verified" : rj > 0 ? "rejected" : s >= req && s === g.length && g.length > 0 ? "pending_supervisor" : s > 0 ? "data_submitted" : "not_started";
    if (st !== r.identity_status) { r.identity_status = st; r.updated_at = nowISO(); emit("reservations"); }
    return st;
  };
  // a verified guest joins a profile: its own, else the one profile with the document, else a new one; two → unlinked and flagged
  const linkProfile = (g: Row): string | null => {
    if (!g.identity_fingerprint || g.verification_status !== "verified") return g.guest_profile_id ?? null;
    if (g.guest_profile_id) { const p = byId("guest_profiles", g.guest_profile_id); if (p && !p.identity_fingerprint) Object.assign(p, { identity_fingerprint: g.identity_fingerprint, identity_type: g.identity_type, identity_last4: g.identity_number_last4, nationality: p.nationality ?? g.nationality, updated_at: nowISO() }); return g.guest_profile_id; }
    const same = T("guest_profiles").filter((p) => p.organization_id === ORG && p.identity_fingerprint === g.identity_fingerprint);
    if (same.length > 1) return null;
    let p = same[0];
    if (!p) { p = { id: uid(), organization_id: ORG, full_name: g.full_name, phone: g.phone, nationality: g.nationality, email: null, notes: null, identity_fingerprint: g.identity_fingerprint, identity_type: g.identity_type, identity_last4: g.identity_number_last4, rating: null, rating_note: null, rated_by: null, rated_at: null, created_at: nowISO(), updated_at: nowISO() }; T("guest_profiles").push(p); }
    g.guest_profile_id = p.id; emit("guest_profiles"); emit("reservation_guests");
    return p.id;
  };
  const activeBans = () => T("guest_bans").filter((b) => b.organization_id === ORG && !b.lifted_at);
  const banMatches = (resId: string): Row[] => {
    const out: Row[] = [];
    for (const b of activeBans()) {
      const ways = new Set<string>();
      for (const g of guestsOf(resId)) {
        if (g.guest_profile_id && g.guest_profile_id === b.guest_profile_id) ways.add("profile");
        if (g.identity_fingerprint && (b.fingerprints ?? []).includes(g.identity_fingerprint)) ways.add("identity");
        const ph = normPhone(g.phone); if (ph && (b.phones ?? []).includes(ph)) ways.add("phone");
      }
      if (ways.size) out.push({ ban_id: b.id, name: b.name_snapshot, reason: b.reason, since: b.created_at, matched_by: [...ways].sort() });
    }
    return out.sort((a, b) => (a.since < b.since ? -1 : 1));
  };
  const profileBan = (p: Row): Row | null => activeBans().find((b) => b.guest_profile_id === p.id || (p.identity_fingerprint && (b.fingerprints ?? []).includes(p.identity_fingerprint)) || (normPhone(p.phone) && (b.phones ?? []).includes(normPhone(p.phone)!))) ?? null;
  const profileVisible = (p: Row) => hasRole("owner") || T("reservation_guests").some((g) => g.guest_profile_id === p.id && myBranches().includes(byId("reservations", g.reservation_id)?.branch_id));
  const duplicatesOf = (p: Row) => T("guest_profiles").filter((o) => o.organization_id === p.organization_id && o.id !== p.id && ((normPhone(o.phone) && normPhone(o.phone) === normPhone(p.phone)) || (o.identity_fingerprint && o.identity_fingerprint === p.identity_fingerprint)))
    .map((o) => ({ id: o.id, full_name: o.full_name, match: o.identity_fingerprint && o.identity_fingerprint === p.identity_fingerprint ? "identity" : "phone", stays: new Set(T("reservation_guests").filter((g) => g.guest_profile_id === o.id).map((g) => g.reservation_id)).size }));
  const staysOf = (pid: string) => new Set(T("reservation_guests").filter((g) => g.guest_profile_id === pid).map((g) => g.reservation_id)).size;
  const lastCheckIn = (pid: string) => T("reservation_guests").filter((g) => g.guest_profile_id === pid).map((g) => byId("reservations", g.reservation_id)?.check_in as string | undefined).filter(Boolean).sort().pop() ?? null;

  // ---- the stay summary (decision 19) ----
  const summaryOf = (r: Row) => {
    const b = byId("branches", r.branch_id)!; const lang = b.default_language ?? "ar"; const en = lang === "en";
    const src = byId("booking_sources", r.source_id); const cat = byId("room_categories", r.room_category_id); const room = roomNo(r.room_id);
    const g = primary(r.id)?.full_name ?? null; const f = financeOf(r.id); const nights = Math.round((Date.parse(r.check_out) - Date.parse(r.check_in)) / 86400000);
    const ci = String(b.check_in_time ?? "16:00").slice(0, 5); const co = String(r.late_checkout_until ?? b.check_out_time ?? "12:00").slice(0, 5); const dep = Number(b.default_deposit_halalas ?? 0);
    const pols = T("property_policies").filter((p) => p.branch_id === r.branch_id && p.is_public).sort((x, y) => (x.sort_order ?? 0) - (y.sort_order ?? 0) || (x.created_at < y.created_at ? -1 : 1))
      .map((p) => ({ title: p.title, content: en && String(p.content_en ?? "").trim() ? p.content_en : p.content_ar }));
    const extras = f.addons + f.penalties + f.adjustments; const t: string[] = [];
    if (en) {
      t.push(`Stay summary — ${b.name_en || b.name_ar}`, `Booking: ${r.internal_ref}`);
      if (r.external_ref) t.push(`Platform booking number: ${r.external_ref}${src ? ` (${src.name})` : ""}`);
      if (g) t.push(`Guest: ${g}`);
      t.push(`Unit: ${cat?.name_en || cat?.name_ar || "—"}${room ? ` — no. ${room}` : ""}`, `Arrival: ${r.check_in} from ${ci}`, `Departure: ${r.check_out} by ${co}`, `Nights: ${nights}`, `Rent: ${sar(f.rent, lang)}`);
      if (f.discounts) t.push(`Discount: ${sar(Math.abs(f.discounts), lang)}`); if (extras) t.push(`Extras: ${sar(extras, lang)}`); if (f.tax) t.push(`Tax: ${sar(f.tax, lang)}`);
      t.push(`Total: ${sar(f.total, lang)}`, `Paid: ${sar(f.net_collected, lang)}`, `Balance: ${sar(f.balance_due, lang)}`, `Deposit: ${sar(dep, lang)} per unit, returned after the unit is inspected at departure${f.deposit_balance > 0 ? ` (held: ${sar(f.deposit_balance, lang)})` : ""}`);
      if (pols.length) t.push("", "Branch policies:");
    } else {
      t.push(`ملخص الإقامة — ${b.name_ar}`, `الحجز: ${r.internal_ref}`);
      if (r.external_ref) t.push(`رقم الحجز في المنصة: ${r.external_ref}${src ? ` (${src.name})` : ""}`);
      if (g) t.push(`الضيف: ${g}`);
      t.push(`الوحدة: ${cat?.name_ar ?? "—"}${room ? ` — رقم ${room}` : ""}`, `الوصول: ${r.check_in} من الساعة ${ci}`, `المغادرة: ${r.check_out} حتى الساعة ${co}`, `عدد الليالي: ${nights}`, `الإيجار: ${sar(f.rent, lang)}`);
      if (f.discounts) t.push(`الخصم: ${sar(Math.abs(f.discounts), lang)}`); if (extras) t.push(`الإضافات: ${sar(extras, lang)}`); if (f.tax) t.push(`الضريبة: ${sar(f.tax, lang)}`);
      t.push(`الإجمالي: ${sar(f.total, lang)}`, `المدفوع: ${sar(f.net_collected, lang)}`, `المتبقي: ${sar(f.balance_due, lang)}`, `التأمين: ${sar(dep, lang)} للوحدة، يُرد بعد فحص الوحدة عند المغادرة${f.deposit_balance > 0 ? ` (المقبوض: ${sar(f.deposit_balance, lang)})` : ""}`);
      if (pols.length) t.push("", "سياسات الفرع:");
    }
    for (const p of pols) t.push(`• ${p.title}: ${String(p.content).replace(/\s+/g, " ")}`);
    const text = t.join("\n");
    const logo = T("branch_media").find((m) => m.branch_id === b.id && m.kind === "logo" && m.data_url);
    return { language: lang, text, hash: textHash(text),
      branch: { id: b.id, name: en ? b.name_en || b.name_ar : b.name_ar, name_ar: b.name_ar, name_en: b.name_en, city: b.city, address: b.address, phone: b.phone, country_code: b.country_code ?? "SA", commercial_register: b.commercial_register, logo_version: logo ? String(logo.sha256).slice(0, 12) : null },
      reservation: { id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref, source: src?.name ?? null, guest_name: g, category: en ? cat?.name_en || cat?.name_ar : cat?.name_ar, room_number: room, check_in: r.check_in, check_out: r.check_out, check_in_time: ci, check_out_time: co, nights },
      money: { rent: f.rent, discounts: f.discounts, extras, tax: f.tax, total: f.total, paid: f.net_collected, balance: f.balance_due, deposit_required: dep, deposit_held: f.deposit_balance },
      policies: pols };
  };
  const ackList = (resId: string) => T("stay_acknowledgements").filter((a) => a.reservation_id === resId).sort((a, b) => (a.accepted_at < b.accepted_at ? 1 : -1))
    .map((a) => ({ id: a.id, method: a.method, language: a.language, accepted_at: a.accepted_at, text_hash: a.text_hash, recorded_by: staffName(a.recorded_by) }));
  const recordAck = (r: Row, guestId: string | null, method: string, hash: string, by: string | null) => {
    const s = summaryOf(r); if (!hash || hash !== s.hash) throw new Error("SUMMARY_CHANGED: the stay summary changed; read it again");
    const dup = T("stay_acknowledgements").find((a) => a.reservation_id === r.id && a.text_hash === hash && a.method === method);
    if (dup) return { ok: true, duplicate: true, accepted_at: dup.accepted_at };
    const a = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, guest_id: guestId, method, language: s.language, text_snapshot: s.text, text_hash: hash, accepted_at: nowISO(), recorded_by: by };
    T("stay_acknowledgements").push(a); emit("stay_acknowledgements");
    return { ok: true, duplicate: false, accepted_at: a.accepted_at };
  };
  const tokenRes = (token: string) => { const s = T("registration_sessions").find((x) => x.token === token); if (!s) throw new Error("TOKEN_INVALID"); return res(s.reservation_id); };

  return {
    // ---- the office path (decision 2) ----
    fn_staff_enter_guest: ({ p }) => c.atomically(() => {
      requireRole("owner", "manager", "supervisor");
      const r = res(p.reservation_id); requireBranch(r.branch_id);
      if (["cancelled", "rejected", "closed", "checked_out", "no_show"].includes(r.status)) throw new Error("RESERVATION_NOT_EDITABLE");
      if (p.document_matched !== true) throw new Error("VALIDATION: document_matched");
      const name = String(p.full_name ?? "").trim(); if (name.split(/\s+/).length < 3) throw new Error("VALIDATION: full_name_three_parts");
      const type = String(p.identity_type ?? ""); if (!["national_id", "iqama", "passport", "gcc_id"].includes(type)) throw new Error("VALIDATION: identity_type");
      const number = String(p.identity_number ?? "").replace(/\s/g, ""); const g = p.guest_id ? byId("reservation_guests", p.guest_id) : null;
      if (p.guest_id && (!g || g.reservation_id !== r.id)) throw new Error("GUEST_NOT_FOUND");
      const correcting = !!g?.data_submitted; let fp: string | null;
      if (!number) { if (!correcting || !g!.identity_fingerprint || type !== g!.identity_type) throw new Error("VALIDATION: identity_number_format"); fp = g!.identity_fingerprint; }
      else { checkIdentity(type, number); fp = fingerprint(type, number); }
      const nat = String(p.nationality ?? "").trim(); if (!nat) throw new Error("VALIDATION: nationality");
      const birth = String(p.birth_date ?? ""); if (!/^\d{4}-\d{2}-\d{2}$/.test(birth) || Number.isNaN(Date.parse(birth))) throw new Error("VALIDATION: birth_date");
      const today = branchToday(r.branch_id); if (birth > today || Number(birth.slice(0, 4)) < Number(today.slice(0, 4)) - 120) throw new Error("VALIDATION: birth_date_range");
      const reason = String(p.reason ?? "").trim() || null; if (correcting && !reason) throw new Error("VALIDATION: reason");
      if (guestsOf(r.id).some((x) => x.identity_fingerprint === fp && x.id !== g?.id)) throw new Error("DUPLICATE_GUEST");
      const phone = String(p.phone ?? "").replace(/[^0-9+]/g, "") || null; const issue = String(p.identity_issue_number ?? "").trim() || null; const rel = String(p.relationship ?? "").trim() || null;
      const before = masked(g ?? undefined); let target: Row;
      if (g) {
        Object.assign(g, { full_name: name, identity_type: type, identity_number_last4: number ? number.slice(-4) : g.identity_number_last4, identity_issue_number: issue, identity_fingerprint: fp, nationality: nat, birth_date: birth,
          phone: phone ?? g.phone, relationship: g.is_primary ? "self" : rel ?? g.relationship ?? "other", data_submitted: true, verification_status: "verified", entry_path: "office",
          entered_by: staffId(), entered_at: nowISO(), verified_by: staffId(), verified_at: nowISO() });
        target = g;
      } else {
        if (guestsOf(r.id).length >= r.adults + r.companions) throw new Error("GUEST_LIMIT_REACHED");
        target = { id: uid(), reservation_id: r.id, guest_profile_id: null, is_primary: false, full_name: name, identity_type: type, identity_number_last4: number.slice(-4), identity_issue_number: issue, identity_fingerprint: fp, nationality: nat, birth_date: birth, phone, phone_verified: false, relationship: rel ?? "other", verification_status: "verified", data_submitted: true, entry_path: "office", entered_by: staffId(), entered_at: nowISO(), verified_by: staffId(), verified_at: nowISO(), created_at: nowISO() };
        T("reservation_guests").push(target);
      }
      linkProfile(target); const st = rollup(r); emit("reservation_guests");
      audit(r.branch_id, correcting ? "guest.corrected" : "guest.entered_from_document", "reservation", r.id, { before, after: masked(target), reason });
      if (correcting) addReview(r.branch_id, "guest_corrected", "reservation_guest", target.id, r.id, `تصحيح بيانات نزيل في ${r.internal_ref}`, reason, { before, after: masked(target) });
      return { ok: true, guest_id: target.id, identity_status: st };
    }),
    fn_staff_approve_identity: ({ p_guest_id, p_approve, p_reason }) => {
      requireRole("owner", "manager", "supervisor"); const g = byId("reservation_guests", p_guest_id); if (!g) throw new Error("GUEST_NOT_FOUND");
      const r = res(g.reservation_id); requireBranch(r.branch_id); if (!g.data_submitted) throw new Error("GUEST_DATA_NOT_SUBMITTED");
      if (!p_approve && !String(p_reason ?? "").trim()) throw new Error("REASON_REQUIRED");
      Object.assign(g, { verification_status: p_approve ? "verified" : "rejected", verified_by: p_approve ? staffId() : null, verified_at: p_approve ? nowISO() : null });
      if (p_approve) linkProfile(g);
      const st = rollup(r); emit("reservation_guests");
      audit(r.branch_id, p_approve ? "approve_identity" : "reject_identity", "reservation_guest", g.id, { reservation_id: r.id, reason: p_reason ?? null });
      return { ok: true, identity_status: st };
    },

    // ---- profiles, ratings, bans, holds (decisions 2, 21) ----
    fn_guest_profiles: ({ p }) => {
      requireRole("owner", "manager", "supervisor"); const q = String(p?.q ?? "").trim(); const filter = p?.filter || "all"; const limit = Math.min(Math.max(Number(p?.limit ?? 50), 1), 200); const offset = Math.max(Number(p?.offset ?? 0), 0);
      const digits = q.replace(/[٠-٩]/g, (x) => String("٠١٢٣٤٥٦٧٨٩".indexOf(x))).replace(/\D/g, "");
      const fps = /^[A-Za-z0-9]{5,15}$/.test(q) ? ["national_id", "passport", "gcc_id"].map((t) => fingerprint(t, q)) : [];
      const rows = T("guest_profiles").filter((gp) => gp.organization_id === ORG && profileVisible(gp)).filter((gp) => !q
        || String(gp.full_name).includes(q) || (digits.length >= 4 && String(gp.phone ?? "").replace(/\D/g, "").includes(digits)) || (digits.length === 4 && gp.identity_last4 === digits) || fps.includes(gp.identity_fingerprint)
        || T("reservation_guests").some((g) => g.guest_profile_id === gp.id && (fps.includes(g.identity_fingerprint) || (digits.length === 4 && g.identity_number_last4 === digits)))
        || T("reservation_guests").some((g) => g.guest_profile_id === gp.id && [byId("reservations", g.reservation_id)?.internal_ref, byId("reservations", g.reservation_id)?.external_ref].some((x) => String(x ?? "").toLowerCase() === q.toLowerCase())))
        .map((gp) => { const ban = profileBan(gp); return { id: gp.id, full_name: gp.full_name, phone_masked: maskPhone(gp.phone), nationality: gp.nationality, identity_type: gp.identity_type ?? null, identity_last4: gp.identity_last4 ?? null, rating: gp.rating ?? null, rating_note: gp.rating_note ?? null, stays: staysOf(gp.id), last_check_in: lastCheckIn(gp.id), banned: !!ban, ban_reason: ban?.reason ?? null, duplicates: duplicatesOf(gp).length, created_at: gp.created_at }; })
        .filter((x) => filter === "all" || (filter === "banned" && x.banned) || (filter === "duplicates" && x.duplicates > 0) || (filter === "rated" && x.rating != null) || (filter === "low" && x.rating != null && x.rating <= 2))
        .sort((a, b) => (a.last_check_in === b.last_check_in ? (a.created_at < b.created_at ? 1 : -1) : (a.last_check_in ?? "") < (b.last_check_in ?? "") ? 1 : -1));
      return { total: rows.length, rows: rows.slice(offset, offset + limit) };
    },
    fn_guest_profile: ({ p_id }) => {
      requireRole("owner", "manager", "supervisor"); const gp = byId("guest_profiles", p_id); if (!gp || !profileVisible(gp)) throw new Error("NOT_FOUND"); const ban = profileBan(gp);
      return { profile: { id: gp.id, full_name: gp.full_name, phone: gp.phone, nationality: gp.nationality, email: gp.email, identity_type: gp.identity_type ?? null, identity_last4: gp.identity_last4 ?? null, rating: gp.rating ?? null, rating_note: gp.rating_note ?? null, rated_at: gp.rated_at ?? null, rated_by: staffName(gp.rated_by), created_at: gp.created_at },
        ban: ban ? { id: ban.id, reason: ban.reason, since: ban.created_at, own: ban.guest_profile_id === gp.id, by: staffName(ban.created_by) } : null,
        ban_history: T("guest_bans").filter((b) => b.guest_profile_id === gp.id).sort((a, b) => (a.created_at < b.created_at ? 1 : -1)).map((b) => ({ id: b.id, reason: b.reason, since: b.created_at, by: staffName(b.created_by), lifted_at: b.lifted_at, lifted_by: staffName(b.lifted_by), lift_reason: b.lift_reason })),
        stays: T("reservation_guests").filter((g) => g.guest_profile_id === gp.id).map((g) => ({ g, r: byId("reservations", g.reservation_id)! })).filter(({ r }) => r && (hasRole("owner") || myBranches().includes(r.branch_id)))
          .sort((a, b) => (a.r.check_in < b.r.check_in ? 1 : -1)).map(({ g, r }) => ({ reservation_id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref, status: r.status, check_in: r.check_in, check_out: r.check_out, branch_name: byId("branches", r.branch_id)?.name_ar ?? null, is_primary: g.is_primary, room_number: roomNo(r.room_id), category_name: byId("room_categories", r.room_category_id)?.name_ar ?? null, source_name: byId("booking_sources", r.source_id)?.name ?? null })),
        duplicates: duplicatesOf(gp), can_ban: hasRole("owner", "manager") };
    },
    fn_guest_rate: ({ p }) => {
      requireRole("owner", "manager", "supervisor"); const rating = p.rating == null || p.rating === "" ? null : Number(p.rating);
      if (rating != null && (!Number.isInteger(rating) || rating < 1 || rating > 5)) throw new Error("VALIDATION: rating");
      const note = String(p.note ?? "").trim() || null; if (note && note.length > 500) throw new Error("VALIDATION: note");
      const gp = byId("guest_profiles", p.profile_id); if (!gp || !profileVisible(gp)) throw new Error("NOT_FOUND");
      const before = { rating: gp.rating ?? null, note: gp.rating_note ?? null };
      Object.assign(gp, { rating, rating_note: note, rated_by: staffId(), rated_at: nowISO(), updated_at: nowISO() }); emit("guest_profiles");
      audit(null, "guest.rated", "guest_profile", gp.id, { before, after: { rating, note } });
      return { ok: true, rating };
    },
    fn_guest_ban: ({ p }) => {
      requireRole("owner", "manager"); const ban = p.ban; if (ban == null) throw new Error("VALIDATION: ban"); const reason = String(p.reason ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason");
      let b: Row | undefined; let gp: Row | undefined;
      if (!ban && p.ban_id) { b = T("guest_bans").find((x) => x.id === p.ban_id && !x.lifted_at); if (!b) throw new Error("NOT_FOUND"); gp = byId("guest_profiles", b.guest_profile_id); }
      else { gp = byId("guest_profiles", p.profile_id); if (!gp || !profileVisible(gp)) throw new Error("NOT_FOUND"); }
      const pid = gp?.id ?? b?.guest_profile_id;
      const latest = T("reservation_guests").filter((g) => g.guest_profile_id === pid).map((g) => byId("reservations", g.reservation_id)!).filter(Boolean).sort((x, y) => (x.check_in < y.check_in ? 1 : -1))[0];
      const branch = latest?.branch_id ?? myBranches()[0] ?? null;
      if (ban) {
        if (T("guest_bans").some((x) => x.guest_profile_id === gp!.id && !x.lifted_at)) return { ok: true, duplicate: true };
        const phones = [...new Set([normPhone(gp!.phone), ...T("reservation_guests").filter((g) => g.guest_profile_id === gp!.id).map((g) => normPhone(g.phone))].filter(Boolean))] as string[];
        const fps = [...new Set([gp!.identity_fingerprint, ...T("reservation_guests").filter((g) => g.guest_profile_id === gp!.id).map((g) => g.identity_fingerprint)].filter(Boolean))] as string[];
        b = { id: uid(), organization_id: ORG, guest_profile_id: gp!.id, name_snapshot: gp!.full_name, phones, fingerprints: fps, reason, created_by: staffId(), created_at: nowISO(), lifted_at: null, lifted_by: null, lift_reason: null };
        T("guest_bans").push(b); emit("guest_bans"); emit("reservations");
        audit(branch, "guest.banned", "guest_profile", gp!.id, { after: { ban_id: b.id, phones: phones.length, documents: fps.length }, reason });
        if (branch) addReview(branch, "guest_banned", "guest_profile", gp!.id, null, `حظر الضيف ${gp!.full_name}`, reason, { ban_id: b.id });
      } else {
        if (!b) { b = T("guest_bans").find((x) => x.guest_profile_id === gp!.id && !x.lifted_at); if (!b) throw new Error("NOT_FOUND"); }
        Object.assign(b, { lifted_at: nowISO(), lifted_by: staffId(), lift_reason: reason }); emit("guest_bans"); emit("reservations");
        audit(branch, "guest.unbanned", "guest_profile", pid ?? b.id, { before: { ban_id: b.id, reason: b.reason }, reason });
        if (branch) addReview(branch, "guest_unbanned", "guest_profile", pid ?? b.id, null, `رفع الحظر عن الضيف ${b.name_snapshot}`, reason, { ban_id: b.id, banned_since: b.created_at });
      }
      return { ok: true, duplicate: false, ban_id: b.id };
    },
    fn_staff_set_hold: ({ p }) => {
      const hold = p.hold; if (hold == null) throw new Error("VALIDATION: hold"); if (hold) requireRole("owner", "manager", "supervisor"); else requireRole("owner", "manager");
      const reason = String(p.reason ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason");
      const r = res(p.reservation_id); requireBranch(r.branch_id); if (!!r.security_hold === !!hold) return { ok: true, duplicate: true };
      const before = { security_hold: !!r.security_hold, reason: r.security_hold_reason ?? null };
      Object.assign(r, { security_hold: !!hold, security_hold_reason: hold ? reason : null, security_hold_by: hold ? staffId() : null, security_hold_at: hold ? nowISO() : null, version: r.version + 1, updated_at: nowISO() }); emit("reservations");
      audit(r.branch_id, hold ? "reservation.hold_set" : "reservation.hold_lifted", "reservation", r.id, { before, after: { security_hold: !!hold }, reason });
      if (hold) addReview(r.branch_id, "security_hold", "reservation", r.id, r.id, `حظر على الحجز ${r.internal_ref}`, reason, {});
      return { ok: true, duplicate: false, security_hold: !!hold };
    },
    fn_reservation_ban_matches: ({ p_reservation }) => banMatches(p_reservation),
    fn_reservation_flags: ({ p_branch }) => {
      requireRole("owner", "manager", "supervisor", "finance"); requireBranch(p_branch); const out: Row = {};
      for (const r of T("reservations").filter((x) => x.branch_id === p_branch && ["draft", "pending_verification", "confirmed", "checked_in"].includes(x.status))) {
        const ban = banMatches(r.id).length > 0; const pg = primary(r.id); const rating = pg?.guest_profile_id ? byId("guest_profiles", pg.guest_profile_id)?.rating ?? null : null;
        if (ban || r.security_hold || rating != null) out[r.id] = { ban, hold: !!r.security_hold, rating };
      }
      return out;
    },

    // ---- platforms (decision 4) ----
    fn_platform_check_list: ({ p_branch, p_date }) => {
      requireRole("owner", "manager", "supervisor"); requireBranch(p_branch); const d = p_date || branchToday(p_branch); const d1 = new Date(d + "T00:00:00Z"); d1.setUTCDate(d1.getUTCDate() + 1); const next = d1.toISOString().slice(0, 10);
      const rows = T("reservations").filter((r) => r.branch_id === p_branch && r.check_in >= d && r.check_in <= next && !["draft", "rejected"].includes(r.status) && byId("booking_sources", r.source_id)?.kind === "external")
        .map((r) => { const s = byId("booking_sources", r.source_id)!; return { id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref, source_name: s.name, source_code: s.code, status: r.status, check_in: r.check_in, check_out: r.check_out, nights: Math.round((Date.parse(r.check_out) - Date.parse(r.check_in)) / 86400000), guests: r.adults + r.companions, guest_name: primary(r.id)?.full_name ?? null, group_ref: r.group_ref, platform_collects: r.platform_collects ?? null, platform_booked_on: r.platform_booked_on ?? null, total_halalas: r.total_halalas, paid_halalas: r.paid_halalas, cancel_reference: r.cancel_reference ?? null, verified_at: r.platform_verified_at ?? null, verified_by: staffName(r.platform_verified_by) }; })
        .sort((a, b) => a.check_in.localeCompare(b.check_in) || a.source_name.localeCompare(b.source_name) || String(a.external_ref).localeCompare(String(b.external_ref)));
      return { date: d, rows };
    },
    fn_platform_mark_checked: ({ p }) => {
      requireRole("owner", "manager", "supervisor"); const r = res(p.reservation_id); requireBranch(r.branch_id); const checked = p.checked !== false;
      if (byId("booking_sources", r.source_id)?.kind !== "external") throw new Error("VALIDATION: not_platform");
      const units = T("reservations").filter((x) => x.id === r.id || (r.group_ref && x.group_ref === r.group_ref));
      for (const x of units) Object.assign(x, { platform_verified_at: checked ? nowISO() : null, platform_verified_by: checked ? staffId() : null, updated_at: nowISO() });
      emit("reservations"); audit(r.branch_id, checked ? "reservation.platform_checked" : "reservation.platform_unchecked", "reservation", r.id, { after: { units: units.length, external_ref: r.external_ref } });
      return { ok: true, units: units.length };
    },
    // decision 36 (0040): by the staff member who entered the booking and by source (p_filters), the filters echoed back
    fn_reports_late_entries: ({ p_branch, p_from, p_to, p_min_days, p_filters }) => {
      requireRole("owner", "manager"); requireBranch(p_branch); if (!p_from || !p_to || p_to < p_from || Math.round((Date.parse(p_to) - Date.parse(p_from)) / 86400000) > 366) throw new Error("VALIDATION: period"); const min = Math.max(Number(p_min_days ?? 1), 0);
      const f = p_filters ?? {}; const fStaff: string | null = f.staff_id || null, fSource: string | null = f.source_id || null; const filters: Row = {}; if (fStaff) filters.staff_id = fStaff; if (fSource) filters.source_id = fSource;
      const all = T("reservations").filter((r) => r.branch_id === p_branch && r.platform_booked_on && byId("booking_sources", r.source_id)?.kind === "external" && (!fStaff || r.created_by === fStaff) && (!fSource || r.source_id === fSource)).map((r) => { const entered = localDay(r.created_at); return { r, entered, lag: Math.round((Date.parse(entered) - Date.parse(r.platform_booked_on)) / 86400000) }; }).filter((x) => x.entered >= p_from && x.entered <= p_to);
      const late = all.filter((x) => x.lag >= min);
      const by = new Map<string, { count: number; max: number }>(); for (const x of late) { const k = staffName(x.r.created_by) ?? "—"; const cur = by.get(k) ?? { count: 0, max: 0 }; cur.count++; cur.max = Math.max(cur.max, x.lag); by.set(k, cur); }
      return { filters, platform_bookings: all.length, late: late.length, after_arrival: late.filter((x) => x.entered > x.r.check_in).length,
        by_staff: [...by.entries()].map(([staff, v]) => ({ staff, count: v.count, max_lag: v.max })).sort((a, b) => b.count - a.count),
        rows: late.sort((a, b) => b.lag - a.lag).map((x) => ({ id: x.r.id, internal_ref: x.r.internal_ref, external_ref: x.r.external_ref, source_name: byId("booking_sources", x.r.source_id)?.name ?? null, booked_on: x.r.platform_booked_on, entered_on: x.entered, entered_at: x.r.created_at, lag_days: x.lag, check_in: x.r.check_in, after_arrival: x.entered > x.r.check_in, status: x.r.status, created_by: staffName(x.r.created_by) })) };
    },
    // decision 36 (0040): by the staff member who verified (p_filters.staff_id); the filters echoed back with the path
    fn_reports_identities: ({ p_branch, p_from, p_to, p_path, p_filters }) => {
      requireRole("owner"); requireBranch(p_branch); if (!p_from || !p_to || p_to < p_from || Math.round((Date.parse(p_to) - Date.parse(p_from)) / 86400000) > 366) throw new Error("VALIDATION: period"); const path = p_path || "office"; if (!["office", "guest", "all"].includes(path)) throw new Error("VALIDATION: path");
      const fStaff: string | null = (p_filters ?? {}).staff_id || null; const filters: Row = { path }; if (fStaff) filters.staff_id = fStaff;
      const rows = T("reservation_guests").map((g) => ({ g, r: byId("reservations", g.reservation_id)! })).filter(({ g, r }) => r && r.branch_id === p_branch && g.verification_status === "verified" && g.verified_at && localDay(g.verified_at) >= p_from && localDay(g.verified_at) <= p_to && (path === "all" || (g.entry_path ?? "guest") === path) && (!fStaff || g.verified_by === fStaff))
        .sort((a, b) => (a.g.verified_at < b.g.verified_at ? 1 : -1)).map(({ g, r }) => ({ guest_id: g.id, reservation_id: r.id, internal_ref: r.internal_ref, full_name: g.full_name, is_primary: g.is_primary, identity_type: g.identity_type, identity_last4: g.identity_number_last4, entry_path: g.entry_path ?? null, entered_by: staffName(g.entered_by), entered_at: g.entered_at ?? null, verified_by: staffName(g.verified_by), verified_at: g.verified_at }));
      const by = new Map<string, { office: number; guest: number }>(); for (const x of rows) { const k = x.verified_by ?? "—"; const cur = by.get(k) ?? { office: 0, guest: 0 }; if (x.entry_path === "office") cur.office++; else cur.guest++; by.set(k, cur); }
      return { filters, count: rows.length, by_staff: [...by.entries()].map(([staff, v]) => ({ staff, ...v })).sort((a, b) => b.office + b.guest - (a.office + a.guest)), rows };
    },

    // ---- the group's page (decision 69) ----
    fn_reservation_group_summary: ({ p_reservation }) => {
      requireRole("owner", "manager", "supervisor", "finance", "housekeeping"); const r = res(p_reservation); if (!myBranches().includes(r.branch_id)) throw new Error("RESERVATION_NOT_FOUND"); if (!r.group_ref) return null;
      const m = hasRole("owner", "manager", "supervisor", "finance"); const units = T("reservations").filter((s) => s.group_ref === r.group_ref).sort((a, b) => a.internal_ref.localeCompare(b.internal_ref));
      const sum = (k: string) => units.reduce((a, s) => a + Number(s[k] ?? 0), 0);
      return { group_ref: r.group_ref, external_ref: r.external_ref, source_name: byId("booking_sources", r.source_id)?.name ?? null,
        units: units.map((s) => ({ id: s.id, internal_ref: s.internal_ref, status: s.status, check_in: s.check_in, check_out: s.check_out, adults: s.adults, companions: s.companions, room_number: roomNo(s.room_id), category_name: byId("room_categories", s.room_category_id)?.name_ar ?? null, total_halalas: m ? s.total_halalas : null, paid_halalas: m ? s.paid_halalas : null, balance_due_halalas: m ? s.balance_due_halalas : null, deposit_balance_halalas: m ? s.deposit_balance_halalas : null })),
        totals: m ? { units: units.length, active_units: units.filter((s) => !["cancelled", "rejected", "no_show"].includes(s.status)).length, total_halalas: sum("total_halalas"), paid_halalas: sum("paid_halalas"), balance_due_halalas: sum("balance_due_halalas"), deposit_balance_halalas: sum("deposit_balance_halalas") } : { units: units.length } };
    },

    // ---- «ملخص الإقامة» (decision 19) ----
    fn_stay_summary: ({ p_reservation }) => { requireRole("owner", "manager", "supervisor", "finance"); const r = res(p_reservation); requireBranch(r.branch_id); return { ...summaryOf(r), acknowledgements: ackList(r.id) }; },
    fn_staff_record_paper_ack: ({ p }) => {
      requireRole("owner", "manager", "supervisor"); const r = res(p.reservation_id); requireBranch(r.branch_id); if (["cancelled", "rejected", "no_show"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID");
      const out = recordAck(r, primary(r.id)?.id ?? null, "paper", String(p.text_hash ?? ""), staffId());
      if (!out.duplicate) audit(r.branch_id, "reservation.summary_signed", "reservation", r.id, { after: { method: "paper", text_hash: p.text_hash } });
      return out;
    },
    fn_guest_stay_summary: ({ p_token }) => {
      const r = tokenRes(p_token); const s = summaryOf(r); const a = T("stay_acknowledgements").filter((x) => x.reservation_id === r.id).sort((x, y) => (x.accepted_at < y.accepted_at ? 1 : -1))[0];
      return { language: s.language, text: s.text, hash: s.hash, policies: s.policies, money: s.money, reservation: s.reservation, branch: s.branch, accepted_at: a?.accepted_at ?? null, method: a?.method ?? null, current: !!a && a.text_hash === s.hash };
    },
    fn_guest_acknowledge: ({ p_token, p_hash }) => {
      const r = tokenRes(p_token); if (["cancelled", "rejected", "no_show", "closed"].includes(r.status)) throw new Error("RESERVATION_NOT_EDITABLE");
      const out = recordAck(r, primary(r.id)?.id ?? null, "electronic", String(p_hash ?? ""), null);
      if (!out.duplicate) audit(r.branch_id, "guest_summary_accepted", "reservation", r.id, { text_hash: p_hash });
      return out;
    },

    // ---- the branch's media and public card (decision 31) ----
    fn_admin_set_branch_media: ({ p }) => {
      requireRole("owner", "manager"); requireBranch(p.branch_id); const kind = p.kind; if (!["logo", "image"].includes(kind)) throw new Error("VALIDATION: kind");
      const raw = String(p.data_base64 ?? "").replace(/^data:[^,]*,/, ""); const cur = T("branch_media").find((m) => m.branch_id === p.branch_id && m.kind === kind);
      const before = cur?.data_url ? { mime: cur.mime, size_bytes: cur.size_bytes, sha256: cur.sha256 } : null;
      if (!raw) { if (!cur) return { ok: true, changed: false }; Object.assign(cur, { mime: null, data_url: null, size_bytes: 0, sha256: null, updated_at: nowISO(), updated_by: staffId() }); emit("branch_media"); audit(p.branch_id, `branch.${kind}_changed`, "branch", p.branch_id, { before, after: null }); return { ok: true, changed: true, media: null }; }
      let bytes: Uint8Array; try { bytes = b64ToBytes(raw); } catch { throw new Error("VALIDATION: image"); }
      if (bytes.length > (kind === "logo" ? 204800 : 1048576)) throw new Error("VALIDATION: image_too_large");
      const mime = sniffImage(bytes); if (!mime) throw new Error("VALIDATION: image_type");
      const sha = textHash(raw); const after = { mime, size_bytes: bytes.length, sha256: sha };
      if (cur) Object.assign(cur, { ...after, data_url: `data:${mime};base64,${raw.replace(/\s/g, "")}`, updated_at: nowISO(), updated_by: staffId() });
      else T("branch_media").push({ branch_id: p.branch_id, kind, ...after, data_url: `data:${mime};base64,${raw.replace(/\s/g, "")}`, updated_at: nowISO(), updated_by: staffId() });
      emit("branch_media"); audit(p.branch_id, `branch.${kind}_changed`, "branch", p.branch_id, { before, after });
      return { ok: true, changed: true, media: after };
    },
    fn_branch_media: ({ p_branch, p_kind }) => { const b = byId("branches", p_branch); if (!b || !(b.is_active || myBranches().includes(b.id))) return null; return T("branch_media").find((m) => m.branch_id === p_branch && m.kind === p_kind)?.data_url ?? null; },
    fn_public_branch: ({ p_branch }) => {
      const b = byId("branches", p_branch); if (!b || !(b.is_active || myBranches().includes(b.id))) return null; const ver = (k: string) => { const m = T("branch_media").find((x) => x.branch_id === b.id && x.kind === k && x.data_url); return m ? String(m.sha256).slice(0, 12) : null; };
      return { id: b.id, name_ar: b.name_ar, name_en: b.name_en, city: b.city, address: b.address, phone: b.phone, map_url: b.map_url ?? null, booking_platform_url: b.booking_platform_url ?? null, default_language: b.default_language ?? "ar", country_code: b.country_code ?? "SA", check_in_time: String(b.check_in_time ?? "16:00").slice(0, 5), check_out_time: String(b.check_out_time ?? "12:00").slice(0, 5), logo_version: ver("logo"), image_version: ver("image") };
    },
    fn_admin_branch_media_info: ({ p_branch }) => { requireRole("owner", "manager"); requireBranch(p_branch); const out: Row = {}; for (const m of T("branch_media").filter((x) => x.branch_id === p_branch && x.data_url)) out[m.kind] = { mime: m.mime, size_bytes: m.size_bytes, updated_at: m.updated_at, updated_by: staffName(m.updated_by) }; return out; },
    fn_admin_set_source_active: ({ p }) => {
      requireRole("owner", "manager"); if (p.is_active == null) throw new Error("VALIDATION: is_active"); const s = byId("booking_sources", p.id); if (!s) throw new Error("NOT_FOUND");
      if (!!s.is_active === !!p.is_active) return { ok: true, changed: false };
      const was = !!s.is_active; s.is_active = !!p.is_active; emit("booking_sources");
      audit(null, s.is_active ? "source.enabled" : "source.disabled", "booking_source", s.id, { before: { code: s.code, is_active: was }, after: { code: s.code, is_active: s.is_active }, reason: String(p.reason ?? "").trim() || null });
      return { ok: true, changed: true };
    },
  };
}

/** What the server adds to fn_reservation_detail in phase 5 (bans, the profile's rating, the hold, the platform fields, the acknowledgements). */
export function detailExtras(c: GuestCtx, rpcs: Record<string, (a: any) => any>, r: Row) {
  const { T, byId, hasRole, staffName } = c;
  const staffy = hasRole("owner", "manager", "supervisor"); const money = hasRole("owner", "manager", "supervisor", "finance");
  const pg = T("reservation_guests").find((g) => g.reservation_id === r.id && g.is_primary); const gp = pg?.guest_profile_id ? byId("guest_profiles", pg.guest_profile_id) : undefined;
  const src = byId("booking_sources", r.source_id);
  return {
    bans: staffy ? rpcs.fn_reservation_ban_matches({ p_reservation: r.id }) : null,
    guest_profile: staffy && gp ? { id: gp.id, rating: gp.rating ?? null, rating_note: gp.rating_note ?? null, rated_at: gp.rated_at ?? null, rated_by: staffName(gp.rated_by), stays: new Set(T("reservation_guests").filter((g) => g.guest_profile_id === gp.id).map((g) => g.reservation_id)).size } : null,
    hold: r.security_hold ? { reason: r.security_hold_reason, at: r.security_hold_at ?? null, by: staffName(r.security_hold_by) } : null,
    platform: src?.kind === "external" ? { booked_on: r.platform_booked_on ?? null, collects: money ? r.platform_collects ?? null : null, verified_at: r.platform_verified_at ?? null, verified_by: staffName(r.platform_verified_by), cancel_reference: r.cancel_reference ?? null } : null,
    acknowledgements: money ? T("stay_acknowledgements").filter((a) => a.reservation_id === r.id).sort((a, b) => (a.accepted_at < b.accepted_at ? 1 : -1)).map((a) => ({ id: a.id, method: a.method, language: a.language, accepted_at: a.accepted_at, text_hash: a.text_hash, recorded_by: staffName(a.recorded_by) })) : null,
  };
}
