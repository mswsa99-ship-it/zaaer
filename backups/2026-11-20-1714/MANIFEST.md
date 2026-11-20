# النسخة الاحتياطية — 20 نوفمبر 2026، 17:14 UTC (بعد 0068، قبل ترحيلات رحلة الضيف W2–W7: 0069–0072)

نسخة من النظام قبل ترحيلات المهام W2–W7 من رحلة الضيف (مفاتيح الضريبة، يوم المغادرة، المغادرة ورد التأمين، التقييم، قواعد التنبيه، شرح الوحدات بالصور) وبيانات التجربة. تحلّ محل نسخة 14 نوفمبر لهذه الترحيلات: تغيّرت البيانات بعدها (محادثات المساعد وسجلات استعماله).

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `d46096e` (المنشور على `develop` وقت النسخة) | الواجهة والدوال والترحيلات حتى 0068 |
| قاعدة البيانات | `zaaer-db-2026-11-20-1714.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 93 في `public` (4,172 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-11-20 17:14 UTC (20:14 بتوقيت الرياض). كان المشروع عند 70 قيدًا في سجل الترحيلات، آخرها `20261113100000` (0068).

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها بيانات شخصية للضيوف، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف مشفّرةً من القاعدة بمفتاح نقل لمرة واحدة (دفعتان: ملفات الضيوف ثم بقية الجداول)، ثم فُكّت محليًا وبُني منها سكربت الاستعادة. حُذف مفتاح النقل والنص المقروء بعد الحفظ.

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-11-20-1714.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-11-20-1714.sql.gz.enc` | `a6c35d372bfcde593fcc011b57b5099f23f089d4700dc317b3d1953581705ab8` |
| `zaaer-db-2026-11-20-1714.sql.gz` | `561bd7ccb41889ced50c2d3892136b2f0d50bb08b02ae15675f6b0f4bc1de081` |
| `zaaer-db-2026-11-20-1714.sql` | `2428a8ab67295e71c1c257e24e9248f60ec4422a4912b1c5a05396955d818a74` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-11-20-1714.sql.gz.enc -out zaaer-db-2026-11-20-1714.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-11-20-1714.sql.gz
sha256sum zaaer-db-2026-11-20-1714.sql     # يطابق الجدول أعلاه
```

السكربت معاملة واحدة، ويتوقف دون تغيير إن اختلف سجل ترحيلات الهدف عن الـ70.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بالترحيلات الـ70 استقبلت النسخة: الجداول الـ93 مطابقة (4,172 صفًا).
- **الترحيلات القادمة على النسخة المستعادة:** طُبّقت 0069 و0070 (في ثلاثة أجزاء كما ستُرسل) و0071 و0072 بالملفات المغلّفة نفسها دون خطأ، وطابقت بصمة البنية (13 نوعًا) قاعدةً مبنية من الترحيلات كلها. لم تتغير قيمة أي عمود قديم في أي جدول؛ أُضيفت أعمدة جديدة فقط (ضريبة الخدمات والمنتجات للحجوزات فارغة، فلا ضريبة عليها كما كانت)، وأُضيفت إعدادات الرحلة للفروع الثلاثة وقواعد التنبيه الثماني، وقائمة المنتجات المثال (3 فئات و12 منتجًا معلّمة «تجريبي») في الفرعين النشطين، وعُلِّم 2,452 نزيلًا مستوردين من زائر.
- **فك التشفير ذهابًا وإيابًا:** طابقت بصمة السكربت.

## الجداول

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `accounting_periods` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 56 | `f8b0c38f6a50d9e82418ad7a060d2bc3` |
| `ai_ops_conversations` | 5 | `479b87561d32715ae6c60ed25fa3981e` |
| `ai_ops_messages` | 14 | `d4491de92304984d2d3fe433fa3d44be` |
| `ai_settings` | 1 | `6a806e5ee2d0df8d25d61d84154792eb` |
| `ai_tool_executions` | 3 | `6b7c6081cdef7165c81e90bd9c7b0e62` |
| `ai_usage_daily` | 10 | `a7335a4954d6af6ecca6c93db5bfbdc6` |
| `audit_events` | 204 | `6c8b5804ea4fcaf2546463911518e88a` |
| `bank_mail_settings` | 0 | `empty` |
| `bank_match_items` | 0 | `empty` |
| `bank_matches` | 0 | `empty` |
| `bank_messages` | 0 | `empty` |
| `bank_movements` | 0 | `empty` |
| `bank_parse_rules` | 25 | `7ccd86560ea482f071d09b6d0120ac9e` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 12 | `5696bdf29ac5d1491d139e2222d2ef30` |
| `branch_media` | 0 | `empty` |
| `branch_media_items` | 0 | `empty` |
| `branch_memberships` | 2 | `9d1141b80fa241a2f00220ca22a01d05` |
| `branch_payment_settings` | 0 | `empty` |
| `branch_whatsapp_channels` | 3 | `e81eb6e82d849418c94c080ee89e002c` |
| `branches` | 3 | `f774a334047f468247acf9712c0905d1` |
| `cash_accounts` | 6 | `f8dbe10bef5bf00b96cf58c36e8d63e3` |
| `checkout_inspections` | 1 | `804e533f61a7128a101ef16d603b61fa` |
| `client_errors` | 24 | `81ba3888ec0ad33587c6bb6fc97c28c2` |
| `code_rotation_events` | 3 | `9ac37ba1f7c6a9c508787f2a9427165c` |
| `conversation_messages` | 284 | `418bfd6f5f9be62932f60979eff3882b` |
| `conversations` | 142 | `e709864cfe192eeac8c8f6387b94a78d` |
| `data_purge_requests` | 2 | `566ea0feae2ac75f69f4d3d814421437` |
| `day_closing_lines` | 0 | `empty` |
| `day_closing_requests` | 0 | `empty` |
| `day_closings` | 0 | `empty` |
| `document_sequences` | 3 | `1ddd3bbd32ff8510d9d335ce69d5d3b9` |
| `expense_attachments` | 0 | `empty` |
| `expense_categories` | 12 | `edb670b5bfd618a1b4e9e9e707b7be96` |
| `expense_vouchers` | 0 | `empty` |
| `facilities` | 2 | `a1454c52a4a87e13a024367dffd1424f` |
| `financial_vouchers` | 24 | `0d92b495b42664a0fb14e9de345de19a` |
| `floors` | 2 | `aa1798b4855f65793795456a181beae8` |
| `gl_accounts` | 30 | `e18fee925b491e6c0fb0f00b43e4e184` |
| `guest_bans` | 0 | `empty` |
| `guest_lookup_attempts` | 1 | `f7582d03482631896e2ef5fd2b0c2a0d` |
| `guest_phone_challenges` | 0 | `empty` |
| `guest_phone_sessions` | 0 | `empty` |
| `guest_profiles` | 2552 | `049fe03d8aafb72a134b3aa25c7d41b1` |
| `housekeeping_tasks` | 3 | `b8ac72ae1acf5455814921f61df7f247` |
| `human_handoff_tickets` | 0 | `empty` |
| `integration_events` | 0 | `empty` |
| `inventory_periods` | 28 | `70e5c7a8eaf1633f74b83aa8d9569a07` |
| `invoices` | 1 | `294b2116cff20ebe6fcf3d5e6f67fb3b` |
| `journal_entries` | 24 | `d59cdbb66467ecbc815d95a0cd2d3af1` |
| `journal_lines` | 48 | `60338f9b907b65921f6d5e7d6a87360f` |
| `keyboxes` | 10 | `138f977020de59b1b3023b9a8eaadaa9` |
| `knowledge_entries` | 10 | `d66598ccc1ae2d0579f3e9ba203b6476` |
| `maintenance_tickets` | 0 | `empty` |
| `monitor_runs` | 3 | `9fcd883332965ad0777b706843c1a855` |
| `notifications` | 1 | `2a82424c760b975545f998d4fd66ce61` |
| `organizations` | 1 | `38afcb223362ea093b5aa6edfdf5f3c8` |
| `payment_transactions` | 0 | `empty` |
| `platform_payouts` | 0 | `empty` |
| `pos_settlements` | 0 | `empty` |
| `product_branches` | 0 | `empty` |
| `product_categories` | 0 | `empty` |
| `product_order_lines` | 0 | `empty` |
| `product_orders` | 0 | `empty` |
| `products` | 0 | `empty` |
| `property_policies` | 13 | `feed0e5f55c616f6b3f931088b53454f` |
| `rate_calendar` | 0 | `empty` |
| `registration_sessions` | 0 | `empty` |
| `release_rules` | 2 | `409b07f8f53f2c7ee6c8a153b773cb17` |
| `released_slots` | 5 | `adbb2db91bdb8ce532d233f55353d227` |
| `reservation_allocations` | 2 | `2fb86065471456b2bf7e49788d4fe37e` |
| `reservation_charges` | 101 | `732ec64b4123f3a44f7878fa919c9c5a` |
| `reservation_guests` | 100 | `91722e0987bbe95a1fe7d6d69a8dd6d4` |
| `reservation_nights` | 244 | `5710289b388cc86a57ffd2e15446dba4` |
| `reservations` | 100 | `3f4048fe352e22f661129a94536fdb57` |
| `review_items` | 0 | `empty` |
| `role_permissions` | 0 | `empty` |
| `room_categories` | 5 | `c88b1df98e10b92b87541e94a4291399` |
| `rooms` | 34 | `460849e72e83a440ba1797b9366ee274` |
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
