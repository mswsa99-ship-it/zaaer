# بيئة التطوير الموازية (Staging)

نسخة كاملة من النظام على الإنترنت، منفصلة عن الإنتاج، للتطوير والتجربة والقبول قبل أي إطلاق. بياناتها **افتراضية فقط** (بذور العرض) — لا يُدخل فيها نزيل حقيقي ولا رقم هوية حقيقي ولا مفتاح دفع حقيقي.

| الجزء | أين | يتحدث من |
|---|---|---|
| الواجهة (الويب) | GitHub Pages: `https://mswsa99-ship-it.github.io/zaaer/` | فرع `develop` تلقائيًا (`.github/workflows/staging.yml`) |
| قاعدة البيانات + Auth + Realtime | مشروع Supabase مستقل للـstaging (المعرّف في `.env.staging`) | الترحيلات في `supabase/migrations` |
| Edge Functions | `ai-reception` · `ai-ops` · `ai-health` على مشروع الـstaging | `supabase/functions` |
| الإنتاج (لاحقًا) | مشروع Supabase آخر + Netlify | فرع `main` (`production.yml`) — §6 |

```
feature/* ──PR──▶ develop ──تلقائيًا──▶ staging   (verify → backend → web → Pages → فحص حي)
                     │
                     └──PR──▶ main ──بموافقة──▶ production (verify → backend → Netlify → smoke)
```

## 1. الحالة الحالية (22 أكتوبر 2026)

- قاعدة البيانات: الترحيلات 0001–0014 و0016 مطبقة ومسجلة في سجل الترحيلات، ومطابقة لقاعدة مبنية من الصفر من نفس الملفات (المخطط، تعريفات الدوال، الصلاحيات، البيانات).
- **0015 معلّق**: يعيد إنشاء `fn_admin_delete_definition` (الحذف النهائي لتعريف بلا تبعيات). كل شيء آخر يعمل بدونه، والأرشفة تعمل. يُطبَّق تلقائيًا بأول تشغيل للخط الخلفي (§3)، أو يدويًا (§3-ب).
- مفاتيح التشفير (رموز الصناديق وأرقام الهويات) أُنشئت داخل قاعدة البيانات في Supabase Vault (ترحيل 0014) ولم تمر بأي ملف أو محادثة.
- `demo_mode = false`: لا يصبح أول مسجّل مالكًا تلقائيًا؛ توجد **دعوة مالك واحدة** لبريد حساب المالك.
- Edge Functions منشورة ومطابقة حرفيًا لملفات المستودع. الذكاء الاصطناعي **معطّل** (لا مفتاح بعد) → المساعدان يعملان بالمسار الحتمي: قاعدة المعرفة + السياسات + الردود الإرشادية.
- واتساب، الدفع الإلكتروني، التسجيل الحكومي: غير متكاملة وتظهر بحالتها الحقيقية (لا نجاح وهمي).

## 2. إعداد لمرة واحدة (صاحب الحساب)

**أ. تفعيل GitHub Pages** — المستودع ← Settings ← Pages ← Build and deployment ← Source: **GitHub Actions**.
ثم Settings ← Environments ← `github-pages` ← Deployment branches and tags: أضف الفرع **`develop`** (إن كانت القاعدة الافتراضية تسمح بـ`main` فقط). بعدها أعد تشغيل آخر تشغيل لـ**staging** من تبويب Actions (Re-run all jobs).

**ب. روابط الدخول في Supabase** — مشروع الـstaging ← Authentication ← URL Configuration:
- Site URL: `https://mswsa99-ship-it.github.io/zaaer/`
- Redirect URLs: `https://mswsa99-ship-it.github.io/zaaer/**`

بدون ذلك يُفعَّل البريد عند الضغط على رابط التأكيد لكن المتصفح يُحوَّل إلى `localhost` — ثم يكفي فتح صفحة الدخول يدويًا.

