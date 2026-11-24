# Tax-on paid-order fixture qualification

Net-only supplement to aa17358. No adapter or cancellation acceptance added here.

Reviewed cumulative candidate0bf7f1b3against canonical fixture, extracted only the new paidordertax block. Corrected its misleading all-production-path comment: it creates its own stay through normal local owner RPCs, then explicitly updates only that synthetic reservation's tax_products_rate_bp=1500 and prices_include_tax=false. The production snapshot trigger runs only before INSERT and normally derives from branch settings. This direct local state construction tests cancellation against an existing15%added-tax snapshot, not branch tax configuration or trigger behavior. Base branch settings and victims stay unchanged.

Before execution, canonical disposable PG16catalog rechecked: notifications has tenant-fill and hotel-pointer triggers only; extensions pgcrypto/uuid-ossp/plpgsql/btree_gist, no network/vault/cron extension. Minimal setup reuses qualified paid fixture RPC paths, no keybox/delivery or all-family preload. Local identity encryption uses the bootstrap literal test setting for this connection only, not a real secret. No messages or spending.

Only extracted block executed atomically in iso_credit1745, setup exit0.4targets now have paid orders,15%tax snapshot, prices tax-exclusive, approved cash receipts, pending tasks, one addon and one positive tax charge, and exact registered notification identities. Observed addon7001/7002/7003/7004, tax1050/1050/1050/1051. No cancellation probe rerun and no adapter count change. RPC owner must provide exact positive/foreign/effect/non-target proof before coverage credit. Tax fixture is a local test seam, not full production-path tax acceptance.
