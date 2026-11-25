# Backup scheduling and drill runbook (item 7.1) - proposal, nothing here is active

Status: local code and synthetic tests only. No schedule, secret, account or destination has been set up by this runbook.

## Proven vs not proven
Proven by the executor (reported, not re-run here): encrypted private Drive backup of 117 public tables / 443 rows plus a 114-row registry, restore content hash on all 117, column ACL pack 171, decrypt and hash round trip.
Not proven: Auth settings, Storage file contents, non-public schema fingerprints, any scheduled run, any monthly drill, the owner-visible "last backup" stamp, failure alerts.

## Cadence (proposed)
- Weekly backup: Sunday 02:15 UTC. `scripts/backup/backup.sh` then `verify-remote.sh` on the downloaded copy.
- Monthly restore drill: day 1, 03:15 UTC, `restore-drill.sh` into a scratch database, then `coverage-report.sh`.
- Prune: `prune.sh` dry run first; apply only after the first verified remote copy.
The cron lines in `.github/workflows/backup.yml.proposed` stay commented until the owner approves activation.

## Needs the owner must supply (unsupported by this repo)
1. Drive destination and its credential. Repo text that says "approved" is not owner approval; confirm with the owner directly.
2. Encryption passphrase file, stored and escrowed by the owner. Losing it makes every archive unreadable.
3. Database URI for the dump and a separate one for the scratch restore.
4. Failure alert route (who gets told, by what channel). Without it a failed run is silent.
5. Storage: service credential and destination for file bytes; see `storage-inventory.example.sh`.
6. Auth settings and Edge function code/secrets: export from the platform by the owner; not reachable from SQL.

## Owner-visible "last backup" stamp (spec only, not mine to build)
Backup state already goes through `fn_backup_run_start` / `fn_backup_run_finish`. An admin screen needs a read-only view over the latest row with status `success` (time, size, table and row counts, verification result) and a red state when older than 8 days. Needs a migration and a UI owner.

## First-run checklist (after approval)
Run one manual backup, one `verify-remote.sh` on the downloaded file, one restore drill, record the real results. Only then call the drill real. Local synthetic runs are never reported as real drills.