**ج. حساب المالك** — افتح `…/zaaer/staff/login` ← «حساب جديد» بنفس البريد الذي أُنشئت له دعوة المالك ← أكّد البريد ← سجّل الدخول. يُربط الحساب بالدعوة تلقائيًا بدور «مالك» وله كل الفروع. بقية الموظفين يُدعون من `/admin/staff`.
> خدمة البريد المدمجة في Supabase لا ترسل إلا لأعضاء فريق المشروع وبعدد محدود في الساعة. لموظفين آخرين على الـstaging: اضبط SMTP خاصًا (Authentication ← Emails)، أو عطّل «Confirm email» في بيئة الـstaging فقط.

## 3. نشر الخلفية تلقائيًا (اختياري، موصى به)

أضف في المستودع ← Settings ← Secrets and variables ← Actions ← **Secrets**:

| الاسم | من أين |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | Supabase ← Account ← Access Tokens (رمز شخصي) |
| `STAGING_DB_PASSWORD` | كلمة مرور قاعدة بيانات مشروع الـstaging (Project Settings ← Database؛ يمكن إعادة تعيينها هناك) |
| `STAGING_GEMINI_API_KEY` | اختياري — مفتاح Gemini **جديد** (§4) |

من أول دفع إلى `develop` بعدها يطبّق الخط الترحيلات المعلقة بالترتيب (ومنها 0015)، وينشر الدوال، ويضبط أسرارها (`APP_BASE_URL` تلقائيًا = رابط الـstaging). بدون هذه الأسرار تُنشر الواجهة فقط ويظهر تنبيه «Backend not deployed» في ملخص التشغيل.

**ب. يدويًا بدل ذلك**: انسخ محتوى `supabase/migrations/20261022161000_0015_admin_delete_definition.sql` في SQL Editor لمشروع الـstaging وشغّله. آمن للتكرار (`create or replace` + `grant`)، فإن طبّقه الخط لاحقًا مرة أخرى فلا أثر.

> متغيرات اختيارية (Variables): `STAGING_SUPABASE_URL` و`STAGING_SUPABASE_ANON_KEY` تتجاوز ما في `.env.staging`، و`STAGING_DEFAULT_BRANCH_ID` يثبّت فرع شاشات النزلاء، و`STAGING_APP_BASE_URL` عند ربط نطاق خاص.

## 4. الذكاء الاصطناعي (Gemini)

1. **ألغِ المفتاح الذي أُرسل في المحادثة وأنشئ مفتاحًا جديدًا** (Google AI Studio ← API keys). أي مفتاح كُتب في محادثة أو ملف يُعامل كمكشوف.
2. ضعه في مكان واحد فقط: Supabase ← Edge Functions ← Secrets باسم `GEMINI_API_KEY` — أو سر GitHub `STAGING_GEMINI_API_KEY` إن فعّلت §3. لا يوضع أبدًا في `.env.staging` ولا في أي ملف في المستودع.
3. من `/admin/ai-settings`: فعّل المحرك ← «اختبار الاتصال».

المفتاح لا يصل إلى المتصفح ولا قاعدة البيانات. عند غيابه أو تجاوز الميزانية أو انقطاع المزود يعمل المسار الحتمي نفسه.

## 5. دورة التطوير اليومية

1. فرع من `develop` (`feature/...`) ← تعديلات ← `npm run verify:quick` أثناء العمل و`npm run verify` قبل الدفع.
2. Pull Request إلى `develop`: يعمل `verify.yml` (typecheck، الوحدات، الدوال، SQL من الصفر على PostgreSQL 16، السباقات، البناءان، E2E).
3. الدمج في `develop` ← `staging.yml`: البوابة كاملة ← الخلفية (إن فُعّلت §3) ← بناء الواجهة على مشروع الـstaging ← Pages ← فحص حي.
4. تغييرات قاعدة البيانات: **ملف ترحيل جديد فقط** بطابع زمني أحدث من آخر ملف. لا تعدّل ترحيلًا مطبّقًا، ولا تغيّر مخطط الـstaging من لوحة Supabase مباشرة (يفسد مزامنة السجل).
5. تشغيل الواجهة محليًا على خلفية الـstaging: `npx vite --mode staging` (يقرأ `.env.staging`؛ ما تفعله يُكتب في قاعدة الـstaging).

