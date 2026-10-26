# النسخة الاحتياطية — 26 أكتوبر 2026، 10:45 UTC (قبل إغلاق الدوال الداخلية أمام الزوار)

نسخة من النظام كما هو منشور قبل الترحيل 0045 على المشروع الفعلي: زائر بلا حساب لا يستدعي إلا الدوال الأربع عشرة لصفحات الضيف، ولا يتغير شيء لموظف مسجّل ولا للدوال على الخادم ولا في البيانات. منفصلة عن نسخة العمل: الفرع `backup/2026-10-26-1045` لا يُدمج في غيره ولا يُنشر منه شيء، ولا تعمل عليه فحوص CI. النسخ السابقة تبقى كما هي.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `develop` عند `f2dc806` | الواجهة والدوال والترحيلات كما هي منشورة الآن (حتى 0044: مصفوفة الصلاحيات ولصقة المالك) |
| قاعدة البيانات | `zaaer-db-2026-10-26-1045.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 70 في `public` (542 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-10-26 10:45 بتوقيت UTC (13:45 بتوقيت الرياض)، في لقطة واحدة متسقة لكل الجداول. كان المشروع عند الترحيلات 0001–0044 كلها (46 قيدًا في سجل الترحيلات، يطابق `supabase/production-applied.txt`).

**ليس فيها:** حسابات الدخول (auth) ومفاتيح Vault وأسرار الدوال؛ لا تمسّها الترحيلات وتبقى في المشروع. الأعمدة المشفّرة محفوظة كما هي وتُقرأ في المشروع نفسه فقط.

**كيف أُخذت:** صُدّرت الصفوف من قاعدة البيانات مشفّرةً هناك (OpenPGP، AES-256، بمفتاح نقل عام لمرة واحدة لم يغادر مفتاحه الخاص جهاز العمل؛ الاستعلام يقرأ الجداول كلها بلقطة واحدة عبر دالة مؤقتة للجلسة تزول بانتهائها)، ثم فُكّت محليًا وطوبقت بصمة كل جدول مع بصمة الخادم، وبُني منها سكربت الاستعادة. حُذف مفتاح النقل والنص المقروء بعد الحفظ.

## التشفير والمفتاح

الملف مضغوط (gzip) ثم مشفّر بـ AES-256-CBC، والمفتاح مشتق بـ PBKDF2-SHA256 بـ 600,000 تكرار. **المفتاح ليس في المستودع**: هو في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف «مفتاح النسخة الاحتياطية 2026-10-26 1045 (قبل إغلاق الدوال للزوار)» (فُك به الملف بعد رفعه وطابقت البصمة).

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-10-26-1045.sql.gz.enc` (المحفوظ هنا) | `2cd44e975f4f85417b0601f6b316c609afa0de0be8df302f2802e908e8ece781` |
| `zaaer-db-2026-10-26-1045.sql.gz` (بعد فك التشفير) | `cfb5efabfc08e358a7393b887d8d8665f08456c7e9e42f7a8565f0b34d6610f1` |
| `zaaer-db-2026-10-26-1045.sql` (بعد فك الضغط) | `e27bb19b764113172bd298bc2f024340d4e6d79b75fbc080f5f4b0ae677ad67f` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-10-26-1045.sql.gz.enc -out zaaer-db-2026-10-26-1045.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-10-26-1045.sql.gz
sha256sum zaaer-db-2026-10-26-1045.sql     # يجب أن يطابق الجدول أعلاه
```

سكربت SQL واحد في معاملة واحدة **يستبدل** صفوف الجداول الـ 70 بصفوف النسخة، بعد أن يتحقق أن قاعدة الهدف عند الترحيلات نفسها (الـ 46) ويتوقف دون تغيير إن اختلفت. بعد تطبيق 0045 يبقى المخطط نفسه في الجداول (0045 يغيّر صلاحيات الدوال فقط)، لكن السكربت يطلب سجل الترحيلات نفسه (46)؛ الاستعادة الكاملة إلى مشروع جديد بالترحيلات الـ 46، والكود يرجع بنشر `f2dc806`.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة من الترحيلات نفسها (46) استعادت النسخة: الجداول الـ 70 مطابقة للأصل، عدد الصفوف وبصمة كل جدول.
- **بروفة التطبيق على البيانات الحقيقية:** على النسخة المستعادة طُبّق 0045 كما سيُطبَّق: بصمة كل جدول بعده مطابقة لما قبله (لا تغيير في البيانات)، والدوال التي يستدعيها زائر بلا حساب 14 بالضبط (دوال صفحات الضيف)، ودوال الموظف المسجّل 393 قبله وبعده، ودالة للموظفين يرفضها الزائر «permission denied» قبل أن تعمل، وبحث الضيف ومعلومات الفرع يعملان للزائر.

## الجداول: عدد الصفوف والبصمة

البصمة: `md5` لصفوف الجدول (`to_jsonb(row)::text` مرتبةً، بفاصل `|`، والمنطقة الزمنية UTC). «empty» جدول بلا صفوف.

| الجدول | الصفوف | البصمة |
| --- | ---: | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 1 | `9010d47ab7580d0b09527a291dc3fd81` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 38 | `aeda93e8bcf8662b9c3f23876177130c` |
| `ai_ops_conversations` | 1 | `685a74a7809d5d3f682c8f620615d9c7` |
| `ai_ops_messages` | 2 | `40f946fa387f0a732bcfd42de0bfde69` |
| `ai_settings` | 1 | `294138572fd36c762edd4db58a4cd990` |
| `ai_tool_executions` | 9 | `7602c0766f5eeb3073699ef6c0373612` |
| `ai_usage_daily` | 5 | `87c0597c55865f3be2a519ec9108d451` |
| `audit_events` | 8 | `4fb91b8c38025077e96702f1baf33b1f` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 12 | `82974a8c33093b5c018cdf683343250a` |
| `branch_media` | 0 | `empty` |
| `branch_memberships` | 0 | `empty` |
| `branch_whatsapp_channels` | 0 | `empty` |
| `branches` | 1 | `a15cf7f37aa2886d9371dc8ce3da3acf` |
| `cash_accounts` | 2 | `fb3a13e03bcb4b2c1818b59c4a16af4f` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 0 | `empty` |
| `code_rotation_events` | 0 | `empty` |
| `conversation_messages` | 222 | `c3f81f11feed58227795a614f0698712` |
| `conversations` | 109 | `e50bafb1f6abef70ddfe97f7e89dcccf` |
| `data_purge_requests` | 0 | `empty` |
| `document_sequences` | 1 | `3905c429cbc066592c1ce2d47c14671d` |
| `facilities` | 2 | `a1454c52a4a87e13a024367dffd1424f` |
| `financial_vouchers` | 1 | `85d67caf090d888634bd0f90eb5652c7` |
| `floors` | 2 | `aa1798b4855f65793795456a181beae8` |
| `guest_bans` | 0 | `empty` |
| `guest_lookup_attempts` | 1 | `55a0799355bb9b93f67871c6a1e09512` |
| `guest_phone_challenges` | 0 | `empty` |
| `guest_phone_sessions` | 0 | `empty` |
| `guest_profiles` | 4 | `808c4db8c5e3f8d49631a48b2475dd94` |
| `housekeeping_tasks` | 0 | `empty` |
| `human_handoff_tickets` | 1 | `8ac028f3e9ac397b9b8ece1d3004596e` |
| `integration_events` | 0 | `empty` |
| `inventory_periods` | 28 | `70e5c7a8eaf1633f74b83aa8d9569a07` |
| `invoices` | 0 | `empty` |
| `keyboxes` | 10 | `c354efa76b282680caf732a69d2c154e` |
| `knowledge_entries` | 10 | `d66598ccc1ae2d0579f3e9ba203b6476` |
| `maintenance_tickets` | 0 | `empty` |
| `monitor_runs` | 1 | `a2f0eab9a15dea502054fb0d5bddce24` |
| `notifications` | 1 | `d205042de8f0cdd8697c5839b5a2041c` |
| `organizations` | 1 | `6165fbcb4de2379de1ad27cb71f1d5e9` |
| `payment_transactions` | 1 | `516176dab503c0a2cbdb790cc6b42957` |
| `platform_payouts` | 0 | `empty` |
| `pos_settlements` | 0 | `empty` |
| `property_policies` | 7 | `5bd8e62169fefca310701e2cc210f856` |
| `rate_calendar` | 0 | `empty` |
| `registration_sessions` | 0 | `empty` |
| `release_rules` | 2 | `409b07f8f53f2c7ee6c8a153b773cb17` |
| `released_slots` | 14 | `125a547ee9c949cf4b40f07e920a84dd` |
| `reservation_allocations` | 2 | `9dda7d9e571aacb68ad43c79d01c1522` |
| `reservation_charges` | 8 | `d9d945d56bd31e4ffe16c69f945fc8e6` |
| `reservation_guests` | 5 | `9d0d1bf4f6c692e26f78d4e72f8ba912` |
| `reservation_nights` | 7 | `4ad5179a52876dc8112bec9db12d2df7` |
| `reservations` | 4 | `be41a1109feb34a4c37a0472074dd4cd` |
| `review_items` | 0 | `empty` |
| `role_permissions` | 0 | `empty` |
| `room_categories` | 2 | `3e4090608419943b10f7bf6ea983a7e1` |
| `rooms` | 10 | `1ca2ddefa58aaaacd7eabbc03a184cbb` |
| `service_definitions` | 0 | `empty` |
| `staff_profiles` | 1 | `9c647393ee0dd1b390cb6ec6ad9034d4` |
| `staff_saved_views` | 0 | `empty` |
| `stay_acknowledgements` | 0 | `empty` |
| `stay_payment_exceptions` | 0 | `empty` |
| `system_settings` | 1 | `413e33a99b9e1f4227944452dfb95f6b` |
| `task_types` | 3 | `acc07e3fbc3bd89855129bd3bad74780` |
| `unanswered_questions` | 0 | `empty` |
| `whatsapp_inbound_messages` | 0 | `empty` |
| `whatsapp_outbox` | 0 | `empty` |
