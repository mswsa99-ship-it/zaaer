# النسخة الاحتياطية — 31 أكتوبر 2026، 07:14 UTC (بعد 0050، قبل الترحيل 0051)

نسخة من النظام قبل الترحيل 0051 (عمولة مصادر الحجز). الفرع `backup/2026-10-31-0714` لا يُدمج ولا يُنشر منه شيء.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `e6ef03f` (المنشور على `develop`) | الواجهة والدوال والترحيلات حتى 0050 |
| قاعدة البيانات | `zaaer-db-2026-10-31-0714.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 70 في `public` (2,750 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-10-31 07:14 UTC (10:14 بتوقيت الرياض). كان المشروع عند 52 قيدًا في سجل الترحيلات، آخرها `20261031020000` (0050).

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها بيانات شخصية للضيوف، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف مشفّرةً من القاعدة بمفتاح نقل لمرة واحدة، ثم فُكّت محليًا وطوبقت بصمتها، وبُني منها سكربت الاستعادة. حُذف مفتاح النقل والنص المقروء بعد الحفظ.

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-10-31-0714.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-10-31-0714.sql.gz.enc` | `8d50580bfe60da2917e116f9c17579d46b39ca407552dcc975a9a275c8dcb15e` |
| `zaaer-db-2026-10-31-0714.sql.gz` | `c0e60858e3531df1ae4e2eb73109efabea71a6c20e8e92e2f376d83f3793dc46` |
| `zaaer-db-2026-10-31-0714.sql` | `bb3001a056b32cae5dfb5edb0fea06ce3eae447495f8cf0269c7b6d468d4345b` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-10-31-0714.sql.gz.enc -out zaaer-db-2026-10-31-0714.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-10-31-0714.sql.gz
sha256sum zaaer-db-2026-10-31-0714.sql     # يطابق الجدول أعلاه
```

السكربت معاملة واحدة، ويتوقف دون تغيير إن اختلف سجل ترحيلات الهدف عن الـ52.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بالترحيلات الـ52 استقبلت النسخة: الجداول الـ70 مطابقة (2,750 صفًا).
- **فك التشفير ذهابًا وإيابًا:** طابقت بصمة السكربت.

## الجداول

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 11 | `9790a61ee1d9f0ffc7d9b118cb2591c4` |
| `ai_ops_conversations` | 1 | `dc5628fa262a3748939f0da5596646d4` |
| `ai_ops_messages` | 2 | `5ef175f2c0b963bcea787c985774f161` |
| `ai_settings` | 1 | `294138572fd36c762edd4db58a4cd990` |
| `ai_tool_executions` | 0 | `empty` |
| `ai_usage_daily` | 1 | `3b3169939ed422c65511bd41e5e1c377` |
| `audit_events` | 56 | `f486979392a1b08fc4abf98bde4603c5` |
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
| `conversation_messages` | 36 | `4bc3457ec0715e4278533304988ab4a3` |
| `conversations` | 18 | `eb67b2f296f157506745cf672dfe5c31` |
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
| `monitor_runs` | 3 | `79be70de180076756331e2f54099921d` |
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
