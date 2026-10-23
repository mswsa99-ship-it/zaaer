import { Link } from "react-router-dom";
import { MessageCircle, BookCheck, CalendarPlus, MapPin, Clock } from "lucide-react";
import { useBranch } from "../../lib/branch";

/** The guest's front door: three things a guest comes for, nothing else. */
export default function Landing() {
  const { branch } = useBranch();
  const actions = [
    { to: "/booking/new", icon: CalendarPlus, title: "احجز الآن", desc: "التوفر والأسعار لتواريخك", tone: "bg-brand-600 text-white hover:bg-brand-700", iconTone: "bg-white/15 text-white" },
    { to: "/booking/lookup", icon: BookCheck, title: "حجوزاتي", desc: "برقم جوالك فقط", tone: "card hover:border-brand-300", iconTone: "bg-brand-50 text-brand-600" },
    { to: "/reception", icon: MessageCircle, title: "اسأل الاستقبال", desc: "رد فوري على مدار الساعة", tone: "card hover:border-brand-300", iconTone: "bg-accent-500/10 text-accent-600" },
  ];
  return (
    <div className="mx-auto max-w-md px-4 py-10 lg:py-16">
      <h1 className="text-center text-3xl font-bold text-ink-800">أهلًا بك في منازل الراحة</h1>
      {branch && (
        <p className="mt-3 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-sm text-ink-500">
          <span className="inline-flex items-center gap-1"><MapPin className="h-3.5 w-3.5" /> {branch.name_ar}</span>
          {branch.check_in_time && <span className="inline-flex items-center gap-1"><Clock className="h-3.5 w-3.5" /> الوصول {branch.check_in_time.slice(0, 5)} · المغادرة {branch.check_out_time?.slice(0, 5)}</span>}
        </p>
      )}
      <div className="mt-8 space-y-3">
        {actions.map((a) => (
          <Link key={a.to} to={a.to} className={`flex items-center gap-4 rounded-2xl p-5 shadow-sm transition ${a.tone}`}>
            <span className={`flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl ${a.iconTone}`}><a.icon className="h-6 w-6" /></span>
            <span>
              <span className="block text-lg font-semibold">{a.title}</span>
              <span className="block text-sm opacity-80">{a.desc}</span>
            </span>
          </Link>
        ))}
      </div>
    </div>
  );
}
