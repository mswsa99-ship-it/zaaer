# النسخة الاحتياطية — 30 أكتوبر 2026، 22:36 UTC (بعد استيراد زائر، قبل الترحيل 0049)

نسخة من النظام بعد استيراد بيانات زائر (الهيكل و2,452 ملف ضيف) وقبل تطبيق الترحيل 0049 (سرعة قائمة النزلاء وعلامة «يحتاج استكمال»). الفرع `backup/2026-10-30-2236` لا يُدمج ولا يُنشر منه شيء.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `develop` عند `958947e` | الواجهة والدوال والترحيلات كما هي منشورة الآن |
| قاعدة البيانات | `zaaer-db-2026-10-30-2236.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 70 في `public` (2,706 صفوف) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-10-30 22:36 UTC (01:36 بتوقيت الرياض، 31 أكتوبر)، في لقطة واحدة متسقة. كان المشروع عند 50 قيدًا في سجل الترحيلات، آخرها `20261030020000` (0048).

**ليس فيها:** حسابات الدخول (auth) ومفاتيح Vault وأسرار الدوال. الأعمدة المشفّرة (رموز الصناديق وأرقام الهويات) محفوظة كما هي وتُقرأ في المشروع نفسه فقط. فيها بيانات شخصية للضيوف، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف من قاعدة البيانات مشفّرةً هناك (OpenPGP، AES-256، بمفتاح نقل لمرة واحدة)، ثم فُكّت محليًا وطوبقت بصمتها (md5) مع بصمة الخادم، وبُني منها سكربت الاستعادة. حُذف مفتاح النقل والنص المقروء بعد الحفظ.

## التشفير والمفتاح

الملف مضغوط (gzip) ثم مشفّر بـ AES-256-CBC، والمفتاح مشتق بـ PBKDF2-SHA256 بـ 600,000 تكرار. **المفتاح ليس في المستودع**: هو في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-10-30-2236.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-10-30-2236.sql.gz.enc` | `d557bcb5db0fc5d7ab037d8840a4bd818da5c52fefa0f9ba5d37b336f35d0999` |
| `zaaer-db-2026-10-30-2236.sql.gz` | `9b637d1f5a0f883c13d11a7812f7243a40e24905d69b0a038ee59e4dfdd1fb93` |
| `zaaer-db-2026-10-30-2236.sql` | `b39f4c0351fc6f102b5ae6c03747b9fd483c2e16cafc195047a5c831c70818b7` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-10-30-2236.sql.gz.enc -out zaaer-db-2026-10-30-2236.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-10-30-2236.sql.gz
sha256sum zaaer-db-2026-10-30-2236.sql     # يطابق الجدول أعلاه
```

السكربت يعمل في معاملة واحدة ويستبدل صفوف الجداول بصفوف النسخة، ويتوقف دون تغيير إن اختلف سجل ترحيلات الهدف عن الـ50.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بُنيت من الترحيلات الـ50، ثم استُعيدت إليها النسخة: الجداول الـ70 مطابقة للأصل في عدد الصفوف وبصمة كل جدول (2,706 صفوف).
- **فك التشفير ذهابًا وإيابًا:** الملف المشفّر فُكّ وطابقت بصمته بصمة السكربت.

## الجداول

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 6 | `6c16f2f0f0065db5aa491aaf772a4d75` |
| `ai_ops_conversations` | 1 | `dc5628fa262a3748939f0da5596646d4` |
| `ai_ops_messages` | 2 | `5ef175f2c0b963bcea787c985774f161` |
| `ai_settings` | 1 | `294138572fd36c762edd4db58a4cd990` |
| `ai_tool_executions` | 0 | `empty` |
| `ai_usage_daily` | 1 | `994193221172cc4c223fe7898e422c79` |
| `audit_events` | 41 | `8679e79c903d399557e073336f6187ea` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 12 | `82974a8c33093b5c018cdf683343250a` |
| `branch_media` | 0 | `empty` |
| `branch_memberships` | 2 | `9d1141b80fa241a2f00220ca22a01d05` |
| `branch_whatsapp_channels` | 1 | `35f77f5a0937253e81786497c91415d3` |
| `branches` | 3 | `22057b9b82f21ae1efb05d0ee258ab9e` |
| `cash_accounts` | 6 | `283eeb5574c9782cf6d1b05f2a7eebc7` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 13 | `b23fe5a71d98ea95599c8e2741caaeea` |
| `code_rotation_events` | 3 | `9ac37ba1f7c6a9c508787f2a9427165c` |
| `conversation_messages` | 24 | `63e64cb7c4e8622520b941efa1bcef6e` |
| `conversations` | 12 | `4e9088753e30e00c1daf15921c9a53d8` |
| `data_purge_requests` | 2 | `566ea0feae2ac75f69f4d3d814421437` |
| `document_sequences` | 2 | `793b76b1b311cdd6b5c4fdfcb6ba86a0` |
| `facilities` | 2 | `a1454c52a4a87e13a024367dffd1424f` |
| `financial_vouchers` | 0 | `empty` |
| `floors` | 2 | `aa1798b4855f65793795456a181beae8` |
| `guest_bans` | 0 | `empty` |
| `guest_lookup_attempts` | 0 | `empty` |
| `guest_phone_challenges` | 0 | `empty` |
| `guest_phone_sessions` | 0 | `empty` |
| `guest_profiles` | 2452 | `e2f98894c3ff52e354bd022e88e7def5` |
| `housekeeping_tasks` | 2 | `6146f26355513e97fe39fd0c686ba0f3` |
| `human_handoff_tickets` | 0 | `empty` |
| `integration_events` | 0 | `empty` |
| `inventory_periods` | 28 | `70e5c7a8eaf1633f74b83aa8d9569a07` |
| `invoices` | 0 | `empty` |
| `keyboxes` | 10 | `138f977020de59b1b3023b9a8eaadaa9` |
| `knowledge_entries` | 10 | `d66598ccc1ae2d0579f3e9ba203b6476` |
| `maintenance_tickets` | 0 | `empty` |
| `monitor_runs` | 3 | `8ef732ae29e2972a9fd02e37d91d7e2e` |
| `notifications` | 0 | `empty` |
| `organizations` | 1 | `6165fbcb4de2379de1ad27cb71f1d5e9` |
| `payment_transactions` | 0 | `empty` |
| `platform_payouts` | 0 | `empty` |
| `pos_settlements` | 0 | `empty` |
| `property_policies` | 7 | `5bd8e62169fefca310701e2cc210f856` |
| `rate_calendar` | 0 | `empty` |
| `registration_sessions` | 0 | `empty` |
| `release_rules` | 2 | `409b07f8f53f2c7ee6c8a153b773cb17` |
| `released_slots` | 5 | `adbb2db91bdb8ce532d233f55353d227` |
| `reservation_allocations` | 0 | `empty` |
| `reservation_charges` | 0 | `empty` |
| `reservation_guests` | 0 | `empty` |
| `reservation_nights` | 0 | `empty` |
| `reservations` | 0 | `empty` |
| `review_items` | 0 | `empty` |
| `role_permissions` | 0 | `empty` |
| `room_categories` | 5 | `a07298d89d832b9f09dd5d4e4df42500` |
| `rooms` | 34 | `17b5213c710dd7d4a85805576b62d17d` |
| `service_definitions` | 1 | `f4bef283947689922b413f304ac63406` |
| `staff_profiles` | 3 | `92c2c9d1dd735746aa24c4de9057bc91` |
| `staff_saved_views` | 0 | `empty` |
| `stay_acknowledgements` | 0 | `empty` |
| `stay_payment_exceptions` | 0 | `empty` |
| `system_settings` | 1 | `413e33a99b9e1f4227944452dfb95f6b` |
| `task_types` | 5 | `484db08f1fe3adfbd9d8132360fa4c09` |
| `unanswered_questions` | 0 | `empty` |
| `whatsapp_inbound_messages` | 0 | `empty` |
| `whatsapp_outbox` | 0 | `empty` |
