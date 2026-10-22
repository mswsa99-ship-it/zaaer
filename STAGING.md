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

## 1. الحالة الحالية (23 أكتوبر 2026)

- قاعدة البيانات: الترحيلات 0001–0019 كلها مطبقة ومسجلة في سجل الترحيلات، والسجل يطابق ملفات `supabase/migrations` واحدًا بواحد (فلا يجد الخط الخلفي ما يطبّقه مرة ثانية). تعريفات الدوال مطابقة لقاعدة مبنية من الصفر من نفس الملفات؛ الاستثناء الوحيد `fn_admin_delete_definition` (0015، طُبّق يدويًا من SQL Editor وفق §3-ب): مطابق سطرًا بسطر بعد تجاهل المسافات البادئة التي أضافها المحرر.
- مفاتيح التشفير (رموز الصناديق وأرقام الهويات) أُنشئت داخل قاعدة البيانات في Supabase Vault (ترحيل 0014) ولم تمر بأي ملف أو محادثة.
- `demo_mode = false`: لا يصبح أول مسجّل مالكًا تلقائيًا. **حساب المالك مُنشأ ومؤكَّد ومربوط بدعوته** (دور «مالك»، كل الفروع)، وهو الحساب الوحيد؛ بقية الموظفين يُدعون من `/admin/staff`.
- Edge Functions (`ai-reception` v8 · `ai-ops` v8 · `ai-health` v6) منشورة ومطابقة حرفيًا لملفات المستودع.
- **التواريخ التشغيلية بتوقيت الفرع** (ترحيل 0019): جلسات قاعدة البيانات المستضافة تعمل بتوقيت UTC، فكان «اليوم» بين 00:00 و03:00 بتوقيت الرياض يُحسب يوم أمس (ملخص اليوم، شرط فترة الإقامة لإصدار الرمز، سريان تبديل الوحدة، تاريخ الميلاد). صار يُحسب من `branches.timezone` في SQL والواجهة والمساعدَين.
- **الذكاء الاصطناعي مفعّل** (`GEMINI_API_KEY` في أسرار Edge Functions): النموذج الأساسي `gemini-3.6-flash`، والاحتياطيان `gemini-3.8-flash` ثم `gemini-3.5-flash-lite`. سبب الترتيب: `gemini-3.8-flash` أعاد لهذا المفتاح «503 high demand» لساعات متواصلة يوم الإعداد بينما أجاب `gemini-3.6-flash` فورًا (بما في ذلك استدعاء الأدوات). كل تغيير على الإعدادات مسجّل في سجل التدقيق مع السبب؛ ويمكن للمالك إعادة الترتيب من `/admin/ai-settings`.
- `APP_BASE_URL`: أفاد المالك بضبطه يدويًا من لوحة Supabase (Edge Functions ← Secrets) بالقيمة `https://mswsa99-ship-it.github.io/zaaer` وفق §3-ب. قيم الأسرار لا تظهر لأي أداة، فلا يُتحقق منها إلا بأثرها؛ وبدونه تبقى روابط المساعد نسبية (`/booking/...`) وتعمل أزرار المحادثة كما هي.
- واتساب، الدفع الإلكتروني، التسجيل الحكومي: غير متكاملة وتظهر بحالتها الحقيقية (لا نجاح وهمي).
- **متابعة قبل نهاية 2026**: الواجهة والدوال تستخدم مفاتيح Supabase القديمة (`anon` و`service_role`)، وSupabase توقفها بنهاية 2026 لصالح مفاتيح `publishable`/`secret`؛ يلزم نقل النظام إليها قبل ذلك (توثيق Supabase: Migrating to the new API keys).

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

من أول دفع إلى `develop` بعدها يطبّق الخط الترحيلات المعلقة بالترتيب، وينشر الدوال، ويضبط أسرارها (`APP_BASE_URL` تلقائيًا = رابط الـstaging). بدون هذه الأسرار تُنشر الواجهة فقط ويظهر تنبيه «Backend not deployed» في ملخص التشغيل.

