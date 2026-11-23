# النسخة الاحتياطية — 23 نوفمبر 2026، 18:04 UTC (بعد 0077، قبل ترحيل الدوال بالفندق 0078)

نسخة كاملة من بيانات النظام بعد تطبيق ترحيل قواعد الصفوف بالفندق 0077، وقبل ترحيل الدوال بالفندق والفرع 0078 (المرحلة 2 من خطة التصحيح، البند 2.4). **0078 لم يُطبَّق على الإنتاج**: توقّف العمل بطلب المالك (21:15 بتوقيت الرياض) بعد هذه النسخة وتجربتها وقبل التطبيق.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `7f11718` (المنشور على `develop` وقت النسخة) | الواجهة والدوال والترحيلات حتى 0072 و0074–0077 مطبّقة، و0073 لصقة للمالك لم تُلصق بعد |
| قاعدة البيانات | `zaaer-db-2026-11-23-1804.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 101 في `public` (347 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-11-23 18:04:25 UTC (21:04 بتوقيت الرياض). كان المشروع عند 78 قيدًا في سجل الترحيلات، آخرها `20261123130000`.

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها أسماء الموظفين وبريدهم وإعدادات الفروع ونصوص محادثات النزلاء، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف من القاعدة في معاملة واحدة (Repeatable Read) مشفّرةً بمفتاح عام لمرة واحدة؛ المفتاح الخاص لم يغادر بيئة العمل وأُتلف بعد فك التشفير. ومن نص JSON كما صدر بُني سكربت الاستعادة، وفي المعاملة نفسها أُخذت بصمة كل جدول.

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-11-23-1804.txt` (المفتاح في سطره الأخير).

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-11-23-1804.sql.gz.enc` | `60abcfd101a2914be5cb14000c9cfcef5040f311b550ead95a20eb73a271316d` |
| `zaaer-db-2026-11-23-1804.sql.gz` | `ffcf42aaddc419fc4a77032ab337ee5690e7d4032f6938b34016a30629e549d5` |
| `zaaer-db-2026-11-23-1804.sql` | `539d5091faa2af8835482a7e44ea586a3c6f0db419844d60f95e86bc977d1b94` |

## الاستعادة (عند الضرورة فقط)

```bash
tail -n 1 zaaer-backup-key-2026-11-23-1804.txt > passphrase.txt
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-11-23-1804.sql.gz.enc -out zaaer-db-2026-11-23-1804.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-11-23-1804.sql.gz
sha256sum zaaer-db-2026-11-23-1804.sql     # يطابق الجدول أعلاه
psql "$DB_URL" -v ON_ERROR_STOP=1 -f zaaer-db-2026-11-23-1804.sql
```

السكربت معاملة واحدة: يرفض العمل دون أي تغيير إن اختلفت أعمدة جداول `public` في الهدف عن أعمدة وقت النسخة (بصمة الأعمدة `ed309c7537fa19ad5ad3cc53f5c30a89`)، ثم يفرّغ الجداول المئة والواحد ويعيد صفوفها كما كانت. ترحيل 0078 لا يغيّر عمودًا، فالنسخة تُستعاد بعده كما تُستعاد قبله.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة محلية جديدة بالترحيلات الـ78 استقبلت النسخة: الجداول الـ101 مطابقة للإنتاج عددًا وبصمة (347 صفًا، والبصمة بتوقيت UTC كما أُخذت).
- **الرفض:** على قاعدة أعمدتها مختلفة رفض السكربت العمل ولم يتغير فيها شيء.
- **الترحيل المعلّق على النسخة المستعادة:** طُبّق ملف 0078 النهائي (md5 `6752389436843d8a87814439499c8b0b`) عليها مرتين: لم يتغير صف في الجداول الـ101، وبصمة المخطط بعد الثانية مطابقة لها بعد الأولى في الأنواع الثلاثة عشر؛ وجُرّبت كتلة التطبيق المتحققة من البصمة على نسخة أخرى: طبّقت ثم رفضت الثانية (`MIGRATION_0078_ALREADY`) دون تغيير. ولا صف في بيانات الإنتاج يشير إلى صف فندق آخر في أيٍّ من المؤشرات الـ211.
- **فك التشفير ذهابًا وإيابًا:** طابق الملف المضغوط بايتًا ببايت.

## الجداول

البصمة: عدد الصفوف وmd5 لنصوص الصفوف مرتبة، كما حُسبت في معاملة التصدير.

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `accounting_periods` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 20 | `7a84318b48b514886b51d7d001be5b6e` |
| `ai_ops_conversations` | 0 | `empty` |
| `ai_ops_messages` | 0 | `empty` |
| `ai_settings` | 1 | `998f096b050ce755f1078f23ef078aec` |
| `ai_tool_executions` | 0 | `empty` |
| `ai_usage_daily` | 1 | `51bf20fafcd5565168491b3b65b64440` |
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
| `branch_memberships` | 2 | `b0cde8c8b72747d2a515ac5bf990035e` |
| `branch_payment_settings` | 0 | `empty` |
| `branch_whatsapp_channels` | 2 | `fdc2dcce4ac089d66d86a4b3e48c989e` |
| `branches` | 2 | `9f8f08389e7660a947963547c7fdd4b3` |
| `cash_accounts` | 4 | `a430ee47fa61ce9fc695e59b1360eb72` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 0 | `empty` |
| `code_rotation_events` | 0 | `empty` |
| `conversation_messages` | 60 | `77360d421aab0ebfc1b86b7b6f2fe7c8` |
| `conversations` | 30 | `077bade75faba479d6fe032b290aa633` |
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
| `journey_ticks` | 2 | `21a3e139612a5e4479008a359647388d` |
| `keyboxes` | 0 | `empty` |
| `knowledge_entries` | 0 | `empty` |
| `maintenance_tickets` | 0 | `empty` |
| `monitor_runs` | 2 | `241784a400e2db9653e94d0da48e751c` |
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