## 6. الإنتاج (عند الجاهزية)

مشروع Supabase **جديد** للإنتاج وموقع Netlify، ثم في GitHub ← Environments ← `production` (مع **Required reviewers**):

- Variables: `SUPABASE_PROJECT_REF` · `VITE_SUPABASE_URL` · `VITE_SUPABASE_ANON_KEY` · `APP_BASE_URL` · `NETLIFY_SITE_ID` · (`VITE_DEFAULT_BRANCH_ID` اختياري)
- Secrets: `SUPABASE_ACCESS_TOKEN` · `SUPABASE_DB_PASSWORD` · `NETLIFY_AUTH_TOKEN` · (`GEMINI_API_KEY` اختياري)
- متغير المستودع `PRODUCTION_DEPLOY = enabled` ليصبح الدفع إلى `main` إطلاقًا (أو شغّله يدويًا من Actions).

الترحيلات تُنشئ مفاتيح التشفير في Vault الإنتاج تلقائيًا. قبل أول إطلاق حقيقي: `demo_mode = false`، دعوة المالك من SQL Editor، ومراجعة بيانات البذور (0004 تضيف بيانات عرض — تُستبدل ببيانات المنشأة الحقيقية من لوحة الإدارة، **ولا يُستورد مخزون زائر الحقيقي**).

## 7. قواعد الأمان في الـstaging

- بيانات افتراضية فقط. لا هويات أو جوالات أو بطاقات حقيقية، ولا مفاتيح مزودي دفع/واتساب حقيقية.
- `.env.staging` يحوي رابط المشروع والمفتاح العام (anon) فقط — كلاهما يصل لكل زائر في ملفات الواجهة أصلًا، والحماية في قاعدة البيانات (RLS + دوال `SECURITY DEFINER` + تحقق الدور والفرع في كل عملية). مفتاح service-role وكلمة مرور قاعدة البيانات ومفتاح Gemini **لا** تُكتب في المستودع ولا في المحادثات ولا في السجلات.
- GitHub Pages لا يضيف ترويسات الأمان (`X-Frame-Options`...) — مقبول للـstaging فقط؛ الإنتاج على Netlify يضيفها من `netlify.toml`، ويفحصها `scripts/smoke-deployed.sh`.

## 8. ما يُفحص بعد كل نشر

`staging.yml` ← وظيفة **live**:
- `scripts/smoke-deployed.sh` (قراءة فقط): الصفحات والروابط العميقة تُخدم، الزائر المجهول لا يقرأ الحجوزات/السندات/قاعدة المعرفة/الموظفين، `fn_public_knowledge` يجيب، `ai-reception` يرد.
- `tests/staging/live.spec.ts` (متصفح حقيقي): الصفحة الرئيسية تحت المسار الفرعي، المسارات المحمية تحوّل للدخول، **إجابة النزيل تأتي من الـEdge Function نفسها** (HTTP 200 والنص المعروض هو نصها)، ورفض تسليم رمز الصندوق في المحادثة.

محليًا على أي نشر: `STAGING_URL=https://mswsa99-ship-it.github.io/zaaer/ npx playwright test -c playwright.staging.config.ts`

## 9. أعطال متوقعة

| الرسالة | الحل |
|---|---|
| `Get Pages site failed` | §2-أ: Source = GitHub Actions |
| `Branch "develop" is not allowed to deploy to github-pages due to environment protection rules` | §2-أ: أضف `develop` لفروع بيئة `github-pages` |
| رابط تأكيد البريد يفتح `localhost` | §2-ب |
| بعد الدخول: «لا يوجد فرع مخوّل لحسابك» أو لا صلاحيات | الحساب بلا دعوة — ادعه من `/admin/staff` بنفس البريد |
| `Remote migration versions not found in local migrations directory` | تغيير طُبّق على القاعدة خارج ملفات الترحيل — راجع `supabase migration list` ثم `supabase migration repair` (توثيق Supabase: Database Migrations) |
| `Backend not deployed` (تنبيه) | §3 — أو طبّق الترحيلات يدويًا |
