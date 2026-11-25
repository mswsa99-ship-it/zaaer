/**
 * The edge side of fn_ai_guest_reserve (0082): who the reserve guards, and what each of its statuses answers.
 *
 * The reserve is the single admission point for a SCREEN guest's message (a website visitor, anonymous or verified)
 * and runs atomically BEFORE the message is written. The service role (WhatsApp turns) and staff are not reserved:
 * WhatsApp senders are already bounded by their verified number, and staff are signed in. A status other than 'ok'
 * consumed no quota, so the message is not written and the guest gets a scripted reply; a status the code does not
 * know fails closed.
 *
 * Pure and free of Deno and Supabase so the unit tests (tests/unit/guest_reserve.test.ts, ER) pin every branch.
 */

/** the phone-code page («حجوزاتي» → guest-otp): where an otp_required guest proves the number */
export const OTP_LOOKUP_ROUTE = "/booking/lookup";

export function reserveApplies(scope: { channel: string; trustedService: boolean; staff: boolean }): boolean {
  return scope.channel === "screen" && !scope.trustedService && !scope.staff;
}

export interface ReserveDecision {
  /** true only for 'ok': write the message and answer it */
  proceed: boolean;
  reply?: string;
  actions?: Array<{ label: string; route?: string }>;
  /** extra response fields, e.g. { otp_required: true } for the UI's phone-code path */
  extra?: Record<string, unknown>;
  /** the ai_guardrail_events rule recorded for a refusal */
  rule?: string;
  /** set when the scope itself is broken: answer { error } with this status, never admit */
  error?: string;
  errorStatus?: number;
}

const LIMIT_REPLIES: Record<string, { rule: string; ar: string; en: string }> = {
  session_limit: {
    rule: "session_message_limit",
    ar: "وصلت المحادثة إلى الحد الأقصى للرسائل. للمتابعة، تواصل مع الاستقبال أو ابدأ جلسة جديدة.",
    en: "This chat has reached its message limit. To continue, contact the reception or start a new chat.",
  },
  device_limit: {
    rule: "guest_device_limit",
    ar: "تجاوز هذا الجهاز حد الرسائل اليومي. للمتابعة، تواصل مع الاستقبال أو عُد غدًا.",
    en: "This device has passed its daily message limit. To continue, contact the reception or come back tomorrow.",
  },
  branch_limit: {
    rule: "guest_branch_limit",
    ar: "الخدمة مشغولة الآن. تواصل مع الاستقبال وسنساعدك فورًا.",
    en: "The service is busy right now. Contact the reception and we will help you at once.",
  },
  hotel_limit: {
    rule: "guest_hotel_limit",
    ar: "الخدمة مشغولة الآن. تواصل مع الاستقبال وسنساعدك فورًا.",
    en: "The service is busy right now. Contact the reception and we will help you at once.",
  },
};

export function mapReserveStatus(status: string, english: boolean): ReserveDecision {
  if (status === "ok") return { proceed: true };
  if (status === "otp_required") {
    return {
      proceed: false,
      rule: "guest_otp_required",
      extra: { otp_required: true },
      reply: english
        ? "To keep chatting, confirm your phone number with a code we send you on WhatsApp."
        : "للمتابعة، أكّد رقم جوالك برمز يصلك على واتساب.",
      actions: [{ label: english ? "Phone code" : "رمز الجوال", route: OTP_LOOKUP_ROUTE }],
    };
  }
  const known = LIMIT_REPLIES[status];
  if (known) {
    return { proceed: false, rule: known.rule, reply: english ? known.en : known.ar, actions: [] };
  }
  // branch_not_found / conversation_not_found / anything unexpected: the reserve could not place the caller — fail closed
  return { proceed: false, error: status === "branch_not_found" ? "branch_not_found" : "invalid_conversation_scope", errorStatus: status === "branch_not_found" ? 400 : 403 };
}

/**
 * No double request increment: a message the reserve admitted already spent the hotel's daily request budget inside
 * fn_ai_guest_reserve, so the usage bump that follows adds its tokens (and fallbacks/blocks) but zero requests.
 * Every other caller (staff, WhatsApp, a path before the reserve) counts exactly as before.
 */
export function countedRequests(requested: number, reserveCounted: boolean): number {
  return reserveCounted ? 0 : requested;
}
