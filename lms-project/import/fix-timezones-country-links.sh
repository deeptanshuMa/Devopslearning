#!/usr/bin/env bash
# Repairs time_zones.country_id in user_management. This is the actual
# table the org-create "TimeZone" dropdown queries
# (GET /v1/regional/timezones/:country_id) — fix-address-regional-links.sh
# fixed address.country_id/state_id, a different table, which is why that
# fix didn't resolve this dropdown.
#
# CORRECTED (v2): the live time_zones.country_id turned out to be
# genuinely NULL already, not just pointing at stale old IDs — the same
# nulling that hit address.country_id/state_id also hit this column
# (time_zones' own id and row count are intact, only country_id was
# wiped). That means there's nothing left in the live table to "resolve
# by old ID" — the old ID itself is gone. So this version goes back to
# the ORIGINAL time_zones.csv export to recover each row's old country_id
# (matching by time_zones' own id, which is unchanged), resolves that old
# country_id to a name via the original countries.csv, then finds the
# matching current country by name and updates the live row — same
# technique as fix-address-regional-links.sh, just keyed off time_zones.id
# instead of a separate historical foreign key.
#
# Usage:
#   DB_PASSWORD=secret ./fix-timezones-country-links.sh <db_name> <user_management_csv_dir> [db_host] [db_port] [db_user]
#
# <user_management_csv_dir> must contain the ORIGINAL countries.csv AND
# time_zones.csv (the same normalized folder from prepare-csv-dir.sh used
# for the original import).
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

for f in countries time_zones; do
  if [ ! -f "$CSV_DIR/$f.csv" ]; then
    echo "ERROR: $CSV_DIR/$f.csv not found — point this at the normalized User Management export directory" >&2
    exit 1
  fi
done

stage_from_csv() {
  local file="$1" stage="$2"
  local header_line header_cols colspec c abspath
  header_line="$(head -n 1 "$file")"
  IFS=',' read -ra header_cols <<< "$header_line"
  colspec=""
  for c in "${header_cols[@]}"; do
    c="${c%$'\r'}"; c="${c#\"}"; c="${c%\"}"
    if [ -n "$colspec" ]; then colspec+=","; fi
    colspec+="\"${c}\" TEXT"
  done
  abspath="$(realpath "$file")"
  echo "CREATE TEMP TABLE \"${stage}\" (${colspec});"
  echo "\\copy \"${stage}\" FROM '${abspath}' WITH (FORMAT csv, HEADER true)"
}

SQL_FILE="$(mktemp)"
trap 'rm -f "$SQL_FILE"' EXIT

{
  stage_from_csv "$CSV_DIR/countries.csv" "__old_countries"
  stage_from_csv "$CSV_DIR/time_zones.csv" "__old_time_zones"

  cat <<'SQL'
\echo 'time_zones rows before fix, by whether their country_id currently resolves:'
SELECT
  count(*) FILTER (WHERE nc.id IS NOT NULL) AS already_ok,
  count(*) FILTER (WHERE nc.id IS NULL) AS needs_fix
FROM time_zones tz
LEFT JOIN countries nc ON nc.id = tz.country_id;

-- Recover each row's ORIGINAL country_id from the export (matching by
-- time_zones' own id, which was never touched), resolve that old
-- country_id to a name via the original countries.csv, then find the
-- current country with that name.
UPDATE time_zones tz
SET country_id = nc.id
FROM "__old_time_zones" otz
JOIN "__old_countries" oc ON oc.id = otz.country_id
JOIN countries nc ON nc.name = oc.name
WHERE tz.id::text = otz.id
  AND otz.country_id IS NOT NULL AND otz.country_id <> ''
  AND tz.country_id IS NULL;

\echo 'time_zones rows after fix:'
SELECT
  count(*) FILTER (WHERE nc.id IS NOT NULL) AS resolves_now,
  count(*) FILTER (WHERE nc.id IS NULL) AS still_broken
FROM time_zones tz
LEFT JOIN countries nc ON nc.id = tz.country_id;

DROP TABLE "__old_countries";
DROP TABLE "__old_time_zones";
SQL
} > "$SQL_FILE"

"${PSQL[@]}" -f "$SQL_FILE"

echo "Done. 'still_broken' should be 0 (or close to it) if every historical country name matched a current one."
