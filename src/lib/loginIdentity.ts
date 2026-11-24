import type { SupabaseClient } from "@supabase/supabase-js";
import type { StaffProfile } from "./auth";
import { defaultPermissions, type Permissions } from "./permissionCatalog";

export const PROFILE_LOAD_ERROR = "تعذّر التحقق من صلاحيات الحساب. أعد المحاولة، ولم يتم فتح أي صفحة.";

/** Missing is a successful empty lookup, never a transport/permission error. */
export async function readLoginIdentity(client: SupabaseClient, uid: string): Promise<{ operator: boolean; profile: StaffProfile | null; permissions: Permissions }> {
  const operator = await client.rpc("fn_platform_operator_id");
  if (operator.error) throw new Error(PROFILE_LOAD_ERROR);
  if (operator.data) return { operator: true, profile: null, permissions: defaultPermissions(null) };
  const lookup = () => client.from("staff_profiles").select("id, auth_user_id, organization_id, full_name, email, phone, role, is_active").eq("auth_user_id", uid).maybeSingle();
  let result = await lookup();
  if (result.error) throw new Error(PROFILE_LOAD_ERROR);
  if (!result.data) {
    const claim = await client.rpc("fn_claim_staff_profile", { p_full_name: null });
    if (claim.error) throw new Error(PROFILE_LOAD_ERROR);
    result = await lookup();
    if (result.error) throw new Error(PROFILE_LOAD_ERROR);
  }
  const profile = result.data as StaffProfile | null;
  if (!profile || !profile.is_active) return { operator: false, profile, permissions: defaultPermissions(null) };
  const permissions = await client.rpc("fn_my_permissions", {});
  const p = permissions.data as { allowed?: unknown; full?: unknown; sees_money?: boolean } | null;
  if (permissions.error || !p || !Array.isArray(p.allowed) || !p.allowed.every(c => typeof c === "string") || !Array.isArray(p.full) || !p.full.every(c => typeof c === "string")) throw new Error(PROFILE_LOAD_ERROR);
  return { operator: false, profile, permissions: { allowed: new Set(p.allowed), full: new Set(p.full), seesMoney: !!p.sees_money } };
}
