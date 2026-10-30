# النسخة الاحتياطية — 30 أكتوبر 2026، 18:53 UTC (قبل الترحيلين 0047 و0048)

نسخة من النظام كما هو منشور قبل تطبيق تصحيحات ملاحظات التجربة (الترحيل 0047: صحة البيانات؛ الترحيل 0048: التغييرات قبل الوصول) على المشروع الفعلي. الفرع `backup/2026-10-30-1853` لا يُدمج ولا يُنشر منه شيء.

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `develop` عند `958947e` | الواجهة والدوال والترحيلات كما هي منشورة الآن |
| قاعدة البيانات | `zaaer-db-2026-10-30-1853.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 70 في `public` (752 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-10-30 18:53 UTC (21:53 بتوقيت الرياض)، في لقطة واحدة متسقة. كان المشروع عند 48 قيدًا في سجل الترحيلات، آخرها `20261029050000` (0046)، يطابق `supabase/production-applied.txt`.

**ليس فيها:** حسابات الدخول (auth) ومفاتيح Vault وأسرار الدوال. الأعمدة المشفّرة (رموز الصناديق وأرقام الهويات) محفوظة كما هي وتُقرأ في المشروع نفسه فقط.

**كيف أُخذت:** صُدّرت الصفوف من قاعدة البيانات مشفّرةً هناك (OpenPGP، AES-256، بمفتاح نقل لمرة واحدة)، ثم فُكّت محليًا وطوبقت بصمتها (md5) مع بصمة الخادم، وبُني منها سكربت الاستعادة. حُذف مفتاح النقل والنص المقروء بعد الحفظ.

## التشفير والمفتاح

الملف مضغوط (gzip) ثم مشفّر بـ AES-256-CBC، والمفتاح مشتق بـ PBKDF2-SHA256 بـ 600,000 تكرار. **المفتاح ليس في المستودع**: هو في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف «مفتاح النسخة الاحتياطية 2026-10-30 1853 (قبل 0047 و0048)» (طوبق بعد رفعه).

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-10-30-1853.sql.gz.enc` | `883155165983bdbe71783a93ff6b95151584ec4b50bb24960d35a9cb370040c8` |
| `zaaer-db-2026-10-30-1853.sql.gz` | `52916a82c1c648a0a5c49c77c84582ce24fb1807ed63732aab61927776a2d52e` |
| `zaaer-db-2026-10-30-1853.sql` | `585a92f326c6c8d76bcc907cceaf16a15d7d2d2255e67d6026e9746ad4c7e1b2` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-10-30-1853.sql.gz.enc -out zaaer-db-2026-10-30-1853.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-10-30-1853.sql.gz
sha256sum zaaer-db-2026-10-30-1853.sql     # يطابق الجدول أعلاه
```

السكربت يعمل في معاملة واحدة ويستبدل صفوف الجداول بصفوف النسخة، ويتوقف دون تغيير إن اختلف سجل ترحيلات الهدف عن الـ48. بعد تطبيق 0047 و0048 لا يُستعاد إلى المشروع مباشرة: الاستعادة الكاملة إلى مشروع جديد يُبنى بالترحيلات الـ48، والكود يرجع بنشر أب هذا الإيداع.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بُنيت من الترحيلات الـ48، ثم استُعيدت إليها النسخة: الجداول الـ70 مطابقة للأصل في عدد الصفوف وبصمة كل جدول.
- **بروفة التطبيق:** طُبّق 0047 ثم 0048 على النسخة المستعادة دون خطأ، وبقي عدد الصفوف كما هو.

## الجداول: عدد الصفوف والبصمة

البصمة: `md5` لصفوف الجدول (`to_jsonb(row)::text` مرتبةً، بفاصل `|`، والمنطقة الزمنية UTC).

| الجدول | الصفوف | البصمة |
| --- | ---: | --- |
| `access_delivery_events` | 3 | `6cff55001f65c75515de2aaae1546291` |
| `access_release_requests` | 1 | `9010d47ab7580d0b09527a291dc3fd81` |
| `ai_action_proposals` | 0 | `empty` |
| `ai_guardrail_events` | 59 | `c2933a9168281831f8fab174973c8b25` |
| `ai_ops_conversations` | 2 | `c7032c637ab9ca0d12dff4d431f6c5df` |
| `ai_ops_messages` | 4 | `d8aeec7bfb052cd33a0ae96600dbec74` |
| `ai_settings` | 1 | `294138572fd36c762edd4db58a4cd990` |
| `ai_tool_executions` | 10 | `f2b5f710eeae6b8e5ee6bd3e6e6414c7` |
| `ai_usage_daily` | 7 | `992bbd96492ff503742a127f4128c5c1` |
| `audit_events` | 75 | `38b6d7d8fba730123da739d8c5ce2b0f` |
| `blocks` | 1 | `13a8a75a2d1b7817cc5425e0c72366fe` |
| `booking_sources` | 12 | `82974a8c33093b5c018cdf683343250a` |
| `branch_media` | 0 | `empty` |
| `branch_memberships` | 0 | `empty` |
| `branch_whatsapp_channels` | 1 | `35f77f5a0937253e81786497c91415d3` |
| `branches` | 1 | `a15cf7f37aa2886d9371dc8ce3da3acf` |
| `cash_accounts` | 2 | `fb3a13e03bcb4b2c1818b59c4a16af4f` |
| `checkout_inspections` | 1 | `bb5f5c2b29f3867b3f3c79ebb46b9321` |
| `client_errors` | 13 | `b23fe5a71d98ea95599c8e2741caaeea` |
| `code_rotation_events` | 3 | `9ac37ba1f7c6a9c508787f2a9427165c` |
| `conversation_messages` | 250 | `ea67a666426e32ba34878db888883af9` |
| `conversations` | 123 | `6287f02dd2b909724913f522fbc4039a` |
| `data_purge_requests` | 2 | `566ea0feae2ac75f69f4d3d814421437` |
| `document_sequences` | 2 | `793b76b1b311cdd6b5c4fdfcb6ba86a0` |
| `facilities` | 2 | `a1454c52a4a87e13a024367dffd1424f` |
| `financial_vouchers` | 12 | `4f1a9c5d5b339a070d41d1037b13d59a` |
| `floors` | 2 | `aa1798b4855f65793795456a181beae8` |
| `guest_bans` | 0 | `empty` |
| `guest_lookup_attempts` | 4 | `d41bee174f3e24d4aa0f4ad85fe1cc2f` |
| `guest_phone_challenges` | 0 | `empty` |
| `guest_phone_sessions` | 1 | `90f57f7fb6a83f8bceba24da26fae41c` |
| `guest_profiles` | 5 | `73346d696f6518da67ea38aed61a82ab` |
| `housekeeping_tasks` | 2 | `338765fd6ef99260e3da7ec22abd7492` |
| `human_handoff_tickets` | 1 | `8ac028f3e9ac397b9b8ece1d3004596e` |
| `integration_events` | 0 | `empty` |
| `inventory_periods` | 28 | `70e5c7a8eaf1633f74b83aa8d9569a07` |
| `invoices` | 4 | `50a70bedff5e0f5775c8067dde38e14d` |
| `keyboxes` | 10 | `138f977020de59b1b3023b9a8eaadaa9` |
| `knowledge_entries` | 10 | `d66598ccc1ae2d0579f3e9ba203b6476` |
| `maintenance_tickets` | 1 | `83858c9483ad85055eb1f75d17520786` |
| `monitor_runs` | 1 | `4e0d77bfa80502921f6cae793e4baa73` |
| `notifications` | 2 | `8b36bf74262b5cc945d8bccb3cde86fa` |
| `organizations` | 1 | `6165fbcb4de2379de1ad27cb71f1d5e9` |
| `payment_transactions` | 1 | `516176dab503c0a2cbdb790cc6b42957` |
| `platform_payouts` | 0 | `empty` |
| `pos_settlements` | 1 | `7a87e3639a4fa8e68b5e139bd6756fb3` |
| `property_policies` | 7 | `5bd8e62169fefca310701e2cc210f856` |
| `rate_calendar` | 0 | `empty` |
| `registration_sessions` | 1 | `10d38d709e69b1bf00bc9a373da5d4b9` |
| `release_rules` | 2 | `409b07f8f53f2c7ee6c8a153b773cb17` |
| `released_slots` | 14 | `394d5ebe5e4a2b1b148a04711f0a9152` |
| `reservation_allocations` | 5 | `6a0836d6fe7e1c0c617a2cbb9d9dcef1` |
| `reservation_charges` | 12 | `cb7f0c2867bff2ce0e0e5a97e60d2764` |
| `reservation_guests` | 6 | `f6777d2ab93194ce93c2dba9645b8cfd` |
| `reservation_nights` | 16 | `487e5e8d4f24ca6a4806fbf4b841e65c` |
| `reservations` | 5 | `efc8d88824427ff66d6b6ba3263885cc` |
| `review_items` | 2 | `8b71532a0baac0a1a99a686f44c03b89` |
| `role_permissions` | 0 | `empty` |
| `room_categories` | 2 | `3e4090608419943b10f7bf6ea983a7e1` |
| `rooms` | 10 | `a2800599022a6ef6d9becf2b87677e7c` |
| `service_definitions` | 1 | `f4bef283947689922b413f304ac63406` |
| `staff_profiles` | 1 | `9c647393ee0dd1b390cb6ec6ad9034d4` |
| `staff_saved_views` | 0 | `empty` |
| `stay_acknowledgements` | 2 | `b13209c6230a025ca851cffa7fa9e4fd` |
| `stay_payment_exceptions` | 1 | `f1c497c50fae6b6e8fecc8e132494495` |
| `system_settings` | 1 | `413e33a99b9e1f4227944452dfb95f6b` |
| `task_types` | 3 | `acc07e3fbc3bd89855129bd3bad74780` |
| `unanswered_questions` | 0 | `empty` |
| `whatsapp_inbound_messages` | 0 | `empty` |
| `whatsapp_outbox` | 0 | `empty` |
