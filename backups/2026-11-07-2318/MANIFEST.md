# النسخة الاحتياطية — 7 نوفمبر 2026، 23:18 UTC (بعد 0065، قبل ترحيل المحاسبة A6 وA7: 0066)

نسخة من النظام قبل ترحيل المهمتين A6 وA7 من النظام المحاسبي (رسائل البنك بالبريد واستخراج الحركات). الفرع `backup/2026-11-07-2318` لا يُدمج ولا يُنشر منه شيء.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع (المنشور على `develop`) | الواجهة والدوال والترحيلات حتى 0065 |
| قاعدة البيانات | `zaaer-db-2026-11-07-2318.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 82 في `public` (3,122 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-11-07 23:18 UTC (02:18 بتوقيت الرياض، 8 نوفمبر). كان المشروع عند 67 قيدًا في سجل الترحيلات، آخرها `20261108040000` (0065).

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها بيانات شخصية للضيوف، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف مشفّرةً من القاعدة بمفتاح نقل لمرة واحدة، ثم فُكّت محليًا وبُني منها سكربت الاستعادة. حُذف مفتاح النقل والنص المقروء بعد الحفظ. سكربت الاستعادة يتجاوز الأعمدة المحسوبة (مثل `reservations.guest_verified`) فتُحسب من جديد.

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-11-07-2318.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-11-07-2318.sql.gz.enc` | `d489b9817358dd83d1973d41f6321ee914dacfa2d9b17bb77f7abb5b97687eb7` |
| `zaaer-db-2026-11-07-2318.sql.gz` | `4352e4d7187c5f7d938780140deb0868a973bf31bf0388bdb1e0f4b6adaa9a9e` |
| `zaaer-db-2026-11-07-2318.sql` | `ecbe5fdeae108405adfd29bc48fea13a85e9f34e5a2d2890363114b554ec8cc8` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-11-07-2318.sql.gz.enc -out zaaer-db-2026-11-07-2318.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-11-07-2318.sql.gz
sha256sum zaaer-db-2026-11-07-2318.sql     # يطابق الجدول أعلاه
```

السكربت معاملة واحدة، ويتوقف دون تغيير إن اختلف سجل ترحيلات الهدف عن الـ67.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بالترحيلات الـ67 استقبلت النسخة: الجداول الـ82 مطابقة (3,122 صفًا).
- **الترحيلات القادمة على النسخة المستعادة:** طُبّق 0066 عليها دون خطأ (25 كلمة لقراءة الرسائل، و64 عملية في مصفوفة الصلاحيات).
- **فك التشفير ذهابًا وإيابًا:** طابقت بصمة السكربت.

## الجداول

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `accounting_periods` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 40 | `ac181f3e25c736ecb6655a9eb069f5b1` |
| `ai_ops_conversations` | 2 | `7f9acfd48da08f95aaba625614c2f1ab` |
| `ai_ops_messages` | 4 | `8a6d4727c0e727ebc6e33708dc431ed8` |
| `ai_settings` | 1 | `6a806e5ee2d0df8d25d61d84154792eb` |
| `ai_tool_executions` | 2 | `985a7f0cbf4e33ae1c05c145d08606c3` |
| `ai_usage_daily` | 5 | `e84056a321adf039234d352c95db3524` |
| `audit_events` | 60 | `20a65c615042655550727e9cfdb2f7ab` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 12 | `5696bdf29ac5d1491d139e2222d2ef30` |
| `branch_media` | 0 | `empty` |
| `branch_media_items` | 0 | `empty` |
| `branch_memberships` | 2 | `9d1141b80fa241a2f00220ca22a01d05` |
| `branch_payment_settings` | 0 | `empty` |
| `branch_whatsapp_channels` | 3 | `e81eb6e82d849418c94c080ee89e002c` |
| `branches` | 3 | `f774a334047f468247acf9712c0905d1` |
| `cash_accounts` | 6 | `f8dbe10bef5bf00b96cf58c36e8d63e3` |
| `checkout_inspections` | 0 | `empty` |
| `client_errors` | 13 | `b23fe5a71d98ea95599c8e2741caaeea` |
| `code_rotation_events` | 3 | `9ac37ba1f7c6a9c508787f2a9427165c` |
| `conversation_messages` | 236 | `84e5dad740f11a20cd076afa657d1dae` |
| `conversations` | 118 | `7bbb8a037726db5f192f2cc028662b69` |
| `data_purge_requests` | 2 | `566ea0feae2ac75f69f4d3d814421437` |
| `day_closing_lines` | 0 | `empty` |
| `day_closing_requests` | 0 | `empty` |
| `day_closings` | 0 | `empty` |
| `document_sequences` | 2 | `793b76b1b311cdd6b5c4fdfcb6ba86a0` |
| `expense_attachments` | 0 | `empty` |
| `expense_categories` | 8 | `320c74cda03827e2a8ebb0f997df915c` |
| `expense_vouchers` | 0 | `empty` |
| `facilities` | 2 | `a1454c52a4a87e13a024367dffd1424f` |
| `financial_vouchers` | 0 | `empty` |
| `floors` | 2 | `aa1798b4855f65793795456a181beae8` |
| `gl_accounts` | 19 | `03ba9c7c22c37fa1fd89f95eabc23413` |
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
| `journal_entries` | 0 | `empty` |
| `journal_lines` | 0 | `empty` |
| `keyboxes` | 10 | `138f977020de59b1b3023b9a8eaadaa9` |
| `knowledge_entries` | 10 | `d66598ccc1ae2d0579f3e9ba203b6476` |
| `maintenance_tickets` | 0 | `empty` |
| `monitor_runs` | 3 | `5aa051eabb8d200ab1bbc17cec98c5b5` |
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
