# النسخة الاحتياطية — 23 نوفمبر 2026، 06:17 UTC (قبل مسح بيانات التجربة)

نسخة كاملة من بيانات النظام قبل مسح بيانات الحجوزات والنزلاء والمال التي أُدخلت في مرحلة البناء والتصحيح (قرار المالك ق1، 23 نوفمبر).

| الجزء | أين | ما فيه |
| --- | --- | --- |
| الكود | أب هذا الإيداع: `5daaaca` (المنشور على `develop` وقت النسخة) | الواجهة والدوال والترحيلات حتى 0072 |
| قاعدة البيانات | `zaaer-db-2026-11-23-0617.sql.gz.enc` في هذا المجلد | كل صفوف الجداول الـ 100 في `public` (5,168 صفًا) لمشروع Supabase `ojcxkyyyhbbkqannemex` |

**وقت أخذها:** 2026-11-23 06:17 UTC (09:17 بتوقيت الرياض). كان المشروع عند 74 قيدًا في سجل الترحيلات، آخرها `20261115120000` (0072).

**ليس فيها:** حسابات الدخول ومفاتيح Vault وأسرار الدوال. فيها بيانات شخصية للضيوف (منها 2,452 نزيلًا مستوردًا من زائر)، لذلك لا تُحفظ إلا مشفّرة.

**كيف أُخذت:** صُدّرت الصفوف مشفّرةً من القاعدة بمفتاح نقل لمرة واحدة (دفعتان: ملفات الضيوف ثم بقية الجداول)، ثم فُكّت محليًا وبُني منها سكربت الاستعادة من نص JSON كما صدر (دون إعادة صياغة الأرقام).

## التشفير والمفتاح

gzip ثم AES-256-CBC بمفتاح مشتق بـ PBKDF2-SHA256 (600,000 تكرار). **المفتاح ليس في المستودع**: في Google Drive للمالك، مجلد «Zaaer — النسخ الاحتياطية»، ملف `zaaer-backup-key-2026-11-23-0617.txt`.

| الملف | SHA-256 |
| --- | --- |
| `zaaer-db-2026-11-23-0617.sql.gz.enc` | `70f16ebe5063e6b5073831052406585f9e39d08b9a33ceb2c792128262e77582` |
| `zaaer-db-2026-11-23-0617.sql.gz` | `7df2e9c7fb08ce6d428c005c36873acc027909259fff1ea265ca5b43837e731b` |
| `zaaer-db-2026-11-23-0617.sql` | `31d10b169dcc73718f70867e77a4b51f78d5a8341ca92e5abd6660bca2c0aeeb` |

