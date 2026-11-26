import type { OpsReply } from "./api";

/** A late reply is labelled with the question it answers and is read-only: any action it proposed is named but never offered for confirmation here. */
export function opsLateReplyText(question: string, r: OpsReply): string {
  const q = question.length > 80 ? question.slice(0, 80) + "…" : question;
  const acts = (r.proposals ?? []).map((x) => `• ${x.summary}`).join("\n");
  return `وصل ردّ متأخر على سؤالك «${q}»:\n${r.reply}` + (acts ? `\n\nاقترح الرد إجراءً لم يُعرض هنا للتأكيد لأنه وصل متأخرًا:\n${acts}\nاطلبه مجددًا إن كنت ما زلت تريده.` : "");
}
