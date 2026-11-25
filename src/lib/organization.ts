/** Hotel identity is cached per address and guest/staff context, never across hotels. */
import { useLocation } from "react-router-dom";
import { useEffect, useState } from "react";
import { currentGuestScope, guestScopeKey } from "./guestScope";
import { supabase } from "./supabase";

export interface OrganizationInfo { name_ar: string; name_en: string | null; logo: string | null; license_number?: string | null }
interface Entry { value: OrganizationInfo | null; fresh: boolean; inflight: Promise<OrganizationInfo | null> | null }
const entries = new Map<string, Entry>();
const listeners = new Set<() => void>();
function scopeKey(): string { return `${currentGuestScope().guest ? "guest" : "staff"}:${guestScopeKey()}`; }
function storageKey(key: string): string { return "zaaer_org_name_v1:" + key; }
function entry(key = scopeKey()): Entry {
  let e = entries.get(key);
  if (e) return e;
  let value: OrganizationInfo | null = null;
  try {
    const raw = localStorage.getItem(storageKey(key));
    const v = raw ? JSON.parse(raw) : null;
    if (v && typeof v.name_ar === "string") value = { name_ar: v.name_ar, name_en: v.name_en ?? null, logo: null };
  } catch { /* storage unavailable */ }
  e = { value, fresh: false, inflight: null }; entries.set(key, e); return e;
}
export function organizationName(): string | null { return entry().value?.name_ar ?? null; }
export function loadOrganization(force = false): Promise<OrganizationInfo | null> {
  const key = scopeKey(), e = entry(key);
  if (e.fresh && !force) return Promise.resolve(e.value);
  e.inflight ??= Promise.resolve(supabase.rpc("fn_public_organization", {})).then(({ data, error }) => {
    e.inflight = null;
    if (error) return e.value;
    e.value = data as OrganizationInfo | null; e.fresh = true;
    try {
      if (e.value) localStorage.setItem(storageKey(key), JSON.stringify({ name_ar: e.value.name_ar, name_en: e.value.name_en }));
      else localStorage.removeItem(storageKey(key));
    } catch { /* storage unavailable */ }
    if (scopeKey() === key) for (const l of listeners) l();
    return e.value;
  }, () => { e.inflight = null; return e.value; });
  return e.inflight;
}
export function refreshOrganization(): Promise<OrganizationInfo | null> { entry().fresh = false; return loadOrganization(true); }
export function useOrganization(): OrganizationInfo | null {
  const { pathname } = useLocation();
  const key = scopeKey();
  const [state, setState] = useState(() => ({ key, value: entry(key).value }));
  useEffect(() => {
    const update = () => { if (scopeKey() === key) setState({ key, value: entry(key).value }); };
    listeners.add(update); update(); void loadOrganization(true);
    return () => { listeners.delete(update); };
  }, [pathname, key]);
  return state.key === key ? state.value : entry(key).value;
}
export function useOrganizationName(): string { return useOrganization()?.name_ar ?? ""; }