## الاستعادة (عند الضرورة فقط)

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in zaaer-db-2026-11-23-0617.sql.gz.enc -out zaaer-db-2026-11-23-0617.sql.gz -pass file:passphrase.txt
gunzip zaaer-db-2026-11-23-0617.sql.gz
sha256sum zaaer-db-2026-11-23-0617.sql     # يطابق الجدول أعلاه
psql "$DB_URL" -f zaaer-db-2026-11-23-0617.sql
```

السكربت معاملة واحدة: يتوقف دون تغيير إن اختلف سجل ترحيلات الهدف عن الـ74، ثم يفرّغ جداول `public` ويعيد صفوفها كما كانت.

## ما جُرِّب قبل حفظها

- **تجربة الاستعادة:** قاعدة جديدة بالترحيلات الـ74 استقبلت النسخة: الجداول الـ100 مطابقة للإنتاج عددًا وبصمة (5,168 صفًا).
- **فك التشفير ذهابًا وإيابًا:** طابق الملف المضغوط بايتًا ببايت.

## الجداول

| الجدول | الصفوف | البصمة (md5) |
| --- | --- | --- |
| `access_delivery_events` | 0 | `empty` |
| `access_release_requests` | 0 | `empty` |
| `accounting_periods` | 0 | `empty` |
| `ai_action_proposals` | 1 | `944180b581e38d8af9dccb6cc9790e91` |
| `ai_guardrail_events` | 67 | `5cfd272ef288a1381dde7293bfc9f465` |
| `ai_ops_conversations` | 6 | `14a4853e98f7584afde32bb361178fba` |
| `ai_ops_messages` | 20 | `d5f991ecd2b5a014cf5b028cb3e2a466` |
| `ai_settings` | 1 | `998f096b050ce755f1078f23ef078aec` |
| `ai_tool_executions` | 7 | `08d993898572e7202b90885e71fd00fa` |
| `ai_usage_daily` | 13 | `aadff1f447283dbf37b571049bb219f3` |
| `alert_events` | 2 | `5811007c14eedd8582ba989611a945e7` |
| `alert_rules` | 8 | `b5016bcfd663a3051950d3e20a63a174` |
| `audit_events` | 379 | `fc224a71a53ca5c54ccfadc7a13534c8` |
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
| `checkout_inspections` | 2 | `dba92e9de2f0546447708d630ff81a7d` |
| `client_errors` | 40 | `c9e61b2ec5c9c4c2d24068612bc33fee` |
| `code_rotation_events` | 3 | `fbd7f061bcdb081811084e5d85893f19` |
| `conversation_messages` | 308 | `b401cd89c89445b1711c087838e2162e` |
| `conversations` | 154 | `85811511abbd6827e5120a1f85c68934` |
| `data_purge_requests` | 2 | `68944f998d31f1b4fc880b6e76bd116b` |
| `day_closing_lines` | 3 | `e93213bd30ca2af53cb37198bdfd40e6` |
| `day_closing_requests` | 0 | `empty` |
| `day_closings` | 1 | `595e3781c82f5b8287e1ff14edd44fb0` |
| `document_sequences` | 4 | `3eb7cc8c397774700556e5d4dbb64fc7` |
| `expense_attachments` | 1 | `cdbc2c05b98741d67af6b7bc91c5a01c` |
| `expense_categories` | 12 | `c8bf8eff221c4f473ab14b1da953ac16` |
| `expense_vouchers` | 1 | `d2addf45074fe42933149cd0f7fff272` |
| `facilities` | 2 | `61f5da8eeb1ed2ed38c74fd435f732d3` |
| `financial_vouchers` | 46 | `f60d1388d5f0dca4dee10af58e451fc1` |
| `floors` | 2 | `dff7a8efbf7f2b5d74a7f8cc80c61c5a` |
| `gl_accounts` | 31 | `4d3de7c047b61c6add8ebdb1fc0c7c87` |
| `guest_bans` | 0 | `empty` |
| `guest_lookup_attempts` | 1 | `7a8c57681e61f561b1f6fc5bd783aa6b` |
| `guest_phone_challenges` | 0 | `empty` |
| `guest_phone_sessions` | 0 | `empty` |
| `guest_profiles` | 2654 | `21e583bcc8b9525a93a9717473f05d80` |
| `guest_reviews` | 2 | `1e02cb1fe738f3e83dce94b6b8fe9e10` |
| `housekeeping_tasks` | 5 | `01c39539142a70112b2853a27a20e3c2` |
| `human_handoff_tickets` | 0 | `empty` |
| `integration_events` | 0 | `empty` |
| `inventory_periods` | 28 | `867e83c2ce30714d45c3f94c29c7c36d` |
| `invoices` | 3 | `e91ba6ed62ade987c700aeb950eb773f` |
| `journal_entries` | 48 | `e0f326f142832a5409d518f60863657f` |
| `journal_lines` | 96 | `cbe9fe4d2c0c436e2e9850d3ef4fb92d` |
| `journey_messages` | 6 | `542deb32118e4987e4993d0fe0cd89ff` |
| `journey_ticks` | 2 | `5cebf32e4dc0aa3fc8ddee59100290bc` |
| `keyboxes` | 10 | `12ae003ffbd2013501a9721575bb8b6c` |
| `knowledge_entries` | 10 | `9a2361604d15dbffb164c08dd9ca4807` |
| `maintenance_tickets` | 0 | `empty` |
| `monitor_runs` | 3 | `4d92aee11391f5da9cb7a3c846255b3f` |
| `notifications` | 3 | `d1ce95cd28429d571907ff00312ad03e` |
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
| `reservation_allocations` | 8 | `41ed141f81d4f6238dbf550ac477f171` |
| `reservation_charges` | 217 | `c6abb67d80174e527d02d1f249634836` |
| `reservation_guests` | 215 | `02e0cc570683d27ca36a3b2ff14baf41` |
| `reservation_nights` | 359 | `c2707e26bb144e2ff70808c6439d30f6` |
| `reservations` | 215 | `f383bdd6ade9fbd5edae7114d29bec4d` |
| `review_items` | 3 | `fb41b2021ddd0a71ee98bc71d1b14a6d` |
| `role_permissions` | 0 | `empty` |
| `room_categories` | 5 | `67805ba1d54e5c759b5f78d9588a96f3` |
| `rooms` | 34 | `fa581ccdb86088d5a93c331ddc15e827` |
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
