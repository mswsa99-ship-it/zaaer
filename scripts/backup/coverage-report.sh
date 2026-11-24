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
echo "schemas in the dump:"; pg_restore --list "$W/db.dump" | awk '/ SCHEMA - /{print "  " $NF}' | sort -u
echo "fingerprinted (counts+hashes proven on restore): public schema tables only"
echo "NOT covered: Supabase Auth settings/providers/templates, Storage bucket objects (files), Edge function code and secrets,"
echo "             project config, the encryption passphrase itself, vault contents. Each needs its own approved path."
