import { individualAllows, type IndividualPermissions } from "./individualPermissions";

/**
 * The staff inbox (0128): replying to a guest is an ADD on /staff/inbox, taking or returning a conversation is an EDIT.
 * Individual-mode accounts get each affordance only with its own grant (view is implied by the grant model).
 * Legacy accounts keep what the screen always showed: the server decides by role (fn_can), nothing is hidden here.
 */
export function inboxAffordances(pageAccess: IndividualPermissions | undefined): { canReply: boolean; canTake: boolean } {
  if (!pageAccess || pageAccess.mode !== "individual") return { canReply: true, canTake: true };
  return { canReply: individualAllows(pageAccess, "/staff/inbox", "add"), canTake: individualAllows(pageAccess, "/staff/inbox", "edit") };
}
