#!/usr/bin/env bash
# Repairs time_zones.country_id in user_management after usermgmt's own
# regional-data reseed replaced countries with fresh IDs. This is the
# actual table the org-create "TimeZone" dropdown queries
# (GET /v1/regional/timezones/:country_id) — fix-address-regional-links.sh
# fixed address.country_id/state_id, a different table, which is why that
# fix didn't resolve this dropdown.
#
# time_zones itself was never touched by the reseed (still 427 rows, same
# as the original export) — only its country_id values are stale, still
# pointing at the old, now-deleted country rows. Since the reseeded
# countries table presumably has the same names just new IDs, this
# resolves each time_zones row's old country_id to a name (via the
# original countries.csv) and updates it to the current matching country's
# id — same technique as fix-address-regional-links.sh, just applied to
# time_zones' own country_id column directly instead of a historical
# per-row reference.
#
# Usage:
#   DB_PASSWORD=secret ./fix-timezones-country-links.sh <db_name> <user_management_csv_dir> [db_host] [db_port] [db_user]
#
# <user_management_csv_dir> must contain the ORIGINAL countries.csv (the
# same normalized folder from prepare-csv-dir.sh used for the original
# import) — address.csv/states.csv aren't needed for this one.
set -euo pipefail

usage() {
  cat <<EOF
Usage: DB_PASSWORD=... $0 <db_name> <user_management_csv_dir> [db_host] [db_port] [db_user]
EOF
}

DB_NAME="${1:?$(usage)}"
CSV_DIR="${2:?$(usage)}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"
DB_USER="${5:-postgres}"
: "${DB_PASSWORD:?Set the DB_PASSWORD environment variable first}"

export PGPASSWORD="$DB_PASSWORD"
PSQL=(psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME")

if [ ! -f "$CSV_DIR/countries.csv" ]; then
  echo "ERROR: $CSV_DIR/countries.csv not found — point this at the normalized User Management export directory" >&2
  exit 1
fi

SQL_FILE="$(mktemp)"
trap 'rm -f "$SQL_FILE"' EXIT

{
  header_line="$(head -n 1 "$CSV_DIR/countries.csv")"
  IFS=',' read -ra header_cols <<< "$header_line"
  colspec=""
  for c in "${header_cols[@]}"; do
    c="${c%$'\r'}"; c="${c#\"}"; c="${c%\"}"
    if [ -n "$colspec" ]; then colspec+=","; fi
    colspec+="\"${c}\" TEXT"
  done
  abspath="$(realpath "$CSV_DIR/countries.csv")"
  echo "CREATE TEMP TABLE \"__old_countries\" (${colspec});"
  echo "\\copy \"__old_countries\" FROM '${abspath}' WITH (FORMAT csv, HEADER true)"

  cat <<'SQL'
\echo 'time_zones rows before fix, by whether their country_id currently resolves:'
SELECT
  count(*) FILTER (WHERE nc.id IS NOT NULL) AS already_ok,
  count(*) FILTER (WHERE nc.id IS NULL) AS needs_fix
FROM time_zones tz
LEFT JOIN countries nc ON nc.id = tz.country_id;

UPDATE time_zones tz
SET country_id = nc.id
FROM "__old_countries" oc
JOIN countries nc ON nc.name = oc.name
WHERE tz.country_id = oc.id::uuid
  AND NOT EXISTS (SELECT 1 FROM countries c2 WHERE c2.id = tz.country_id);

\echo 'time_zones rows after fix:'
SELECT
  count(*) FILTER (WHERE nc.id IS NOT NULL) AS resolves_now,
  count(*) FILTER (WHERE nc.id IS NULL) AS still_broken
FROM time_zones tz
LEFT JOIN countries nc ON nc.id = tz.country_id;

DROP TABLE "__old_countries";
SQL
} > "$SQL_FILE"

"${PSQL[@]}" -f "$SQL_FILE"

echo "Done. 'still_broken' should be 0 (or close to it) if every historical country name matched a current one."
