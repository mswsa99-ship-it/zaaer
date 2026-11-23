# النسخة الاحتياطية — 23 نوفمبر 2026، 06:50 UTC (بعد مسح بيانات البناء، قبل ترحيل 0074)

نسخة كاملة من بيانات النظام بعد أن لصق المالك ملف مسح بيانات البناء (الحجوزات والنزلاء والمال)، وقبل تطبيق ترحيل الحسابات 0074 وقبل إزالة فرع الرياض التجريبي.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `5daaaca` (المنشور على `develop` وقت النسخة) | الواجهة والدوال والترحيلات حتى 0073 |
| قاعدة البيانات | `zaaer-db-2026-11-23-0650.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 100 في `public` (342 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-11-23 06:50:25 UTC (09:50 بتوقيت الرياض). كان المشروع عند 74 قيدًا في سجل الترحيلات، آخرها `20261115120000`.

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها أسماء الموظفين وبريدهم وإعدادات الفروع، لذلك لا تُحفظ إلا مشفّرة. لا بيانات نزلاء فيها (مُسحت قبلها).

**كيف أُخذت:** صُدّرت الصفوف من القاعدة في معاملة واحدة (Repeatable Read) مشفّرةً بمفتاح عام لمرة واحدة؛ المفتاح الخاص لم يغادر بيئة العمل وأُتلف بعد فك التشفير. ومن نص JSON كما صدر بُني سكربت الاستعادة (دون إعادة صياغة الأرقام)، وفي المعاملة نفسها أُخذت بصمة كل جدول.

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-11-23-0650.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-11-23-0650.sql.gz.enc` | `7b0d800165b3d9f30d016a256b31087c3b255644108c05475541c6c491b8119d` |
| `zaaer-db-2026-11-23-0650.sql.gz` | `b1b2fc2c51925d9910f8b0d2220d4fd5e4ba80ef264f054b3d73b1808e46910f` |
| `zaaer-db-2026-11-23-0650.sql` | `1bc16cb91c5f820263412d85bdcb7d4ff5b4d44137225231f647024645f97db9` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-11-23-0650.sql.gz.enc -out zaaer-db-2026-11-23-0650.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-11-23-0650.sql.gz
sha256sum zaaer-db-2026-11-23-0650.sql     # يطابق الجدول أعلاه
psql "$DB_URL" -v ON_ERROR_STOP=1 -f zaaer-db-2026-11-23-0650.sql
```

السكربت معاملة واحدة: يرفض العمل دون أي تغيير إن اختلفت أعمدة جداول `public` في الهدف عن أعمدة وقت النسخة (بصمة الأعمدة `baa9db8ff0de8a479b4acad71f35a4db`)، ثم يفرّغ الجداول المئة ويعيد صفوفها كما كانت. ترحيل 0074 لا يضيف أعمدة، فالنسخة تُستعاد بعده كما تُستعاد قبله.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة محلية جديدة بالترحيلات الـ74 استقبلت النسخة: الجداول الـ100 مطابقة للإنتاج عددًا وبصمة (342 صفًا).
- **الرفض:** على قاعدة أعمدتها مختلفة رفض السكربت العمل ولم يتغير فيها شيء.
- **الترحيل المعلّق على النسخة المستعادة:** طُبّق 0074 عليها مرتين؛ نجح، والثانية لم تغيّر شيئًا.
- **فك التشفير ذهابًا وإيابًا:** طابق الملف المضغوط بايتًا ببايت.

## الجداول

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `accounting_periods` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 1 | `0a425a6aa66087e8f41cd68fdbe4a04d` |
| `ai_ops_conversations` | 0 | `empty` |
| `ai_ops_messages` | 0 | `empty` |
| `ai_settings` | 1 | `998f096b050ce755f1078f23ef078aec` |
| `ai_tool_executions` | 0 | `empty` |
| `ai_usage_daily` | 1 | `821fefdab8abbcdfea89ebe3d971ec07` |
| `alert_events` | 0 | `empty` |
| `alert_rules` | 8 | `b5016bcfd663a3051950d3e20a63a174` |
| `audit_events` | 64 | `2526ed6480a9560281da4f0cf4a6bcdd` |
| `bank_mail_settings` | 0 | `empty` |
| `bank_match_items` | 0 | `empty` |
| `bank_matches` | 0 | `empty` |
| `bank_messages` | 0 | `empty` |
| `bank_movements` | 0 | `empty` |
| `bank_parse_rules` | 25 | `e027690af3c56e3903b7c19a45d9a106` |
| `blocks` | 1 | `04d81379c65914eac980c67dcba68966` |
| `booking_sources` | 12 | `de60dedc790ad3fee9dce6d26302b3ad` |
| `branch_journey_settings` | 3 | `b5397658861a15e219433eca9deaee74` |
| `branch_media` | 0 | `empty` |
| `branch_media_items` | 0 | `empty` |
| `branch_memberships` | 2 | `90fe02ec42f62d1da31cd9526eda5e0d` |
| `branch_payment_settings` | 0 | `empty` |
| `branch_whatsapp_channels` | 3 | `ddaf3bf3f672d9681a9cf664ad640953` |
| `branches` | 3 | `02c99b4607599989dbf85f4562d11ad9` |
| `cash_accounts` | 6 | `2f6c54c8c07d4500a344278e203b7238` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 0 | `empty` |
| `code_rotation_events` | 0 | `empty` |
| `conversation_messages` | 0 | `empty` |
| `conversations` | 0 | `empty` |
| `data_purge_requests` | 0 | `empty` |
| `day_closing_lines` | 0 | `empty` |
| `day_closing_requests` | 0 | `empty` |
| `day_closings` | 0 | `empty` |
| `document_sequences` | 4 | `533d9e228ff642c7f6540d4ca66cb251` |
| `expense_attachments` | 0 | `empty` |
| `expense_categories` | 12 | `c8bf8eff221c4f473ab14b1da953ac16` |
| `expense_vouchers` | 0 | `empty` |
| `facilities` | 2 | `61f5da8eeb1ed2ed38c74fd435f732d3` |
| `financial_vouchers` | 0 | `empty` |
| `floors` | 2 | `dff7a8efbf7f2b5d74a7f8cc80c61c5a` |
| `gl_accounts` | 31 | `4d3de7c047b61c6add8ebdb1fc0c7c87` |
| `guest_bans` | 0 | `empty` |
| `guest_lookup_attempts` | 0 | `empty` |
| `guest_phone_challenges` | 0 | `empty` |
| `guest_phone_sessions` | 0 | `empty` |
| `guest_profiles` | 0 | `empty` |
| `guest_reviews` | 0 | `empty` |
| `housekeeping_tasks` | 0 | `empty` |
| `human_handoff_tickets` | 0 | `empty` |
| `integration_events` | 0 | `empty` |
| `inventory_periods` | 28 | `867e83c2ce30714d45c3f94c29c7c36d` |
| `invoices` | 0 | `empty` |
| `journal_entries` | 0 | `empty` |
| `journal_lines` | 0 | `empty` |
| `journey_messages` | 0 | `empty` |
| `journey_ticks` | 2 | `516383cc53fcca2005c0d062b7367096` |
| `keyboxes` | 10 | `fe82b7467006f33b499231ad1e6c6fc2` |
| `knowledge_entries` | 10 | `9a2361604d15dbffb164c08dd9ca4807` |
| `maintenance_tickets` | 0 | `empty` |
| `monitor_runs` | 2 | `a75f5fedc366a74d13ee0794ee66a225` |
| `notifications` | 0 | `empty` |
| `organizations` | 1 | `27b1e1641ec47db84d383a9177669f1b` |
| `payment_transactions` | 0 | `empty` |
| `platform_payouts` | 0 | `empty` |
| `pos_settlements` | 0 | `empty` |
| `product_branches` | 24 | `b842fc74d20e41a82661157cda8e3ae6` |
| `product_categories` | 3 | `b928a5434d295eeafd776d673570873f` |
| `product_order_lines` | 0 | `empty` |
| `product_orders` | 0 | `empty` |
| `products` | 12 | `2e3898024fd49e1bbdc5560ac766d7f4` |
| `property_policies` | 13 | `2eb89b05d5d6430dc331d1eabd81ee54` |
| `rate_calendar` | 0 | `empty` |
| `registration_sessions` | 0 | `empty` |
| `release_rules` | 2 | `c719de8f1405e5685410d7d7b1ad8906` |
| `released_slots` | 5 | `d6591e08096bac096045658111106e79` |
| `reservation_allocations` | 0 | `empty` |
| `reservation_charges` | 0 | `empty` |
| `reservation_guests` | 0 | `empty` |
| `reservation_nights` | 0 | `empty` |
| `reservations` | 0 | `empty` |
| `review_items` | 0 | `empty` |
| `role_permissions` | 0 | `empty` |
| `room_categories` | 5 | `67805ba1d54e5c759b5f78d9588a96f3` |
| `rooms` | 34 | `8abb9cba731f062cfa5ad067fb66a1c8` |
| `service_definitions` | 1 | `c3bd3ffc292fd113e67a907614e1444d` |
| `staff_profiles` | 3 | `f2e0cd35bca53857772603415f9cfba9` |
| `staff_saved_views` | 0 | `empty` |
| `stay_acknowledgements` | 0 | `empty` |
| `stay_extension_requests` | 0 | `empty` |
| `stay_payment_exceptions` | 0 | `empty` |
| `system_settings` | 1 | `42a4e5fc7bc440f2839ccdb79ab0f746` |
| `task_types` | 5 | `b0353c8ac7345bf6bdc08a77a6f70484` |
| `unanswered_questions` | 0 | `empty` |
| `whatsapp_inbound_messages` | 0 | `empty` |
| `whatsapp_outbox` | 0 | `empty` |
