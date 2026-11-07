# النسخة الاحتياطية — 7 نوفمبر 2026، 17:00 UTC (بعد 0063، قبل ترحيل المحاسبة A4: 0064)

نسخة من النظام قبل ترحيل المهمة A4 من النظام المحاسبي (المصروفات ودفتر الحركة). الفرع `backup/2026-11-07-1700` لا يُدمج ولا يُنشر منه شيء.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع (المنشور على `develop`) | الواجهة والدوال والترحيلات حتى 0063 |
| قاعدة البيانات | `zaaer-db-2026-11-07-1700.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 75 في `public` (3,055 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-11-07 17:00 UTC (20:00 بتوقيت الرياض). كان المشروع عند 65 قيدًا في سجل الترحيلات، آخرها `20261108020000` (0063).

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها بيانات شخصية للضيوف، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف مشفّرةً من القاعدة بمفتاح نقل لمرة واحدة، ثم فُكّت محليًا وبُني منها سكربت الاستعادة. حُذف مفتاح النقل والنص المقروء بعد الحفظ. سكربت الاستعادة يتجاوز الأعمدة المحسوبة (مثل `reservations.guest_verified`) فتُحسب من جديد.

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-11-07-1700.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-11-07-1700.sql.gz.enc` | `ba62a010406c50b7245656cf9177f66daaf91cd6ed582d7a123461d54d005c91` |
| `zaaer-db-2026-11-07-1700.sql.gz` | `576a361b65a3b46586af7392546e1612b7f995551fa443fb7fde9c2c9932f2d9` |
| `zaaer-db-2026-11-07-1700.sql` | `f337ac88b1e6bc58dc635fc106fb9750725263bd829f79f9151f0c23ff476bc3` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-11-07-1700.sql.gz.enc -out zaaer-db-2026-11-07-1700.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-11-07-1700.sql.gz
sha256sum zaaer-db-2026-11-07-1700.sql     # يطابق الجدول أعلاه
```

السكربت معاملة واحدة، ويتوقف دون تغيير إن اختلف سجل ترحيلات الهدف عن الـ65.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بالترحيلات الـ65 استقبلت النسخة: الجداول الـ75 مطابقة (3,055 صفًا).
- **الترحيلات القادمة على النسخة المستعادة:** طُبّق 0064 عليها دون خطأ.
- **فك التشفير ذهابًا وإيابًا:** طابقت بصمة السكربت.

## الجداول

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 36 | `d790688fdfcb59e92f69f6df867c911d` |
| `ai_ops_conversations` | 2 | `7f9acfd48da08f95aaba625614c2f1ab` |
| `ai_ops_messages` | 4 | `8a6d4727c0e727ebc6e33708dc431ed8` |
| `ai_settings` | 1 | `6a806e5ee2d0df8d25d61d84154792eb` |
| `ai_tool_executions` | 2 | `985a7f0cbf4e33ae1c05c145d08606c3` |
| `ai_usage_daily` | 5 | `21fb719fca3fe63d5a1e2e7c93fe04a7` |
| `audit_events` | 60 | `20a65c615042655550727e9cfdb2f7ab` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 12 | `5696bdf29ac5d1491d139e2222d2ef30` |
| `branch_media` | 0 | `empty` |
| `branch_media_items` | 0 | `empty` |
| `branch_memberships` | 2 | `9d1141b80fa241a2f00220ca22a01d05` |
| `branch_payment_settings` | 0 | `empty` |
| `branch_whatsapp_channels` | 3 | `e81eb6e82d849418c94c080ee89e002c` |
| `branches` | 3 | `f774a334047f468247acf9712c0905d1` |
| `cash_accounts` | 6 | `44f8ec95e5e4828147d8f60845ea45a5` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 13 | `b23fe5a71d98ea95599c8e2741caaeea` |
| `code_rotation_events` | 3 | `9ac37ba1f7c6a9c508787f2a9427165c` |
| `conversation_messages` | 212 | `8cd1bba29b22e593010065872e10d0af` |
| `conversations` | 106 | `afd8a3b86efb53579cf85130d6e2d1d9` |
| `data_purge_requests` | 2 | `566ea0feae2ac75f69f4d3d814421437` |
| `day_closing_lines` | 0 | `empty` |
| `day_closing_requests` | 0 | `empty` |
| `day_closings` | 0 | `empty` |
| `document_sequences` | 2 | `793b76b1b311cdd6b5c4fdfcb6ba86a0` |
| `facilities` | 2 | `a1454c52a4a87e13a024367dffd1424f` |
| `financial_vouchers` | 0 | `empty` |
| `floors` | 2 | `aa1798b4855f65793795456a181beae8` |
| `guest_bans` | 0 | `empty` |
| `guest_lookup_attempts` | 1 | `f7582d03482631896e2ef5fd2b0c2a0d` |
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
| `monitor_runs` | 3 | `cb27455defe1fdd763b9204dde41fd61` |
| `notifications` | 0 | `empty` |
| `organizations` | 1 | `38afcb223362ea093b5aa6edfdf5f3c8` |
| `payment_transactions` | 0 | `empty` |
| `platform_payouts` | 0 | `empty` |
| `pos_settlements` | 0 | `empty` |
| `property_policies` | 13 | `feed0e5f55c616f6b3f931088b53454f` |
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
