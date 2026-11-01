# النسخة الاحتياطية — 31 أكتوبر 2026، 21:38 UTC (بعد 0051، قبل ترحيلات المرحلة 1: 0052–0054)

نسخة من النظام قبل ترحيلات المرحلة 1 من مراجعة 31 أكتوبر (الأمن، الاستقبال، المال). الفرع `backup/2026-10-31-2138` لا يُدمج ولا يُنشر منه شيء.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `0280544` (المنشور على `develop`) | الواجهة والدوال والترحيلات حتى 0051 |
| قاعدة البيانات | `zaaer-db-2026-10-31-2138.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 70 في `public` (2,799 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-10-31 21:38 UTC (00:38 بتوقيت الرياض، 1 نوفمبر). كان المشروع عند 53 قيدًا في سجل الترحيلات، آخرها `20261031030000` (0051).

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها بيانات شخصية للضيوف، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف مشفّرةً من القاعدة بمفتاح نقل لمرة واحدة، ثم فُكّت محليًا وطوبقت بصمتها، وبُني منها سكربت الاستعادة. جدول `guest_profiles` لم تتغير بصمته منذ نسخة `backup/2026-10-31-0714` فأُخذت صفوفه منها بعد مطابقة البصمة. حُذف مفتاح النقل والنص المقروء بعد الحفظ.

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-10-31-2138.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-10-31-2138.sql.gz.enc` | `2344fb231054cf80618b26ab24d9b5b52a53a2bc7d15b3399177601bd1a27cd1` |
| `zaaer-db-2026-10-31-2138.sql.gz` | `aa52f7460ae998839c28e385810ded5ec351f1389464fb35b03337570bd0ea16` |
| `zaaer-db-2026-10-31-2138.sql` | `e6df6c734b4a4bde3c6c8c52bfdc528b8aab2b4eef91fb755e77e435b0b0ad19` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-10-31-2138.sql.gz.enc -out zaaer-db-2026-10-31-2138.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-10-31-2138.sql.gz
sha256sum zaaer-db-2026-10-31-2138.sql     # يطابق الجدول أعلاه
```

السكربت معاملة واحدة، ويتوقف دون تغيير إن اختلف سجل ترحيلات الهدف عن الـ53.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بالترحيلات الـ53 استقبلت النسخة: الجداول الـ70 مطابقة (2,799 صفًا).
- **الترحيلات القادمة على النسخة المستعادة:** طُبّقت 0052 و0053 و0054 عليها دون خطأ.
- **فك التشفير ذهابًا وإيابًا:** طابقت بصمة السكربت.

## الجداول

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 17 | `abc39ae7a8f327a0f16715b97f01f6d6` |
| `ai_ops_conversations` | 1 | `dc5628fa262a3748939f0da5596646d4` |
| `ai_ops_messages` | 2 | `5ef175f2c0b963bcea787c985774f161` |
| `ai_settings` | 1 | `294138572fd36c762edd4db58a4cd990` |
| `ai_tool_executions` | 0 | `empty` |
| `ai_usage_daily` | 2 | `148dc15ae72f438c8d0333cfdf6d19fc` |
| `audit_events` | 60 | `20a65c615042655550727e9cfdb2f7ab` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 12 | `5696bdf29ac5d1491d139e2222d2ef30` |
| `branch_media` | 0 | `empty` |
| `branch_memberships` | 2 | `9d1141b80fa241a2f00220ca22a01d05` |
| `branch_whatsapp_channels` | 3 | `697823b65a7b57b2337845b8eb5a0cb5` |
| `branches` | 3 | `71272eff0507a19605e99b3a364e95ec` |
| `cash_accounts` | 6 | `283eeb5574c9782cf6d1b05f2a7eebc7` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 13 | `b23fe5a71d98ea95599c8e2741caaeea` |
| `code_rotation_events` | 3 | `9ac37ba1f7c6a9c508787f2a9427165c` |
| `conversation_messages` | 60 | `c74aaa7929a68eeb382efbee882463eb` |
| `conversations` | 30 | `a6ff4e357dccd0da572e62c6fc0afb27` |
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
| `monitor_runs` | 3 | `4af64694eee34bb4b3b22ab97ea70bf2` |
| `notifications` | 0 | `empty` |
| `organizations` | 1 | `6165fbcb4de2379de1ad27cb71f1d5e9` |
| `payment_transactions` | 0 | `empty` |
| `platform_payouts` | 0 | `empty` |
| `pos_settlements` | 0 | `empty` |
| `property_policies` | 13 | `3c66bc998d049798e415b9655755511c` |
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
| `room_categories` | 5 | `c88b1df98e10b92b87541e94a4291399` |
| `rooms` | 34 | `6e8130bb81140d1365fb5044004e63a6` |
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
