/** A conversation id is a locator, never proof of a guest's booking or another branch. */
export interface ReceptionScope { organizationId: string; branchId: string; guestToken: string | null }
export interface ReceptionConversation { organization_id: string | null; branch_id: string | null; guest_token: string | null; client_fingerprint: string | null; channel: string }
export function mayResumeConversation(c: ReceptionConversation, s: ReceptionScope, proof: { trustedService: boolean; staff: boolean; fingerprint: string; channel: string }): boolean {
 if (c.organization_id !== s.organizationId || c.branch_id !== s.branchId || c.channel !== proof.channel) return false;
 if (proof.trustedService || proof.staff) return true;
 // The booking capability must be supplied again, never recovered from a conversation id.
 if (c.guest_token) return !!s.guestToken && c.guest_token === s.guestToken;
 return !!proof.fingerprint && c.client_fingerprint === proof.fingerprint;
}
export function bookingMatchesScope(reservation: { organization_id?: string; branch_id?: string } | null, s: ReceptionScope): boolean {
 return !!reservation && reservation.organization_id === s.organizationId && reservation.branch_id === s.branchId;
}
export function aiBudgetAvailable(settings: { daily_request_limit?: number; ops_daily_request_limit?: number; daily_token_budget?: number }, usage: { requests?: number; tokens_in?: number; tokens_out?: number } | null, ops = false): boolean {
 return (usage?.requests ?? 0) < Number(settings.daily_request_limit ?? 2000) + (ops ? Number(settings.ops_daily_request_limit ?? 500) : 0)
  && (usage?.tokens_in ?? 0) + (usage?.tokens_out ?? 0) < Number(settings.daily_token_budget ?? 500000);
}
