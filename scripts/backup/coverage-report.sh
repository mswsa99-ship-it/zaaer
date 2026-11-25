#!/usr/bin/env bash
# What a given archive does and does not cover (item 7.1). Prints schemas present in the dump and the fixed
# list of things this backup never covers. Usage: coverage-report.sh <archive.tar.gpg>
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
source scripts/backup/lib.sh
A="${1:-}"; [ -f "$A" ] || backup_die "usage: coverage-report.sh <archive.tar.gpg>"
backup_check_tools; backup_check_passphrase_file
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
gpg --batch --yes --quiet --decrypt --passphrase-file "$BACKUP_PASSPHRASE_FILE" --output "$W/f.tar" "$A" || backup_die "decryption failed"
python3 scripts/backup/unpack.py "$W/f.tar" "$W" bundle.tar bundle.sha256
python3 scripts/backup/unpack.py "$W/bundle.tar" "$W" db.dump manifest.tsv
pg_restore --list "$W/db.dump" > "$W/toc.txt"
echo "schemas in the dump:"; awk '/ SCHEMA - /{print "  " $(NF-1)}' "$W/toc.txt" | sort -u
echo "per schema (table definitions / table data entries in the dump; rows are not counted here):"
backup_toc_coverage "$W/toc.txt" | awk -F'\t' '{printf "  %s: %s tables, %s with data\n", $1, $2, $3}'
if backup_toc_coverage "$W/toc.txt" | awk -F'\t' '$1=="auth" && $3>0 {f=1} END{exit !f}'; then
  echo "auth: user table DATA is in this dump (may include password hashes). It is not fingerprinted and not restore-verified; the archive must stay encrypted."
else
  echo "auth: no table data in this dump."
fi
if backup_toc_coverage "$W/toc.txt" | awk -F'\t' '$1=="storage" && $3>0 {f=1} END{exit !f}'; then
  echo "storage: object METADATA rows are in this dump. The file contents (bytes) are never in a database dump."
else
  echo "storage: no metadata data in this dump; file contents are never in a database dump."
fi
echo "fingerprinted (counts+hashes proven on restore): public schema tables only"
echo "NOT covered: Supabase Auth settings/providers/templates, Storage file contents, Edge function code and secrets,"
echo "             project config, the encryption passphrase itself, vault contents. Each needs its own approved path."
