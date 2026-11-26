import type { OpsReply } from "./api";

/** A late reply is labelled with the question it answers and is read-only: any action it proposed is named but never offered for confirmation here. */
export function opsLateReplyText(question: string, r: OpsReply): string {
  const flat = question.replace(/\s+/g, " ").trim();
  const cps = Array.from(flat);   // by code point, so an emoji is never cut in half
  const q = cps.length > 80 ? cps.slice(0, 80).join("") + "…" : flat;
  const acts = (r.proposals ?? []).map((x) => `• ${x.summary}`).join("\n");
  return `وصل ردّ متأخر على سؤالك «${q}»:\n${r.reply}` + (acts ? `\n\nاقترح الرد إجراءً لم يُعرض هنا للتأكيد لأنه وصل متأخرًا:\n${acts}\nاطلبه مجددًا إن كنت ما زلت تريده.` : "");
}
