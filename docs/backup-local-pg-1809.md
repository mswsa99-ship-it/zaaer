# Item7.1 own-cluster PG16 harness

Local source6c5d843plus reviewed harness. This is not an operational backup schedule or full disaster recovery acceptance.

Rejected v1 existing-socket/fixed-name path before execution. Reviewed v2 own-initdb-only cluster with no TCP, verified data_directory and empty cluster, random collision-checked DB names, checked bootstraps/migrations, retained raw logs. Added clearing of inherited BACKUP configuration except evidence path, preventing external upload hooks/restore override/connection inheritance. PG environment overrides are also cleared.

Replaced weak concurrent writer loop (could suppress all insert failures) with a deterministic PATH wrapper around pg_dump: backup exports its snapshot and finishes manifest, then20successful local synthetic guest rows commit before the actual pg_dump imports the same snapshot. Restored backup has0post-snapshot rows while final source has20. This proves shared-snapshot consistency at that boundary, not a sustained production concurrency workload. No production backup script changed.

Evidence:21backup static/local-file tests pass, including2red tests before inherited-env/writer fixes. Own PG16run H01–H11 and subchecks:16PASS, failures0, skips0, exit0.117public tables/576rows restored with identical manifest hashes. Tested backup state success, exact restore, archive verification, local-fetch hook, restore drill+scratch cleanup, nonempty-target rejection, wrong passphrase, changed sidecar, corrupt archive, untouched target on failure, deterministic snapshot writer, and failed-source state recording.

A new throwaway cluster was created on a private temporary Unix socket and stopped/deleted at completion. It applied schema migrations only, no all-family application-RPC fixtures. Synthetic300row seed and20writer rows only; random local encryption passphrase never printed and removed with temporary files. No network listener, real user data, vault secret, Drive or external upload. Logs retained under /tmp/roomai-backup-pg1809. Encrypted archives temporary, not an operational backup artifact.

Open: real remote transport/configuration, active weekly/predeploy schedule, monthly drills and alerting, Auth/Storage/Edge/secrets recovery, production destination/key/restore authority. Missing-extension real-server negative was not exercised here. These prevent item7.1global acceptance.
