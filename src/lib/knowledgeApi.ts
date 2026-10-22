/**
 * Knowledge base (migration 0010): the records the reception assistant answers from.
 * Reads go through RLS (staff of the organization); writes only through the audited RPCs.
 */
import { supabase } from "./supabase";

export interface KnowledgeRow {
  id: string;
  branch_id: string | null;
  category: KnowledgeCategory;
  question: string;
  keywords: string[];
  answer: string;
  answer_en: string | null;
  is_public: boolean;
  is_active: boolean;
  priority: number;
  used_count: number;
  last_used_at: string | null;
  version: number;
  archived_at: string | null;
  archive_reason: string | null;
  updated_at: string;
}

export interface UnansweredRow {
  id: string;
  branch_id: string | null;
  question: string;
  asked_count: number;
  first_asked_at: string;
  last_asked_at: string;
  status: "open" | "answered" | "ignored";
  knowledge_entry_id: string | null;
}

export type KnowledgeCategory = "general" | "stay" | "services" | "location" | "payment" | "policies" | "facilities" | "other";
export const KNOWLEDGE_CATEGORY_LABELS: Record<KnowledgeCategory, string> = {
  general: "عام", stay: "الإقامة", services: "الخدمات", location: "الموقع والمحيط", payment: "الدفع", policies: "السياسات", facilities: "المرافق", other: "أخرى",
};

export interface KnowledgeDraft {
  id?: string;
  version?: number;
  branch_id: string | null;          // null = every branch of the organization
  category: KnowledgeCategory;
  question: string;
  keywords: string[];
  answer: string;
  answer_en?: string | null;
  is_public: boolean;
  is_active: boolean;
  priority: number;
  reason?: string;
  unanswered_id?: string | null;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export const knowledgeApi = {
  list: async (branchId: string, includeArchived = false) => {
    let q = supabase.from("knowledge_entries")
      .select("id, branch_id, category, question, keywords, answer, answer_en, is_public, is_active, priority, used_count, last_used_at, version, archived_at, archive_reason, updated_at")
      .or(`branch_id.eq.${branchId},branch_id.is.null`)
      .order("priority", { ascending: false }).order("used_count", { ascending: false }).order("updated_at", { ascending: false });
    if (!includeArchived) q = q.is("archived_at", null);
    const { data, error } = await q;
    if (error) throw error;
    return (data as KnowledgeRow[]) ?? [];
  },
  unanswered: async (branchId: string, status: "open" | "answered" | "ignored" | "all" = "open") => {
    let q = supabase.from("unanswered_questions")
      .select("id, branch_id, question, asked_count, first_asked_at, last_asked_at, status, knowledge_entry_id")
      .or(`branch_id.eq.${branchId},branch_id.is.null`)
      .order("asked_count", { ascending: false }).order("last_asked_at", { ascending: false });
    if (status !== "all") q = q.eq("status", status);
    const { data, error } = await q;
    if (error) throw error;
    return (data as UnansweredRow[]) ?? [];
  },
  upsert: (d: KnowledgeDraft) => rpc<{ ok: boolean; id: string; version: number }>("fn_admin_upsert_knowledge", { p: d }),
  archive: (id: string, reason: string, archive = true) => rpc<{ ok: boolean }>("fn_admin_archive_knowledge", { p_id: id, p_reason: reason, p_archive: archive }),
  resolveUnanswered: (id: string, status: "open" | "ignored", note?: string) => rpc<{ ok: boolean }>("fn_admin_resolve_unanswered", { p_id: id, p_status: status, p_note: note ?? null }),
};

/** Suggests keywords from a question: content words only (no stop words / question words). */
export function suggestKeywords(question: string): string[] {
  const stop = new Set(["هل", "ما", "ماذا", "من", "في", "فيه", "على", "عن", "كيف", "متى", "أين", "وين", "يوجد", "توجد", "عندكم", "لديكم", "ممكن", "أبي", "أبغى", "أريد", "هو", "هي", "إلى", "أو", "كم", "هناك", "تقدمون", "توفرون", "يتوفر", "تتوفر", "لو", "سمحت", "is", "are", "there", "do", "you", "have", "the", "a", "an", "any", "can", "i", "we", "of", "to", "in", "at", "for", "what", "where", "when", "how"]);
  return [...new Set(question.split(/[^\p{L}\p{N}]+/u).map((w) => w.replace(/^(ال|وال|بال|لل)/, "")).filter((w) => w.length >= 3 && !stop.has(w)))].slice(0, 6);
}
