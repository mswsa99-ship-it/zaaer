/**
 * 0054 (MONEY-07): the organisation's own name for printed documents, read from the server once per session
 * (fn_organization_info) instead of a name written in the code. The owner's «المنشأة» settings screen (Phase 2)
 * edits the same record.
 */
import { supabase } from "./supabase";

export interface OrganizationInfo { name_ar: string; name_en: string | null; license_number: string | null }
let cached: OrganizationInfo | null = null;
let inflight: Promise<OrganizationInfo | null> | null = null;

/** The name already loaded (null until loadOrganization() has answered). */
export function organizationName(): string | null { return cached?.name_ar ?? null; }

/** Loads the organisation once; a failure leaves the name unknown (the document then shows the branch only). */
export function loadOrganization(): Promise<OrganizationInfo | null> {
  if (cached) return Promise.resolve(cached);
  inflight ??= Promise.resolve(supabase.rpc("fn_organization_info", {})).then(({ data, error }) => {
    inflight = null;
    if (error || !data) return null;
    cached = data as OrganizationInfo;
    return cached;
  }, () => { inflight = null; return null; });
  return inflight;
}
