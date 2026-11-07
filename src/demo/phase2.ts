/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0056 (Phase 2b of the 31 October review): the branch's guide (arrival instructions and the
 * bank details guests see), its gallery and entry videos, the booking sources added from the settings, and the branch's
 * payment provider settings. The same rules, argument names and return shapes as the SQL functions.
 */
import { uid, nowISO, ORG, type Row } from "./data";
import { latinDigits } from "../lib/validation";
import { normalizeArabic } from "../../supabase/functions/_shared/guardrails";

export interface Phase2Ctx {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  myBranches: () => string[];
  requireCap: (code: string) => void;
  requireBranch: (b: string | null | undefined) => void;
  staffId: () => string | null;
  staffName: (id: string | null | undefined) => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string, details: Row) => void;
  emit: (table: string) => void;
  validHttpsUrl: (u: string) => boolean;
}

/** fn_valid_iban: SA, two check digits, 20 more; the ISO 13616 check (mod 97 = 1) */
export function validIban(p: string | null | undefined): boolean {
  const s = String(p ?? "").replace(/\s/g, "").toUpperCase();
  if (!/^SA\d{2}[0-9A-Z]{20}$/.test(s)) return false;
  const moved = s.slice(4) + s.slice(0, 4);
  let r = 0; for (const ch of moved) { const d = /\d/.test(ch) ? ch : String(ch.charCodeAt(0) - 55); for (const x of d) r = (r * 10 + Number(x)) % 97; }
  return r === 1;
}

const imageMime = (b64: string): string | null => {
  let bin = ""; try { bin = atob(b64); } catch { return null; }
  const b = (i: number) => bin.charCodeAt(i);
  return b(0) === 0x89 && bin.slice(1, 4) === "PNG" ? "image/png" : b(0) === 0xff && b(1) === 0xd8 && b(2) === 0xff ? "image/jpeg" : bin.slice(0, 4) === "RIFF" && bin.slice(8, 12) === "WEBP" ? "image/webp" : null;
};

