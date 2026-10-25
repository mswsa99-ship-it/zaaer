# النسخة الاحتياطية — 25 أكتوبر 2026، 08:26 UTC (قبل المرحلة 4)

نسخة من النظام كما هو منشور قبل تطبيق المرحلة 4 (الترحيلين 0036 و0037: الفواتير الجزئية والتلقائية، تعديل الفاتورة، تصحيح السند، قائمة المراجعة، المراقبة) على المشروع الفعلي. منفصلة عن نسخة العمل: الفرع `backup/2026-10-25-0826` لا يُدمج في غيره ولا يُنشر منه شيء، ولا تعمل عليه فحوص CI. النسخة السابقة (قبل المراحل 0–3) في الفرع `backup/2026-10-25` وتبقى كما هي.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `develop` عند `2c58ea1` | الواجهة والدوال والترحيلات كما هي منشورة الآن (المراحل 0–3) |
| قاعدة البيانات | `zaaer-db-2026-10-25-0826.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 63 في `public` (431 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-10-25 08:26 بتوقيت UTC (11:26 بتوقيت الرياض)، في لقطة واحدة متسقة لكل الجداول. كان المشروع عند الترحيلات 0001–0021 و0023–0030 و0032 و0033 و0035 (34 قيدًا في سجل الترحيلات، يطابق `supabase/production-applied.txt`).

**ليس فيها:** حسابات الدخول (auth) ومفاتيح Vault وأسرار الدوال؛ لا تمسّها الترحيلات وتبقى في المشروع. الأعمدة المشفّرة (رموز الصناديق وأرقام الهويات) محفوظة كما هي، وتُقرأ في المشروع نفسه فقط لأن مفاتيحها في Vault. مخطط `zz_first_attempt` القديم فارغ فلم يُنسخ.

**كيف أُخذت:** صُدّرت الصفوف من قاعدة البيانات مشفّرةً هناك (OpenPGP، AES-256، بمفتاح نقل لمرة واحدة) فلم تمرّ نصًا مقروءًا عبر أي أداة، ثم فُكّت محليًا وطوبقت بصمتها مع بصمة الخادم، وبُني منها سكربت الاستعادة. حُذف مفتاح النقل والنص المقروء بعد الحفظ.

## التشفير والمفتاح

الملف مضغوط (gzip) ثم مشفّر بـ AES-256-CBC، والمفتاح مشتق بـ PBKDF2-SHA256 بـ 600,000 تكرار. **المفتاح ليس في المستودع**: هو في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف «مفتاح النسخة الاحتياطية 2026-10-25 0826 (قبل المرحلة 4)» (طوبق بعد رفعه مع المفتاح الذي شفّر الملف). الملف المشفّر وحده لا يكشف شيئًا.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-10-25-0826.sql.gz.enc` (المحفوظ هنا) | `86f88db1daf219567d58bf52c868cc56742767c83adea02a8ee606731b57fe18` |
| `zaaer-db-2026-10-25-0826.sql.gz` (بعد فك التشفير) | `4ebe2855f54b7090e6a848a891c01568934a08dc4d23f48663b3da81fdedfe59` |
| `zaaer-db-2026-10-25-0826.sql` (بعد فك الضغط) | `f511a4e364496d21ff79cac9f322fb97967c31ad03ffa7f04ca97eee61307e4f` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-10-25-0826.sql.gz.enc -out zaaer-db-2026-10-25-0826.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-10-25-0826.sql.gz
sha256sum zaaer-db-2026-10-25-0826.sql     # يجب أن يطابق الجدول أعلاه
```

الملف الناتج سكربت SQL واحد يعمل في معاملة واحدة: **يستبدل** صفوف الجداول الـ 63 بصفوف النسخة. يتحقق أولًا أن قاعدة الهدف عند الترحيلات نفسها (القيود الـ 34) ويتوقف دون أي تغيير إن اختلفت. يُشغَّل في SQL Editor أو بـ `psql -v ON_ERROR_STOP=1 -f`. بعد تطبيق 0036 و0037 على المشروع لا يُستعاد إليه مباشرة: الاستعادة الكاملة تكون إلى مشروع جديد يُبنى بالترحيلات الـ 34 ثم يُشغَّل السكربت فيه، والكود يرجع بنشر `2c58ea1`.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بُنيت من الترحيلات نفسها، ثم استُعيدت إليها النسخة: الجداول الـ 63 مطابقة للأصل، عدد الصفوف وبصمة كل جدول (أدناه).
- **رفض الهدف المختلف:** قاعدة بلا سجل ترحيلات، وأخرى بسجل فيه ترحيل زائد، رفضتا الاستعادة ولم يتغير فيهما شيء.
- **بروفة المرحلة 4 على البيانات الحقيقية:** طُبّق 0036 ثم 0037 على النسخة المستعادة دون أي خطأ. لقطة قبل/بعد (عدد صفوف كل جدول، مجاميع المال حسب النوع والحالة، الحجوزات ومراجعها، التخصيصات): لم يتغير شيء في 72 قيمة من 72؛ الجديد جدول `monitor_runs` وحده. سطور الضريبة الأربعة في الإقامات المنقولة بـ 0007 («(ترحيل)») رُبطت كلٌّ بسطر إيجارها، ولا فواتير قائمة يُعاد ترتيبها. وتشغيل الفحوص السبعة على هذه البيانات لم يجد شيئًا.

## الجداول: عدد الصفوف والبصمة

البصمة: `md5` لصفوف الجدول (`to_jsonb(row)::text` مرتبةً، بفاصل `|`، والمنطقة الزمنية UTC). «empty» جدول بلا صفوف.

| الجدول | الصفوف | البصمة |
| --- | ---: | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 1 | `9010d47ab7580d0b09527a291dc3fd81` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 30 | `3ad07f1d3ecdd47d0121e9bedd586b52` |
| `ai_ops_conversations` | 1 | `685a74a7809d5d3f682c8f620615d9c7` |
| `ai_ops_messages` | 2 | `40f946fa387f0a732bcfd42de0bfde69` |
| `ai_settings` | 1 | `294138572fd36c762edd4db58a4cd990` |
| `ai_tool_executions` | 9 | `7602c0766f5eeb3073699ef6c0373612` |
| `ai_usage_daily` | 4 | `bbdcc492e5caece1d40309a11c2846a4` |
| `audit_events` | 7 | `645ee34e93e2c86c3d2d040c53f33419` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 2 | `3551d77f91b5f9a6abc49860f895d26c` |
| `branch_memberships` | 0 | `empty` |
| `branch_whatsapp_channels` | 0 | `empty` |
| `branches` | 1 | `a352fba6919761af9cdfaeadac1457b2` |
| `cash_accounts` | 2 | `fb3a13e03bcb4b2c1818b59c4a16af4f` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 0 | `empty` |
| `code_rotation_events` | 0 | `empty` |
| `conversation_messages` | 162 | `41c8911006819881d7649c2ee7e5e10a` |
| `conversations` | 79 | `58f64c233513946ab6a913903af32ab3` |
| `document_sequences` | 1 | `3905c429cbc066592c1ce2d47c14671d` |
| `facilities` | 2 | `a1454c52a4a87e13a024367dffd1424f` |
| `financial_vouchers` | 1 | `85d67caf090d888634bd0f90eb5652c7` |
| `floors` | 2 | `aa1798b4855f65793795456a181beae8` |
| `guest_lookup_attempts` | 1 | `55a0799355bb9b93f67871c6a1e09512` |
| `guest_phone_challenges` | 0 | `empty` |
| `guest_phone_sessions` | 0 | `empty` |
| `guest_profiles` | 4 | `82aa1cf3169cb43e3ad174d693b3120b` |
| `housekeeping_tasks` | 0 | `empty` |
| `human_handoff_tickets` | 1 | `8ac028f3e9ac397b9b8ece1d3004596e` |
| `integration_events` | 0 | `empty` |
| `inventory_periods` | 28 | `70e5c7a8eaf1633f74b83aa8d9569a07` |
| `invoices` | 0 | `empty` |
| `keyboxes` | 10 | `c354efa76b282680caf732a69d2c154e` |
| `knowledge_entries` | 10 | `d66598ccc1ae2d0579f3e9ba203b6476` |
| `maintenance_tickets` | 0 | `empty` |
| `notifications` | 1 | `d205042de8f0cdd8697c5839b5a2041c` |
| `organizations` | 1 | `d7d222391590b3427bdf964c36ef7d84` |
| `payment_transactions` | 1 | `516176dab503c0a2cbdb790cc6b42957` |
| `platform_payouts` | 0 | `empty` |
| `pos_settlements` | 0 | `empty` |
| `property_policies` | 7 | `5bd8e62169fefca310701e2cc210f856` |
| `rate_calendar` | 0 | `empty` |
| `registration_sessions` | 0 | `empty` |
| `release_rules` | 2 | `409b07f8f53f2c7ee6c8a153b773cb17` |
| `released_slots` | 14 | `125a547ee9c949cf4b40f07e920a84dd` |
| `reservation_allocations` | 2 | `9dda7d9e571aacb68ad43c79d01c1522` |
| `reservation_charges` | 8 | `8067741af7d05aa86ad20bb5ddf10bad` |
| `reservation_guests` | 5 | `38bbff18dd18d857719181ea56da5b33` |
| `reservation_nights` | 7 | `4ad5179a52876dc8112bec9db12d2df7` |
| `reservations` | 4 | `83486eac764b0233c1d6f7d50833ac15` |
| `review_items` | 0 | `empty` |
| `room_categories` | 2 | `3e4090608419943b10f7bf6ea983a7e1` |
| `rooms` | 10 | `1ca2ddefa58aaaacd7eabbc03a184cbb` |
| `service_definitions` | 0 | `empty` |
| `staff_profiles` | 1 | `f5d0f0d19829af2ae4740319996e8a62` |
| `stay_payment_exceptions` | 0 | `empty` |
| `system_settings` | 1 | `413e33a99b9e1f4227944452dfb95f6b` |
| `task_types` | 3 | `acc07e3fbc3bd89855129bd3bad74780` |
| `unanswered_questions` | 0 | `empty` |
| `whatsapp_inbound_messages` | 0 | `empty` |
| `whatsapp_outbox` | 0 | `empty` |
