export default function Privacy() {
  return (
    <div className="mx-auto max-w-2xl px-4 py-8 lg:py-12">
      <h1 className="text-2xl font-bold text-ink-800">سياسة الخصوصية</h1>
      <div className="prose mt-6 max-w-none text-sm leading-relaxed text-ink-600">
        <p>تلتزم "فايف اورز" بحماية بياناتك الشخصية وفق نظام حماية البيانات الشخصية السعودي (PDPL).</p>
        <h2 className="mt-6 text-base font-semibold text-ink-800">البيانات التي نجمعها</h2>
        <ul className="mt-2 list-disc space-y-1 pr-5">
          <li>الاسم الثلاثي ونوع ورقم الوثيقة الرسمية (مشفر على الخادم).</li>
          <li>الجنسية وتاريخ الميلاد ورقم الجوال.</li>
          <li>بيانات الإقامة (تاريخ الوصول والمغادرة، الغرفة).</li>
          <li>سجلات الدفع والمعاملات المالية.</li>
        </ul>
        <h2 className="mt-6 text-base font-semibold text-ink-800">كيف نحميها</h2>
        <ul className="mt-2 list-disc space-y-1 pr-5">
          <li>تُخزَّن أرقام الوثائق ورموز صناديق المفاتيح مشفّرة على الخادم فقط.</li>
          <li>لا تُرسل البيانات الحساسة عبر محادثات واتساب.</li>
          <li>تُقيّد صلاحية الوصول بحسب الدور الوظيفي.</li>
          <li>تنتهي صلاحية الروابط المؤقتة تلقائيًا.</li>
        </ul>
        <h2 className="mt-6 text-base font-semibold text-ink-800">الاحتفاظ والإتلاف</h2>
        <p className="mt-2">تُحفظ البيانات طوال فترة الإقامة ولترة محددة بعدها وفق المتطلبات النظامية، ثم تُتلف وفق سياسة محددة.</p>
        <h2 className="mt-6 text-base font-semibold text-ink-800">حقوقك</h2>
        <p className="mt-2">لك الحق في الاطلاع على بياناتك وطلب تصحيحها، وذلك بمراجعة إدارة المنشأة.</p>
      </div>
    </div>
  );
}