export function phase2Rpcs(c: Phase2Ctx): Record<string, (a: any) => any> {
  const { T, byId, myBranches, requireCap, requireBranch, staffId, staffName, audit, emit, validHttpsUrl } = c;
  const items = () => (T("branch_media_items") as Row[]);
  const text = (v: unknown) => String(v ?? "").trim() || null;
  return {
    // ---- the branch's guide (SETUP-05)
    fn_admin_set_branch_guide: ({ p }) => {
      requireCap("branch.settings"); const q: Row = p ?? {}; requireBranch(q.branch_id); const b = byId("branches", q.branch_id); if (!b) throw new Error("NOT_FOUND");
      const before = { arrival_instructions: b.arrival_instructions ?? null, bank_name: b.bank_name ?? null, bank_beneficiary: b.bank_beneficiary ?? null, bank_iban: b.bank_iban ?? null };
      const next: Row = { ...before };
      if ("arrival_instructions" in q) { const v = text(q.arrival_instructions); if (v && v.length > 4000) throw new Error("VALIDATION: arrival_instructions"); next.arrival_instructions = v; }
      if ("bank_name" in q) { const v = text(q.bank_name); if (v && v.length > 80) throw new Error("VALIDATION: bank_name"); next.bank_name = v; }
      if ("bank_beneficiary" in q) { const v = text(q.bank_beneficiary); if (v && v.length > 120) throw new Error("VALIDATION: bank_beneficiary"); next.bank_beneficiary = v; }
      if ("bank_iban" in q) { const v = latinDigits(String(q.bank_iban ?? "")).replace(/\s/g, "").toUpperCase() || null; if (v && !validIban(v)) throw new Error("VALIDATION: iban");
        // A1 (0062): the IBAN ends with the last digits of the branch's bank account
        const acc = (T("cash_accounts") as Row[]).find((a) => a.branch_id === b.id && a.kind === "bank_account" && !a.archived_at);
        if (v && acc?.account_suffix && !v.endsWith(acc.account_suffix)) throw new Error("VALIDATION: iban_suffix");
        next.bank_iban = v; }
      if (next.bank_iban && (!next.bank_name || !next.bank_beneficiary)) throw new Error("VALIDATION: bank_details");
      Object.assign(b, next, { version: (b.version ?? 1) + 1, updated_at: nowISO() }); emit("branches");
      if (JSON.stringify(next) !== JSON.stringify(before)) audit(b.id, "branch.guide_changed", "branch", b.id, { before, after: next });
      return { ok: true };
    },
    fn_public_branch_guide: ({ p_branch }) => {
      const b = byId("branches", p_branch); if (!b || !(b.is_active !== false || myBranches().includes(b.id))) return null;
      const live = items().filter((m) => m.branch_id === b.id && !m.archived_at).sort((x, y) => x.sort_order - y.sort_order || String(x.created_at).localeCompare(String(y.created_at)));
      return {
        arrival_instructions: b.arrival_instructions ?? null,
        bank: b.bank_iban ? { bank_name: b.bank_name, beneficiary: b.bank_beneficiary, iban: b.bank_iban } : null,
        photos: live.filter((m) => m.kind === "photo" && !m.room_id).map((m) => ({ id: m.id, caption: m.caption ?? null, version: String(m.sha256 ?? "").slice(0, 12) })),
        videos: live.filter((m) => m.kind === "video").map((m) => ({ id: m.id, caption: m.caption ?? null, url: m.url, block_id: m.block_id ?? null, room_id: m.room_id ?? null })),
      };
    },
    fn_branch_photo: ({ p_id }) => { const m = items().find((x) => x.id === p_id && x.kind === "photo"); if (!m) return null; const b = byId("branches", m.branch_id);
      return (!m.archived_at && b?.is_active !== false) || myBranches().includes(m.branch_id) ? m.data_url ?? null : null; },
    fn_admin_media_items: ({ p_branch, p_archived }) => { requireCap("branch.settings"); requireBranch(p_branch);
      return items().filter((m) => m.branch_id === p_branch && (p_archived || !m.archived_at)).sort((x, y) => String(x.kind).localeCompare(String(y.kind)) || x.sort_order - y.sort_order)
        .map((m) => ({ id: m.id, kind: m.kind, caption: m.caption ?? null, url: m.url ?? null, size_bytes: m.size_bytes ?? 0, sort_order: m.sort_order, block_id: m.block_id ?? null, room_id: m.room_id ?? null, archived_at: m.archived_at ?? null, archive_reason: m.archive_reason ?? null, version: String(m.sha256 ?? m.url ?? "").slice(0, 12) })); },
    fn_admin_upsert_media_item: ({ p }) => {
      requireCap("branch.settings"); const q: Row = p ?? {}; let m: Row | undefined; let branch: string; let kind: string;
      if (q.id) { m = items().find((x) => x.id === q.id); if (!m) throw new Error("NOT_FOUND"); branch = m.branch_id; kind = m.kind; }
      else { branch = q.branch_id; kind = q.kind; if (!["photo", "video"].includes(kind)) throw new Error("VALIDATION: kind"); }
      requireBranch(branch);
      const caption = "caption" in q ? text(q.caption) : m?.caption ?? null; if (caption && caption.length > 160) throw new Error("VALIDATION: caption");
      if (q.block_id && byId("blocks", q.block_id)?.branch_id !== branch) throw new Error("BRANCH_MISMATCH: block");
      if (q.room_id && byId("rooms", q.room_id)?.branch_id !== branch) throw new Error("BRANCH_MISMATCH: room");
      if ("sort_order" in q && !/^[0-9]{1,4}$/.test(String(q.sort_order ?? ""))) throw new Error("VALIDATION: sort_order");
      const checkUrl = (u: string) => { if (!validHttpsUrl(u) || u.length > 500) throw new Error("VALIDATION: video_url"); return u; };
      if (!m) {
        let data_url: string | null = null, size = 0, sha: string | null = null, url: string | null = null;
        if (kind === "photo") { const raw = String(q.data_base64 ?? "").replace(/^data:[^,]*,/, "").replace(/\s/g, ""); if (!raw) throw new Error("VALIDATION: image"); size = Math.floor((raw.length * 3) / 4);
          if (size > 1048576) throw new Error("VALIDATION: image_too_large"); const mime = imageMime(raw); if (!mime) throw new Error("VALIDATION: image_type"); data_url = `data:${mime};base64,${raw}`; sha = `${raw.length.toString(16)}${raw.slice(-10)}`; }
        else url = checkUrl(String(q.url ?? "").trim());
        const order = q.sort_order != null ? Number(q.sort_order) : Math.max(0, ...items().filter((x) => x.branch_id === branch && x.kind === kind).map((x) => x.sort_order)) + 1;
        m = { id: uid(), organization_id: ORG, branch_id: branch, kind, block_id: q.block_id || null, room_id: q.room_id || null, caption, url, data_url, size_bytes: size, sha256: sha, sort_order: order, archived_at: null, archived_by: null, archive_reason: null, created_at: nowISO(), created_by: staffId(), updated_at: null };
        items().push(m); audit(branch, "branch.media_added", "branch_media_item", m.id, { after: { kind, caption, url, size_bytes: size, block_id: m.block_id, room_id: m.room_id } });
      } else {
        const before = { caption: m.caption, sort_order: m.sort_order, url: m.url, block_id: m.block_id, room_id: m.room_id };
        Object.assign(m, { caption, url: kind === "video" && "url" in q ? checkUrl(String(q.url ?? "").trim()) : m.url, sort_order: q.sort_order != null ? Number(q.sort_order) : m.sort_order,
          block_id: "block_id" in q ? q.block_id || null : m.block_id, room_id: "room_id" in q ? q.room_id || null : m.room_id, updated_at: nowISO() });
        audit(branch, "branch.media_changed", "branch_media_item", m.id, { before, after: { caption: m.caption, sort_order: m.sort_order, url: m.url, block_id: m.block_id, room_id: m.room_id } });
      }
      emit("branch_media_items"); return { ok: true, id: m.id };
    },
    fn_admin_archive_media_item: ({ p_id, p_reason, p_archive = true }) => {
      requireCap("branch.settings"); const m = items().find((x) => x.id === p_id); if (!m) throw new Error("NOT_FOUND"); requireBranch(m.branch_id);
      if (p_archive) { if (!String(p_reason ?? "").trim()) throw new Error("VALIDATION: reason"); Object.assign(m, { archived_at: nowISO(), archived_by: staffId(), archive_reason: String(p_reason).trim() }); }
      else Object.assign(m, { archived_at: null, archived_by: null, archive_reason: null });
      emit("branch_media_items"); audit(m.branch_id, p_archive ? "branch.media_archived" : "branch.media_restored", "branch_media_item", m.id, { after: { kind: m.kind, caption: m.caption }, reason: String(p_reason ?? "").trim() || null });
      return { ok: true };
    },

    // ---- the booking sources (SETUP-14)
    fn_admin_upsert_source: ({ p }) => {
      requireCap("definitions"); const q: Row = p ?? {}; const s = q.id ? byId("booking_sources", q.id) : undefined; if (q.id && !s) throw new Error("NOT_FOUND");
      const name = "name" in q || !s ? String(q.name ?? "").trim() : s.name; if (!name || name.length > 80) throw new Error("VALIDATION: name");
      if (T("booking_sources").some((x) => x.organization_id === ORG && !x.archived_at && x.id !== s?.id && normalizeArabic(String(x.name).trim()) === normalizeArabic(name))) throw new Error("DUPLICATE_SOURCE_NAME");
      const kind = String(q.kind || s?.kind || "external"); if (!["direct", "external"].includes(kind)) throw new Error("VALIDATION: source_kind");
      const ref = q.external_reference_required != null ? !!q.external_reference_required : s ? !!s.external_reference_required : kind === "external";
      if ("commission_bp" in q && !/^[0-9]{1,5}$/.test(String(q.commission_bp ?? ""))) throw new Error("VALIDATION: commission");
      let bp = Number(q.commission_bp ?? s?.commission_bp ?? 0); if (bp > 10000) throw new Error("VALIDATION: commission"); if (kind === "direct") bp = 0;
      if (!s) {
        const row: Row = { id: uid(), organization_id: ORG, name, code: "custom_" + Math.random().toString(16).slice(2, 12), kind, external_reference_required: ref, commission_bp: bp, is_active: true, archived_at: null, booking_url: null, created_at: nowISO() };
        T("booking_sources").push(row); emit("booking_sources"); audit(null, "source.created", "booking_source", row.id, { after: { name, code: row.code, kind, external_reference_required: ref, commission_bp: bp } }); return { ok: true, id: row.id, code: row.code };
      }
      if (kind !== s.kind && T("reservations").some((r) => r.source_id === s.id)) throw new Error("SOURCE_IN_USE: kind");
      const before = { name: s.name, kind: s.kind, external_reference_required: !!s.external_reference_required, commission_bp: s.commission_bp ?? 0 };
      Object.assign(s, { name, kind, external_reference_required: ref, commission_bp: bp }); emit("booking_sources");
      const after = { name, kind, external_reference_required: ref, commission_bp: bp };
      if (JSON.stringify(after) !== JSON.stringify(before)) audit(null, "source.updated", "booking_source", s.id, { before, after, reason: String(q.reason ?? "").trim() || null });
      return { ok: true, id: s.id, code: s.code };
    },

    // ---- the payment provider (SETUP-02): the secret kept, never shown again; online payment only when complete
    fn_admin_payment_settings: ({ p_branch }) => {
      requireCap("security"); requireBranch(p_branch); const s = T("branch_payment_settings").find((x) => x.branch_id === p_branch) ?? {};
      return { branch_id: p_branch, provider: s.provider ?? null, provider_label: s.provider_label ?? null, merchant_id: s.merchant_id ?? null, publishable_key: s.publishable_key ?? null,
        has_secret: !!s.secret, secret_last4: s.secret_last4 ?? null, pos_terminal_id: s.pos_terminal_id ?? null, online_enabled: !!s.online_enabled, updated_at: s.updated_at ?? null,
        updated_by: staffName(s.updated_by), complete: !!(s.provider && s.merchant_id && s.publishable_key && s.secret) };
    },
    fn_admin_save_payment_settings: ({ p }) => {
      requireCap("security"); const q: Row = p ?? {}; requireBranch(q.branch_id);
      let s = T("branch_payment_settings").find((x) => x.branch_id === q.branch_id); const fresh = !s; s ??= { branch_id: q.branch_id, organization_id: ORG, online_enabled: false };
      const next: Row = { ...s }; const changed: string[] = [];
      const set = (k: string, v: unknown) => { if (v !== (next[k] ?? null)) { next[k] = v; changed.push(k); } };
      if ("provider" in q) { const v = text(q.provider); if (v && !["moyasar", "tap", "hyperpay", "paytabs", "other"].includes(v)) throw new Error("VALIDATION: provider"); set("provider", v); }
      if ("provider_label" in q) { const v = text(q.provider_label); if (v && v.length > 60) throw new Error("VALIDATION: provider_label"); next.provider_label = v; }
      if (next.provider !== "other") next.provider_label = null;
      if ("merchant_id" in q) { const v = text(q.merchant_id); if (v && (v.length > 80 || !/^[A-Za-z0-9._:-]+$/.test(v))) throw new Error("VALIDATION: merchant_id"); set("merchant_id", v); }
      if ("publishable_key" in q) { const v = text(q.publishable_key); if (v && (v.length > 200 || /\s/.test(v))) throw new Error("VALIDATION: publishable_key"); set("publishable_key", v); }
      const secret = text(q.secret_key);
      if (secret) { if (secret.length < 8 || secret.length > 300 || /\s/.test(secret)) throw new Error("VALIDATION: secret_key"); next.secret = "•"; next.secret_last4 = secret.slice(-4); changed.push("secret_key"); }
      else if (q.clear_secret && next.secret) { next.secret = null; next.secret_last4 = null; changed.push("secret_key"); }
      if ("pos_terminal_id" in q) { const v = text(latinDigits(String(q.pos_terminal_id ?? ""))); if (v && (v.length > 40 || !/^[A-Za-z0-9-]+$/.test(v))) throw new Error("VALIDATION: pos_terminal_id"); set("pos_terminal_id", v); }
      const complete = () => !!(next.provider && next.merchant_id && next.publishable_key && next.secret);
      if ("online_enabled" in q) { if (q.online_enabled && !complete()) throw new Error("VALIDATION: payment_incomplete"); set("online_enabled", !!q.online_enabled); }
      if (next.online_enabled && !complete()) next.online_enabled = false;
      Object.assign(s, next, { updated_at: nowISO(), updated_by: staffId() }); if (fresh) T("branch_payment_settings").push(s); emit("branch_payment_settings");
      if (changed.length) audit(q.branch_id, "payment_settings.updated", "branch", q.branch_id, { after: { changed, provider: s.provider ?? null, secret_last4: s.secret_last4 ?? null, online_enabled: !!s.online_enabled } });
      return { ok: true, changed };
    },
  };
}
