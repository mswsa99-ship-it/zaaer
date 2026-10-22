import { Link } from "react-router-dom";
import { MessageCircle, BookCheck, ShieldCheck, Clock, MapPin, Wifi, KeyRound } from "lucide-react";

export default function Landing() {
  return (
    <div className="mx-auto max-w-5xl px-4 py-8 lg:py-16">
      {/* Hero */}
      <section className="mb-12 text-center">
        <div className="mb-5 inline-flex items-center gap-2 rounded-full bg-brand-50 px-4 py-1.5 text-xs font-medium text-brand-700">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent-500 opacity-75" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-accent-500" />
          </span>
          مساعد استقبال ذكي جاهز لخدمتك
        </div>
        <h1 className="text-3xl font-bold leading-tight text-ink-800 lg:text-5xl lg:leading-[1.2]">
          أهلًا وسهلًا بك في منازل الراحة
        </h1>
        <p className="mx-auto mt-4 max-w-2xl text-base text-ink-500 lg:text-lg">
          نساعدك في إجراءات الحجز والوصول بسرعة وأمان، على مدار الساعة. اختر كيف تبدأ رحلتك معنا.
        </p>
        <Link to="/reception" className="btn-primary mt-6 px-6 py-3 text-base">
          <MessageCircle className="h-5 w-5" /> ابدأ المحادثة مع الاستقبال الذكي
        </Link>
      </section>

      {/* Action cards */}
      <section className="mx-auto mb-16 grid max-w-3xl gap-4 sm:grid-cols-2">
        <Link to="/booking/lookup" className="card group flex flex-col items-start gap-4 p-7 transition-all hover:border-brand-300 hover:shadow-md">
          <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-brand-50 text-brand-600 transition-colors group-hover:bg-brand-100">
            <BookCheck className="h-6 w-6" />
          </div>
          <div>
            <h2 className="text-lg font-semibold text-ink-800">لدي حجز سابق</h2>
            <p className="mt-1 text-sm text-ink-500">أدخل رقم حجزك لإتمام إجراءات الوصول وتسليم رمز الصندوق.</p>
          </div>
          <span className="mt-auto text-sm font-medium text-brand-600">ابدأ الآن ←</span>
        </Link>

        <Link to="/booking/new" className="card group flex flex-col items-start gap-4 p-7 transition-all hover:border-accent-500/40 hover:shadow-md">
          <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-accent-500/10 text-accent-600 transition-colors group-hover:bg-accent-500/20">
            <MessageCircle className="h-6 w-6" />
          </div>
          <div>
            <h2 className="text-lg font-semibold text-ink-800">أرغب بحجز جديد</h2>
            <p className="mt-1 text-sm text-ink-500">استكشف الغرف المتاحة والأسعار وأكمل حجزك عبر منصة الحجز المعتمدة.</p>
          </div>
          <span className="mt-auto text-sm font-medium text-accent-600">استكشف ←</span>
        </Link>
      </section>

      {/* Features */}
      <section className="mx-auto max-w-4xl">
        <h3 className="mb-6 text-center text-base font-semibold text-ink-700">لماذا مساعد الاستقبال الذكي؟</h3>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {[
            { icon: Clock, title: "متاح ٢٤ ساعة", desc: "استقبال ذكي لا ينام" },
            { icon: ShieldCheck, title: "خصوصية محمية", desc: "بياناتك مشفرة وآمنة" },
            { icon: KeyRound, title: "دخول بلا انتظار", desc: "رمز الصندوق فور الاعتماد" },
            { icon: Wifi, title: "تجربة سلسة", desc: "من هاتفك أو شاشة الاستقبال" },
          ].map((f) => (
            <div key={f.title} className="card flex flex-col items-center gap-2 p-5 text-center">
              <f.icon className="h-7 w-7 text-brand-500" />
              <p className="text-sm font-semibold text-ink-700">{f.title}</p>
              <p className="text-xs text-ink-400">{f.desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* Location */}
      <section className="mt-16 flex flex-col items-center gap-3 rounded-2xl bg-brand-600 px-6 py-8 text-center text-white">
        <MapPin className="h-6 w-6" />
        <p className="text-sm">فرع الرياض — طريق الملك فهد</p>
        <Link to="/kiosk" className="mt-2 rounded-xl bg-white/15 px-4 py-2 text-xs font-medium hover:bg-white/25">
          وضع شاشة الاستقبال (Kiosk)
        </Link>
      </section>
    </div>
  );
}
