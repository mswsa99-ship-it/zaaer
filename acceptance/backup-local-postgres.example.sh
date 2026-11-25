#!/usr/bin/env bash
# Runs a command with a throwaway local PostgreSQL 14 (Ubuntu binaries extracted to /tmp/pg14) on a unix socket.
# Usage: pg-with.sh <command...>   — PGHOST/PGPORT/PGUSER are set for the command; server stops when it exits.
set -euo pipefail
PGBIN=/tmp/pg15/root/usr/lib/postgresql/15/bin
PGDATA="${PGDATA:-/tmp/pgdata15}"
PGSOCK="${PGSOCK:-/tmp/pgsock15}"
rm -rf "$PGDATA" "$PGSOCK"; mkdir -p "$PGSOCK"
export LC_ALL=C
"$PGBIN/initdb" -D "$PGDATA" -U postgres --auth=trust --no-instructions --encoding=UTF8 --locale=C.utf8 >/dev/null
"$PGBIN/pg_ctl" -D "$PGDATA" -l /tmp/pg-h.log -o "-k $PGSOCK -p 55435 -c listen_addresses=''" -w start >/dev/null
cleanup() { "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true; }
trap cleanup EXIT
export PGHOST="$PGSOCK" PGPORT=55435 PGUSER=postgres
export PATH="$PGBIN:$PATH"
"$@"
