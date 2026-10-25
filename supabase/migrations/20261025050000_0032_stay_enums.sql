-- =====================================================================
-- 0032 — the stay cycle (Phase 3), its one new access state, on its own so that 0033 can use it.
--   key_handed: the arrival is registered in a unit that has no key box; its ordinary key is handed over at
--   reception and there is no code to deliver (decision 1).
-- =====================================================================
alter type access_status add value if not exists 'key_handed';