**ب. يدويًا بدل ذلك** (كما طُبّق 0015): لكل ترحيل جديد انسخ محتوى ملفه من `supabase/migrations` في SQL Editor لمشروع الـstaging وشغّله، ثم سجّله في سجل الترحيلات بطابعه واسمه من اسم الملف، حتى لا يحاول الخط تطبيقه مرة ثانية حين تُضاف أسراره:
```sql
insert into supabase_migrations.schema_migrations (version, name) values ('<الطابع>', '<الاسم>') on conflict (version) do nothing;
```
والدوال المعدَّلة تُنشر من لوحة Edge Functions أو بـ`supabase functions deploy`.

> متغيرات اختيارية (Variables): `STAGING_SUPABASE_URL` و`STAGING_SUPABASE_ANON_KEY` تتجاوز ما في `.env.staging`، و`STAGING_DEFAULT_BRANCH_ID` يثبّت فرع شاشات النزلاء، و`STAGING_APP_BASE_URL` عند ربط نطاق خاص.

## 4. الذكاء الاصطناعي (Gemini)

1. **ألغِ المفتاح الذي أُرسل في المحادثة وأنشئ مفتاحًا جديدًا** (Google AI Studio ← API keys). أي مفتاح كُتب في محادثة أو ملف يُعامل كمكشوف.
2. ضعه في مكان واحد فقط: Supabase ← Edge Functions ← Secrets باسم `GEMINI_API_KEY` — أو سر GitHub `STAGING_GEMINI_API_KEY` إن فعّلت §3. لا يوضع أبدًا في `.env.staging` ولا في أي ملف في المستودع.
3. من `/admin/ai-settings`: فعّل المحرك ← «اختبار الاتصال». النموذج الافتراضي `gemini-3.8-flash` (نماذج 2.x لا تعمل بمفتاح جديد).
4. **النماذج الاحتياطية** (الحقل نفسه في الصفحة، حتى 3 بالترتيب): إن أعاد النموذج الأساسي 503/429/404/500/504 يُجرَّب التالي ضمن المهلة نفسها، ويُؤجَّل النموذج المتعثر لبقية الطلبات حتى لا ينتظره كل نزيل: بالمدة التي تطلبها Google مع خطأ الحصة (بين 5 ثوانٍ و10 دقائق)، وإلا دقيقة إلى دقيقتين. ويُسجَّل حدث `provider_fallback:<النموذج>` في أحداث الحماية. «اختبار الاتصال» يفحص كل نموذج على حدة، ويعرض أيّها يجيب الآن وسبب تعثّر غيره بالعربية.
5. **حدود الخطة المجانية**: مفتاح من مشروع Google بلا فوترة يعمل بحدود منخفضة لكل نموذج (طلبات في الدقيقة وفي اليوم). عندها يظهر في رسالة الخطأ `free tier quota requests/min=…` أو `requests/day=…` مع مدة الانتظار، وتنبّه صفحة الإعدادات إلى ذلك. يكفي للـstaging؛ أما الإنتاج فيحتاج تفعيل الفوترة لمشروع المفتاح.

المفتاح لا يصل إلى المتصفح ولا قاعدة البيانات. عند غيابه أو تجاوز الميزانية أو تعذّر كل النماذج يعمل المسار الحتمي نفسه، ويُسجَّل السبب (`provider_error:*` مع رسالة المزود) في أحداث الحماية.

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
- `tests/staging/live.spec.ts` (متصفح حقيقي): الصفحة الرئيسية تحت المسار الفرعي، المسارات المحمية تحوّل للدخول، **إجابة النزيل تأتي من الـEdge Function نفسها** (HTTP 200 والنص المعروض هو نصها)، ورفض تسليم رمز الصندوق في المحادثة. مصدر كل إجابة يظهر كتنبيه في ملخص التشغيل: `mode=ai` (النموذج) أو `mode=scripted ai_status=…` (المسار الحتمي وسببه).

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
