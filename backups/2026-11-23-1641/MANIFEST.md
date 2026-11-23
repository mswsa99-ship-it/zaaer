# النسخة الاحتياطية — 23 نوفمبر 2026، 16:41 UTC (بعد 0075، قبل ترحيل أعمدة الفندق والفرع 0076)

نسخة كاملة من بيانات النظام بعد تطبيق ترحيل رقم ترخيص الوحدة 0075، وقبل تطبيق ترحيل أعمدة الفندق والفرع 0076 (المرحلة 2 من خطة التصحيح، البند 2.2). فيها محادثات نزلاء مع المساعد أُجريت بعد المسح (18 محادثة، 36 رسالة)، ولا حجوزات ولا ملفات نزلاء.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `2a84e5e` (المنشور على `develop` وقت النسخة) | الواجهة والدوال والترحيلات حتى 0072 و0074 و0075 مطبّقة، و0073 لصقة للمالك لم تُلصق بعد |
| قاعدة البيانات | `zaaer-db-2026-11-23-1641.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 101 في `public` (302 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-11-23 16:41:23 UTC (19:41 بتوقيت الرياض). كان المشروع عند 76 قيدًا في سجل الترحيلات، آخرها `20261123110000`.

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها أسماء الموظفين وبريدهم وإعدادات الفروع ونصوص محادثات النزلاء، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف من القاعدة في معاملة واحدة (Repeatable Read) مشفّرةً بمفتاح عام لمرة واحدة؛ المفتاح الخاص لم يغادر بيئة العمل وأُتلف بعد فك التشفير. ومن نص JSON كما صدر بُني سكربت الاستعادة (دون إعادة صياغة الأرقام)، وفي المعاملة نفسها أُخذت بصمة كل جدول.

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-11-23-1641.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-11-23-1641.sql.gz.enc` | `a96eb4917c1fc927c5314d87b1061d98633e05d8524cc434c831f3bfb2311802` |
| `zaaer-db-2026-11-23-1641.sql.gz` | `ad97df74c58498cfddfaef68a7249bf19932b63d72e8c5758d02d39f6b4bbb4f` |
| `zaaer-db-2026-11-23-1641.sql` | `270cae6a72ef87b6f9ec405d1a3799b2837d0cd3719e15c23619b2164a217fe8` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-11-23-1641.sql.gz.enc -out zaaer-db-2026-11-23-1641.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-11-23-1641.sql.gz
sha256sum zaaer-db-2026-11-23-1641.sql     # يطابق الجدول أعلاه
psql "$DB_URL" -v ON_ERROR_STOP=1 -f zaaer-db-2026-11-23-1641.sql
```

السكربت معاملة واحدة: يرفض العمل دون أي تغيير إن اختلفت أعمدة جداول `public` في الهدف عن أعمدة وقت النسخة (بصمة الأعمدة `01b6ae43f8ff6b8ad978ae9537ce333b`)، ثم يفرّغ الجداول المئة والواحد ويعيد صفوفها كما كانت. ترحيل 0076 يضيف أعمدة الفندق والفرع إلى 31 جدولًا، فالنسخة تُستعاد على قاعدة بأعمدة ما قبله (بعد إرجاع المخطط إلى 0075)؛ وعلى قاعدة بعده يرفض السكربت العمل كما صُمّم.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة محلية جديدة بالترحيلات الـ76 استقبلت النسخة: الجداول الـ101 مطابقة للإنتاج عددًا وبصمة (302 صفًا).
- **الرفض:** على قاعدة أعمدتها مختلفة رفض السكربت العمل ولم يتغير فيها شيء.
- **الترحيل المعلّق على النسخة المستعادة:** طُبّق 0076 عليها مرتين؛ نجح، ولم يتغير عدد صفوف أي جدول، وامتلأت الأعمدة الجديدة في الجداول الستة التي فيها صفوف، ولم تغيّر المرة الثانية شيئًا، وبصمة المخطط بعدها مطابقة لها بعد الأولى في الأنواع الثلاثة عشر.
- **فك التشفير ذهابًا وإيابًا:** طابق الملف المضغوط بايتًا ببايت.

## الجداول

البصمة: md5 لنصوص الصفوف مرتبة، كما حُسبت في معاملة التصدير.

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `accounting_periods` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 11 | `0977c0bcde55b02ed07b8424dcb16fc0` |
| `ai_ops_conversations` | 0 | `empty` |
| `ai_ops_messages` | 0 | `empty` |
| `ai_settings` | 1 | `998f096b050ce755f1078f23ef078aec` |
| `ai_tool_executions` | 0 | `empty` |
| `ai_usage_daily` | 1 | `c4e94bc5d07ff43f2cd7e043ff7ffc34` |
| `alert_events` | 0 | `empty` |
| `alert_rules` | 8 | `b5016bcfd663a3051950d3e20a63a174` |
| `audit_events` | 48 | `5109375c16528fc74379420bb7ab493b` |
| `bank_mail_settings` | 0 | `empty` |
| `bank_match_items` | 0 | `empty` |
| `bank_matches` | 0 | `empty` |
| `bank_messages` | 0 | `empty` |
| `bank_movements` | 0 | `empty` |
| `bank_parse_rules` | 25 | `e027690af3c56e3903b7c19a45d9a106` |
| `blocks` | 0 | `empty` |
| `booking_sources` | 12 | `de60dedc790ad3fee9dce6d26302b3ad` |
| `branch_journey_settings` | 2 | `2364ac1624fc4a213bc8fdc9babefc8f` |
| `branch_media` | 0 | `empty` |
| `branch_media_items` | 0 | `empty` |
| `branch_memberships` | 2 | `90fe02ec42f62d1da31cd9526eda5e0d` |
| `branch_payment_settings` | 0 | `empty` |
| `branch_whatsapp_channels` | 2 | `fdc2dcce4ac089d66d86a4b3e48c989e` |
| `branches` | 2 | `9f8f08389e7660a947963547c7fdd4b3` |
| `cash_accounts` | 4 | `a430ee47fa61ce9fc695e59b1360eb72` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 0 | `empty` |
| `code_rotation_events` | 0 | `empty` |
| `conversation_messages` | 36 | `350f05bfa121ec95d12dac2b773ecdf4` |
| `conversations` | 18 | `32501f33e851ac2c1b237af93daff195` |
| `data_purge_requests` | 0 | `empty` |
| `day_closing_lines` | 0 | `empty` |
| `day_closing_requests` | 0 | `empty` |
| `day_closings` | 0 | `empty` |
| `document_sequences` | 4 | `533d9e228ff642c7f6540d4ca66cb251` |
| `expense_attachments` | 0 | `empty` |
| `expense_categories` | 12 | `c8bf8eff221c4f473ab14b1da953ac16` |
| `expense_vouchers` | 0 | `empty` |
| `facilities` | 0 | `empty` |
| `financial_vouchers` | 0 | `empty` |
| `floors` | 0 | `empty` |
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
| `inventory_periods` | 0 | `empty` |
| `invoices` | 0 | `empty` |
| `journal_entries` | 0 | `empty` |
| `journal_lines` | 0 | `empty` |
| `journey_messages` | 0 | `empty` |
| `journey_ticks` | 2 | `e38ca0698d0e10859739e96748222072` |
| `keyboxes` | 0 | `empty` |
| `knowledge_entries` | 0 | `empty` |
| `maintenance_tickets` | 0 | `empty` |
| `monitor_runs` | 2 | `944a6083808ded89a1c8142631f10d4a` |
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
| `property_policies` | 6 | `87915dc1188f221fc25822d0abce4bf1` |
| `rate_calendar` | 0 | `empty` |
| `registration_sessions` | 0 | `empty` |
| `release_rules` | 0 | `empty` |
| `released_slots` | 0 | `empty` |
| `reservation_allocations` | 0 | `empty` |
| `reservation_charges` | 0 | `empty` |
| `reservation_guests` | 0 | `empty` |
| `reservation_nights` | 0 | `empty` |
| `reservations` | 0 | `empty` |
| `review_items` | 0 | `empty` |
| `role_permissions` | 0 | `empty` |
| `room_categories` | 3 | `74f4d81a1514b0215c2f0839a220d49f` |
| `room_licenses` | 0 | `empty` |
| `rooms` | 24 | `b3a9bec5f05b7945b0d67479b5c0dfd3` |
| `service_definitions` | 0 | `empty` |
| `staff_profiles` | 3 | `f2e0cd35bca53857772603415f9cfba9` |
| `staff_saved_views` | 0 | `empty` |
| `stay_acknowledgements` | 0 | `empty` |
| `stay_extension_requests` | 0 | `empty` |
| `stay_payment_exceptions` | 0 | `empty` |
| `system_settings` | 1 | `42a4e5fc7bc440f2839ccdb79ab0f746` |
| `task_types` | 2 | `a1cfa8888d32b45458067df96c37cfda` |
| `unanswered_questions` | 0 | `empty` |
| `whatsapp_inbound_messages` | 0 | `empty` |
| `whatsapp_outbox` | 0 | `empty` |
