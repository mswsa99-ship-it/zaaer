/**
 * The unit's licence number (0075, plan item 1.8): the owner, the manager and the supervisor read it; no other role
 * asks for it, and the server refuses them if they do. The licences of the active branch as room → number.
 */
import { useAuth } from "./auth";
import { useBranchQuery } from "./useBranchQuery";
import { opsApi } from "./api";
import { readsUnitLicense } from "./unitLicenseRoles";

export { UNIT_LICENSE_READERS, readsUnitLicense } from "./unitLicenseRoles";

const NONE: ReadonlyMap<string, string> = new Map();

/** room id → licence number for the active branch; an empty map for a role that does not read it (no request sent). */
export function useUnitLicenses() {
  const role = useAuth().profile?.role;
  const reads = readsUnitLicense(role);
  const q = useBranchQuery<ReadonlyMap<string, string>>(async (b) => {
    if (!reads) return NONE;
    return new Map((await opsApi.roomLicenses(b)).map((l) => [l.room_id, l.license_number]));
  }, [reads], NONE);
  return { reads, licenses: q.data, reload: q.reload, error: q.error };
}
