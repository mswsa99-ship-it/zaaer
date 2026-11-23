/**
 * The password rule (owner's decision, 23 Nov 2026): at least 6 characters with English letters and digits. The same
 * rule is set in Supabase Auth (Authentication → Sign In / Providers → Email: minimum length 6, «Letters and
 * digits»), which enforces it on the server; the screens say it before the request is sent.
 */
export const PASSWORD_MIN = 6;
export const PASSWORD_MAX = 72;   // bcrypt reads at most 72 bytes; Supabase refuses longer
export const PASSWORD_HINT = "6 أحرف على الأقل، فيها حروف إنجليزية وأرقام.";

/** Why this password is refused, or null when it passes. */
export function passwordProblem(pw: string): string | null {
  if (pw.length < PASSWORD_MIN) return "كلمة المرور 6 أحرف على الأقل.";
  if (new TextEncoder().encode(pw).length > PASSWORD_MAX) return "كلمة المرور أطول من المسموح (72 حرفًا).";
  if (!/[A-Za-z]/.test(pw)) return "أضف إلى كلمة المرور حرفًا إنجليزيًا واحدًا على الأقل.";
  if (!/[0-9]/.test(pw)) return "أضف إلى كلمة المرور رقمًا إنجليزيًا واحدًا على الأقل (0–9).";
  if (/\s/.test(pw)) return "كلمة المرور بلا مسافات.";
  return null;
}

/** The new password and its confirmation together. */
export function newPasswordProblem(pw: string, confirm: string): string | null {
  return passwordProblem(pw) ?? (pw !== confirm ? "كلمتا المرور غير متطابقتين." : null);
}
