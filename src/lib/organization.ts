/**
 * The organisation's own name and logo (0055, SETUP-04): read from the server once per session — fn_public_organization,
 * open to the guest pages too — and never written in the code. The owner edits them in «المنشأة»; after a save every
 * screen updates at once. The last known name is kept in this browser so a reload shows it straight away.
 */
import { useEffect, useState } from "react";
import { supabase } from "./supabase";

export interface OrganizationInfo { name_ar: string; name_en: string | null; logo: string | null; license_number?: string | null }
const STORE_KEY = "zaaer_org_name_v1";

function readStored(): OrganizationInfo | null {
  try { const raw = localStorage.getItem(STORE_KEY); if (!raw) return null; const v = JSON.parse(raw); return v && typeof v.name_ar === "string" ? { name_ar: v.name_ar, name_en: v.name_en ?? null, logo: null } : null; }
  catch { return null; }
}
function store(o: OrganizationInfo | null) {
  try { if (o) localStorage.setItem(STORE_KEY, JSON.stringify({ name_ar: o.name_ar, name_en: o.name_en })); } catch { /* storage blocked */ }
}

let cached: OrganizationInfo | null = readStored();
let fresh = false;
let inflight: Promise<OrganizationInfo | null> | null = null;
const listeners = new Set<(o: OrganizationInfo | null) => void>();

/** The name already loaded (null until loadOrganization() has answered and nothing was kept from before). */
export function organizationName(): string | null { return cached?.name_ar ?? null; }

/** Loads the organisation once; a failure keeps what is known (the document then shows the branch only). */
export function loadOrganization(force = false): Promise<OrganizationInfo | null> {
  if (fresh && !force) return Promise.resolve(cached);
  inflight ??= Promise.resolve(supabase.rpc("fn_public_organization", {})).then(({ data, error }) => {
    inflight = null;
    if (error || !data) return cached;
    cached = data as OrganizationInfo; fresh = true; store(cached);
    for (const l of listeners) l(cached);
    return cached;
  }, () => { inflight = null; return cached; });
  return inflight;
}

/** After the owner saves «المنشأة»: every screen reads the new name and logo. */
export function refreshOrganization(): Promise<OrganizationInfo | null> { fresh = false; return loadOrganization(true); }

/** The organisation for a layout or a page; null while the first load is still on its way and nothing was kept. */
export function useOrganization(): OrganizationInfo | null {
  const [org, setOrg] = useState<OrganizationInfo | null>(cached);
  useEffect(() => {
    listeners.add(setOrg);
    void loadOrganization();
    return () => { listeners.delete(setOrg); };
  }, []);
  return org;
}

/** The Arabic name to show, or an empty string while it loads (never a name written in the code). */
export function useOrganizationName(): string {
  return useOrganization()?.name_ar ?? "";
}
