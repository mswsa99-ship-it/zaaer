# Hotel exit (plan item 2.12)

The documented owner-only path for leaving the platform: **export everything, then suspend, then delete** — a deliberate, confirmed procedure run by the hotel's owner, with a restorable archive.

This directory holds an operator CLI plus the SQL test suite. **Nothing here is wired into the app or the operator panel**; the path is not live by default. The mechanics live in migration `0102` (`supabase/migrations/20261124220000_0102_hotel_exit.sql`); this CLI is a thin, documented wrapper over those RPCs.

## The procedure

1. **Export** — `fn_hotel_exit_export(p_org)` copies every row of the hotel from all current hotel-linked tables discovered by `fn_hotel_exit_tables()` (plus the registry row) into `hotel_exit_archives` + `hotel_exit_rows`, and writes a manifest: per-table row counts and SHA-256 hashes, an overall hash, and the list of file-bearing tables (`branch_media`, `branch_media_items`, `expense_attachments`, organization logo) whose bytes are inside the archive. The hotel keeps running after export; a later re-export supersedes the earlier one.
2. **Verify** — `fn_hotel_exit_verify(p_archive)` re-counts and re-hashes the live tables against the manifest. Delete refuses a stale or corrupted export (`EXIT: export_stale`).
3. **Suspend** — `fn_hotel_exit_suspend(p_org)` sets `platform_status = 'suspended'`, ends every staff session, and the guest site stops answering. Suspension requires a completed export.
4. **Delete** — `fn_hotel_exit_delete(p_org, p_confirm_name, p_confirm_id)` requires suspension, the hotel's **exact Arabic name** and its **id** (never an email address), and a verified fresh export. It removes the hotel's rows children-first across the tenancy tables, removes the staff's auth accounts, and leaves the registry row as a scrubbed tombstone (`license_status = 'exited'`, `exited_at` set, name kept for the record, logo/license fields nulled). The archive stays behind as the restorable copy.
5. **Restore** — `fn_hotel_exit_restore(p_org, p_archive, p_confirm_id)` puts every archived row back (trigger-free so the seed defaults don't duplicate), re-creates the auth accounts by their original ids, and returns the hotel to the platform status it had at export. Reactivation after that is the platform operator's decision (0082).

Every step re-checks the caller: a live session and an active `owner` staff row **of that hotel**. Visitors, managers, supervisors, owners of other hotels, and (after deletion) the former owner are all refused.

## What is kept on purpose

- `audit_events` and `platform_events` are **retained, not deleted**. They are immutable by design (0088's audit purge is the single sanctioned exception), so they are exported and hashed but their live rows stay.
- The `organizations` registry row stays as the tombstone described above.
- The archive tables themselves stay until an operator removes them by hand; they are RLS-locked to the service role.

## Using the CLI (local / operator environment)

```bash
export PGHOST=... PGPORT=... PGUSER=... PGDATABASE=...
export EXIT_OWNER_SUB=<the owner's auth.users id>   # the CLI runs the calls as the owner's session

scripts/hotel-exit/hotel-exit.sh status  --org <hotel-uuid>
scripts/hotel-exit/hotel-exit.sh export  --org <hotel-uuid> --out ./hotel-dump   # manifest.json + rows.json + export-result.json
scripts/hotel-exit/hotel-exit.sh verify  --org <hotel-uuid>
scripts/hotel-exit/hotel-exit.sh suspend --org <hotel-uuid>
scripts/hotel-exit/hotel-exit.sh delete  --org <hotel-uuid> --name 'الاسم العربي بالضبط'            # dry-run
scripts/hotel-exit/hotel-exit.sh delete  --org <hotel-uuid> --name 'الاسم العربي بالضبط' --confirm # executes
scripts/hotel-exit/hotel-exit.sh restore --org <hotel-uuid> --archive <archive-uuid>
```

The CLI needs a database role allowed to set `request.jwt.claim.sub` — i.e. a local or operator connection, never the anon/authenticated API roles. The RPCs enforce the owner guard regardless of how they are reached.

## Hosted-project notes (not exercised locally)

- **Auth re-invite**: locally, restore re-inserts bare `auth.users` rows by id. On hosted Supabase, the operator must re-invite the staff (password/MFA reset) through the auth admin API; the archive preserves ids, never credentials.
- **Storage**: this deployment keeps file bytes inline (`bytea`), so the archive already contains them. If a future migration moves files to object storage, the export must also copy the objects before delete.
- A failed export mid-run leaves the archive marked `failed`; delete keys only on a `completed` archive that verifies.

## Proof

`tests/hotel-exit/hotel_exit_tests.sql` (59 checks, wired into `tests/sql/run.sh` via the delivered `wiring.diff`) runs the whole lifecycle on a throwaway database with two hotels: every refusal, the order enforcement, the name/id confirmation, the stale/corrupt-export blocks, the other hotel's byte-for-byte isolation, the tombstone, and a full restore with per-table count and content matches.

## Catalog changes (0107)

Migration `20261125070000_0107_hotel_exit_catalog.sql` replaces the fixed table
list with real public tables that have `organization_id`, ordered children-first
using their foreign keys. It includes finance refund approvals and hotel-scoped
backup runs. Global backup runs (`organization_id IS NULL`) do not belong to a
hotel and stay untouched. Audit rows stay retained as before.

An FK cycle refuses the operation rather than dropping constraints or skipping
tables. Export again after the set of tables changes: verify/delete/restore reject
an archive with a different table set (`EXIT: archive_catalog_outdated`). An
already-deleted archive with an old catalog needs an operator-reviewed schema
compatibility plan, not a forced restore. Restores preserve identity column
values, including `backup_runs.seq`, with `OVERRIDING SYSTEM VALUE`.

The independent all-tables completeness assertion remains in the SQL suite.
Expected manifest totals use catalog count plus registry/support, not a frozen
number. Run with nonempty refund and backup fixtures:

```bash
psql -X -v ON_ERROR_STOP=1 -f tests/hotel-exit/hotel_exit_tests.sql
```
