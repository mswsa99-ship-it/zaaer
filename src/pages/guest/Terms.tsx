export default function Terms() {
  return (
    <div className="mx-auto max-w-2xl px-4 py-8 lg:py-12">
      <h1 className="text-2xl font-bold text-ink-800">شروط الاستخدام</h1>
      <div className="prose mt-6 max-w-none text-sm leading-relaxed text-ink-600">
        <p>باستخدامك خدمات "منازل الراحة" فإنك توافق على الشروط التالية:</p>
        <h2 className="mt-6 text-base font-semibold text-ink-800">سياسة الإقامة</h2>
        <ul className="mt-2 list-disc space-y-1 pr-5">
          <li>وقت الوصول: 4:00 مساءً، وقت المغادرة: 12:00 ظهرًا.</li>
          <li>يجب تسجيل بيانات جميع النزلاء قبل الدخول.</li>
          <li>يُمنع الدخول قبل اعتماد المشرف ومطابقة الهوية.</li>
        </ul>
        <h2 className="mt-6 text-base font-semibold text-ink-800">سياسة الإلغاء</h2>
        <ul className="mt-2 list-disc space-y-1 pr-5">
          <li>الإلغاء قبل 48 ساعة: استرداد كامل.</li>
          <li>الإلغاء خلال 48 ساعة: قد تُطبّق رسوم وفق منصة الحجز.</li>
        </ul>
        <h2 className="mt-6 text-base font-semibold text-ink-800">الدفع</h2>
        <p className="mt-2">يتم الدفع إلكترونيًا عبر منصة الحجز أو رابط دفع أو جهاز نقاط البيع. لا يُقبل الدفع النقدي في رحلة الاستقبال الذكي.</p>
        <h2 className="mt-6 text-base font-semibold text-ink-800">المسؤولية</h2>
        <p className="mt-2">تسعى المنشأة لتقديم خدمة آمنة وموثوقة، لكنها لا تتحمل مسؤولية تعطل التكاملات الخارجية (منصات الحجز، مزودي الدفع) خارج سيطرتها.</p>
      </div>
    </div>
  );
}
