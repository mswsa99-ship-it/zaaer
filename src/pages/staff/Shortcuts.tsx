import { SectionTitle, Card } from "../../components/ui";
import { SHORTCUTS } from "../../lib/shortcuts";

/** 6.15 (U15): the page that lists the keyboard shortcuts. */
export default function Shortcuts() {
  return (
    <div>
      <SectionTitle title="اختصارات لوحة المفاتيح" subtitle="للعمل بلوحة المفاتيح وحدها؛ الحروف لا تعمل أثناء الكتابة في حقل." />
      <Card>
        <table className="w-full text-sm" data-testid="shortcuts-table">
          <thead className="text-ink-500"><tr><th className="py-2 text-right font-medium">الاختصار</th><th className="py-2 text-right font-medium">ما يفعله</th></tr></thead>
          <tbody>{SHORTCUTS.map((s) => (<tr key={s.keys} className="border-t border-ink-50"><td className="py-2"><kbd dir="ltr" className="rounded border border-ink-200 bg-ink-50 px-2 py-0.5 font-mono text-xs">{s.keys}</kbd></td><td className="py-2 text-ink-700">{s.label}</td></tr>))}</tbody>
        </table>
      </Card>
    </div>
  );
}
