/**
 * 5.4 (ق6) — منع الفتح داخل إطار بكود. الاستضافة الثابتة (GitHub Pages) لا تستطيع إرسال
 * X-Frame-Options ولا frame-ancestors، لذا يمتنع التطبيق نفسه عن العمل داخل إطار.
 *
 * الحذر الأمني هنا اتجاه البيانات: روابط الضيوف تحمل الرمز في المسار نفسه
 * (‎/booking/status/:token و‎/checkin/:token). لو أعاد الحارس توجيه الإطار الأعلى إلى
 * العنوان الحالي كما هو، تسرب الرمز إلى الصفحة الحاضنة (referrer وسجل التصفح). لذلك
 * الوجهة هي جذر التطبيق فقط — بلا مسار ولا استعلام ولا جزء (hash).
 */

export interface FrameLike {
  top: unknown;
  self: unknown;
}

/** هل نافذتنا داخل إطار؟ أي تشويش في المقارنة يُعامل كإطار (فشل نحو الحماية). */
export function isFramed(w: FrameLike): boolean {
  try {
    return w.top !== w.self;
  } catch {
    return true;
  }
}

/**
 * وجهة الخروج من الإطار: عنوان قاعدة التطبيق المطلق (مثل https://host/ أو ‎https://host/zaaer/‎)
 * محسوبًا من base البناء — أبدًا من مسار الصفحة الحالية أو استعلامها أو جزئها.
 */
export function breakoutTarget(base: string, currentHref: string): string {
  try {
    return new URL(base || "/", currentHref).href;
  } catch {
    return "/";
  }
}

interface GuardWindow {
  top: unknown;
  self: unknown;
  location: { href: string; replace(url: string): void };
  document?: { documentElement?: { style: { display: string } } };
}

/**
 * يُستدعى قبل أي رسم. عند اكتشاف إطار يخفي المحتوى فورًا (واجهة خفية لا تُقرأ ولا تُنقر)،
 * ثم يحاول نقل النافذة العليا إلى جذر التطبيق. كروم الحديث يمنع نقل الأعلى من إطار أجنبي
 * بلا تفاعل مستخدم ويتجاهله بلا استثناء، لذلك لا يوجد fallback يعيد تحميل الصفحة (كان
 * يصنع حلقة reload لا تنتهي): يبقى الإخفاء هو الحماية الدائمة. يرجع true إن كنا داخل إطار.
 */
export function installFrameGuard(w: GuardWindow, base: string): boolean {
  if (!isFramed(w as FrameLike)) return false;
  try {
    if (w.document?.documentElement) w.document.documentElement.style.display = "none";
  } catch {
    /* إخفاء أفضل جهد */
  }
  try {
    (w.top as { location: { replace(url: string): void } }).location.replace(breakoutTarget(base, w.location.href));
  } catch {
    /* منع المتصفح النقل: يكفي الإخفاء */
  }
  return true;
}
