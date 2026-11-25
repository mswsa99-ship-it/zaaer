#!/usr/bin/env bash
# EXAMPLE ONLY, never run by this repo. Storage file contents are not in a database dump.
# To cover them the owner must approve a service credential and a destination. Until then they are NOT backed up.
# Reads secrets from the environment only: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (owner-set), OUT_DIR.
# Writes an inventory (bucket, path, size, etag) so a later copy can be verified object by object.
set -euo pipefail
: "${SUPABASE_URL:?}" "${SUPABASE_SERVICE_ROLE_KEY:?}" "${OUT_DIR:?}"
echo "template: list buckets and objects via the Storage API, write ${OUT_DIR}/storage-inventory.tsv," >&2
echo "copy bytes to the approved destination, then compare size and etag. Not implemented on purpose." >&2
exit 2
