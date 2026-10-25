# النسخة الاحتياطية — 25 أكتوبر 2026

نسخة من النظام كما كان منشورًا قبل تطبيق المراحل 0–3 (الترحيلات 0026–0034) على المشروع الفعلي. هي منفصلة عن نسخة العمل: الفرع `backup/2026-10-25` لا يُدمج في غيره ولا يُنشر منه شيء، ولا تعمل عليه فحوص CI.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `develop` عند `c2b16d8` | الواجهة والدوال والترحيلات كما هي منشورة الآن |
| قاعدة البيانات | `zaaer-db-2026-10-25.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 54 في `public` (397 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-10-25 06:20 بتوقيت UTC (09:20 بتوقيت الرياض). كان المشروع عند الترحيلات 0001–0021 و0023–0025 (26 قيدًا في سجل الترحيلات).

**ليس فيها:** حسابات الدخول (auth) ومفاتيح Vault وأسرار الدوال؛ لا تمسّها الترحيلات وتبقى في المشروع. الأعمدة المشفّرة (رموز الصناديق وأرقام الهويات) محفوظة كما هي، وتُقرأ في المشروع نفسه فقط لأن مفاتيحها في Vault. مخطط `zz_first_attempt` القديم فارغ (24 جدولًا بلا صفوف) فلم يُنسخ.

## التشفير والمفتاح

الملف مضغوط (gzip) ثم مشفّر بـ AES-256-CBC، والمفتاح مشتق بـ PBKDF2-SHA256 بـ 600,000 تكرار. **المفتاح ليس في المستودع**: هو في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف «مفتاح النسخة الاحتياطية 2026-10-25». الملف المشفّر وحده لا يكشف شيئًا.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-10-25.sql.gz.enc` (المحفوظ هنا) | `b570137d1fbf8003c3789c72f60993255836c6b1f780f2584255c11873878aad` |
| `zaaer-db-2026-10-25.sql.gz` (بعد فك التشفير) | `8280b5a5dc8103f2e588d646a859aabc6cfa2fec09b214eca41ff23972c81c57` |
| `zaaer-db-2026-10-25.sql` (بعد فك الضغط) | `f054016c3f5adbcfaf33d69f916dd35dbba7f40a0107d3ffd8b7fd31555af48a` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-10-25.sql.gz.enc -out zaaer-db-2026-10-25.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-10-25.sql.gz
sha256sum zaaer-db-2026-10-25.sql     # يجب أن يطابق الجدول أعلاه
```

الملف الناتج سكربت SQL واحد يعمل في معاملة واحدة: **يستبدل** صفوف الجداول الـ 54 بصفوف النسخة. يتحقق أولًا أن قاعدة الهدف عند الترحيلات نفسها (القيود الـ 26) ويتوقف دون أي تغيير إن اختلفت. يُشغَّل في SQL Editor أو بـ `psql -v ON_ERROR_STOP=1 -f`. بعد تطبيق 0026 وما بعدها على المشروع لا يُستعاد إليه مباشرة: الاستعادة الكاملة تكون إلى مشروع جديد يُبنى بالترحيلات 0001–0021 و0023–0025 ثم يُشغَّل السكربت فيه، والكود يرجع بنشر `c2b16d8`.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بُنيت من الترحيلات نفسها، ثم استُعيدت إليها النسخة: الجداول الـ 54 مطابقة للأصل، عدد الصفوف وبصمة كل جدول (أدناه).
- **رفض الهدف المختلف:** قاعدة بلا سجل ترحيلات، وأخرى بسجل مختلف، رفضتا الاستعادة ولم يتغير فيهما شيء.
- **بروفة الترحيلات المعلّقة على البيانات الحقيقية:** طُبّقت 0022 و0026–0034 بالترتيب على النسخة المستعادة دون أي خطأ. التغيير الوحيد في لقطة قبل/بعد: `audit_events` من 4 إلى 7، وهي قيود 0028 للصندوق والحساب الأوليين وإعدادات الضريبة والتأمين للفرع (مشروحة في `supabase/migration-exceptions.txt`). الحجوزات والسندات والتخصيصات والمبالغ لم تتغير.

البصمة: `md5` لصفوف الجدول مرتبةً (`string_agg(to_jsonb(row)::text, '|' order by to_jsonb(row)::text)`) بتوقيت UTC، محسوبة في المشروع وفي القاعدة المستعادة.

| الجدول | الصفوف | البصمة (md5) |
| --- | ---: | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 1 | `9010d47ab7580d0b09527a291dc3fd81` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 27 | `88f1df3fa69edb9b0bbd7334bea5bc1b` |
| `ai_ops_conversations` | 1 | `685a74a7809d5d3f682c8f620615d9c7` |
| `ai_ops_messages` | 2 | `40f946fa387f0a732bcfd42de0bfde69` |
| `ai_settings` | 1 | `294138572fd36c762edd4db58a4cd990` |
| `ai_tool_executions` | 9 | `7602c0766f5eeb3073699ef6c0373612` |
| `ai_usage_daily` | 3 | `68f49fa8f09e4fa4dbea584583fdc7b4` |
| `audit_events` | 4 | `531edd37febf7a80790d13011b167bf6` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 2 | `3551d77f91b5f9a6abc49860f895d26c` |
| `branch_memberships` | 0 | `empty` |
| `branch_whatsapp_channels` | 0 | `empty` |
| `branches` | 1 | `5fe27e050a555a441c69cfb10c1af2ae` |
| `code_rotation_events` | 0 | `empty` |
| `conversation_messages` | 150 | `59c42c5701e93263566db27a1421282f` |
| `conversations` | 73 | `e72e51ece86fc6131e1e9715d79a21b8` |
| `document_sequences` | 1 | `3905c429cbc066592c1ce2d47c14671d` |
| `facilities` | 2 | `a1454c52a4a87e13a024367dffd1424f` |
| `financial_vouchers` | 1 | `155c99bbe6c7fd17ff53881a127bb3d6` |
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
| `property_policies` | 7 | `5bd8e62169fefca310701e2cc210f856` |
| `registration_sessions` | 0 | `empty` |
| `release_rules` | 2 | `409b07f8f53f2c7ee6c8a153b773cb17` |
| `released_slots` | 14 | `125a547ee9c949cf4b40f07e920a84dd` |
| `reservation_allocations` | 2 | `9dda7d9e571aacb68ad43c79d01c1522` |
| `reservation_charges` | 8 | `d37da0fae4f19c3d90b6b15c9893d68c` |
| `reservation_guests` | 5 | `38bbff18dd18d857719181ea56da5b33` |
| `reservations` | 4 | `13eb8dfa11ae42190cc7d527ac077222` |
| `room_categories` | 2 | `e59133542f5118d7f42123be3f1809d1` |
| `rooms` | 10 | `1ca2ddefa58aaaacd7eabbc03a184cbb` |
| `service_definitions` | 0 | `empty` |
| `staff_profiles` | 1 | `f5d0f0d19829af2ae4740319996e8a62` |
| `system_settings` | 1 | `413e33a99b9e1f4227944452dfb95f6b` |
| `task_types` | 3 | `acc07e3fbc3bd89855129bd3bad74780` |
| `unanswered_questions` | 0 | `empty` |
| `whatsapp_inbound_messages` | 0 | `empty` |
| `whatsapp_outbox` | 0 | `empty` |
