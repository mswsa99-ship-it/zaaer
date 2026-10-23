import ReceptionChat from "../../components/ReceptionChat";
import { SectionTitle } from "../../components/ui";

/**
 * Staff try the reception assistant here — the same assistant (same knowledge, rules and handoff) guests reach
 * on WhatsApp. Conversations started here appear in the inbox as "شاشة" conversations.
 */
export default function AdminAssistant() {
  return (
    <div>
      <SectionTitle title="تجربة المساعد" subtitle="نفس المساعد الذي يرد على النزلاء في واتساب — جرّب الأسئلة قبل ربط الرقم أو بعد تعديل قاعدة المعرفة" />
      <ReceptionChat embedded />
    </div>
  );
}
