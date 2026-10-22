/*
# 0007a — Enum additions (kept in their own migration: new enum values cannot be
used inside the same transaction that adds them).

- reservation_status: + no_show (distinct from cancelled, as observed in Zaaer usage)
- payment_method: + cash, mada, card, bank_transfer, ota_deferred (manual settlement
  methods seen in Zaaer; a "network device/mada" payment is a payment method, not a POS module)
*/
alter type reservation_status add value if not exists 'no_show';

alter type payment_method add value if not exists 'cash';
alter type payment_method add value if not exists 'mada';
alter type payment_method add value if not exists 'card';
alter type payment_method add value if not exists 'bank_transfer';
alter type payment_method add value if not exists 'ota_deferred';

alter type payment_status add value if not exists 'overpaid';
