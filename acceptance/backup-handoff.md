# 7.1 / O4 / T6: local packet, NOT CLOSED

Base: `13259190d1bf5797d9760c6250e416bf79c78a97`.
No live database access, production export, upload, deployment, email, secret configuration or push was performed.

## Delivered

- PostgreSQL custom-format dump + public-table manifest on one exported repeatable-read snapshot.
- AES256 GPG encrypted archive with inner SHA256; restore checks archive membership, hash, counts and content hashes.
- External passphrase-file reference only, restricted file mode, private temporary files, no raw provider failure text in logs.
- Upload executable hook accepts archive and sidecar as separate arguments. Real offsite destination remains unconfigured.
- Pre-deploy wrapper requires backup then successful scratch restore. Monthly drill path also uses a scratch database.
- Migration 0103 stores state, restricts writers to service_role functions and status reads to owners. Hotel owners only see rows explicitly linked to their organization. Unscoped platform backup rows are not exposed to tenant owners.
- Read-only owner page + hook. Route/nav/demo/tenancy/test-runner/production-gate changes are proposals in `backup-wiring.diff`, not applied.
- Weekly/monthly cron proposal in `scripts/backup/schedule.example.cron`, not installed.

## Executed commands and evidence

| Command / check | Result | Evidence |
| --- | --- | --- |
| SQL test without 0103 | PASS expected RED, function missing | backup-red-green/red.log |
| SQL test after 0103 | PASS, 15 checks | backup-sql-final.log |
| local synthetic dataset A backup/restore | PASS, 102 tables, 974 rows, all public table counts/hashes identical | backup-drill-1/full-run.log, manifest.tsv, restored-fingerprint.tsv |
| local synthetic dataset B backup/restore | PASS, 111 tables, 2102 rows at scheduled backup; 2103 at pre-deploy backup, all manifest counts/hashes identical | backup-drill-2/full-run.log |
| pre-deploy wrapper including scratch restore | PASS locally | backup-drill-2/pre-deploy.log |
| monthly restore-drill path | PASS locally | backup-drill-2/restore-drill.log |
| upload hook exit 7 | PASS, non-zero backup exit and failed state | backup-drill-2/f1-* |
| corrupt ciphertext | PASS refused, target remained at 0 public tables | backup-drill-2/f2-* |
| wrong generated synthetic passphrase | PASS refused | backup-drill-2/f3-* |
| restore into nonempty target | PASS refused | backup-drill-2/f4-* |
| tampered sidecar | PASS refused | backup-drill-2/f5-* |
| bash syntax, Python compile | PASS | commands run locally |
| npx tsc -b | PASS | backup-typecheck.log, backup-quick.log |
| targeted eslint of page/hook/UI check | PASS | backup-lint.log |
| production build with invalid harness-only backend URL | PASS, chunk-size warning | backup-build.log |
| Chromium UI harness, success at 1366 and 390, empty and failed at 1366 | PASS, 4 cases, zero horizontal overflow | backup-ui-check.log and PNGs |
| actual pixels | PASS inspected all four screenshots, readable/no clipping | backup-ui-*.png |
| git apply --check backup-wiring.diff | PASS, applies against this packet | local command |
| npm run verify:quick BEFORE wiring | FAIL, not a combined PASS | backup-quick.log |
| targeted contract/tenancy checks BEFORE wiring | FAIL expected until demo/tenancy wiring merged | backup-unwired-contract.log |

Initial quick-gate lint errors in the harness were fixed and targeted lint rerun successfully. The original quick log is retained as FAIL, not relabeled. The two remaining contract failures are deliberate unwired cells: new RPC absent from demo and new table absent from shared tenancy classification. Proposed fixes are in wiring.diff, not independently run as an integrated gate.

## ما جُرب / Remaining acceptance

- Full `npm run verify`, hosted CI, connected owner-page RPC end-to-end, demo parity after wiring, route authorization, AA contrast measurement, independent review, mutation test disabling guards, owner acceptance: ما جُرب.
- Live weekly schedule, monthly schedule, pre-deploy gate, destination retention, offsite readback and live restoration: ما جُرب and NOT ACTIVATED.
- Concurrency during snapshot acquisition, interrupted job cleanup and provider failure variants beyond the five drills: ما جُرب.
- Archive contains a PostgreSQL dump and manifest. Supabase Storage object bytes, external encryption keys and hosted Auth configuration are NOT backed up by this packet. Files proved are archive/bundle/dump/manifest; this is not a proof of all application files or disaster recovery.
- Monthly scratch database must be on an isolated approved restore host, not the production database cluster. The current wrapper derives a scratch database from the supplied admin connection, so operational configuration is load-bearing.
- Temporary plaintext is removed, not securely erased. Live use needs encrypted temporary storage and separately approved secrets/key recovery.
- A successful upload hook exit is not independent remote integrity proof. Production gate proposal expects an operator-provisioned hook and fails closed when missing; hosted runner integration is not ready without that host.
- No current live backup timestamp is asserted. UI screenshots are synthetic view-only fixtures, not production evidence.

Item 7.1 stays OPEN until the missing gates and approved live activation are completed.
