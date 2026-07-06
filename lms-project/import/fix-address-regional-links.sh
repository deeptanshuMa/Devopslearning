#!/usr/bin/env bash
# Repairs address.country_id / address.state_id in user_management after
# usermgmt's own regional-data reseed replaced countries/states with fresh
# IDs, orphaning historical address rows that pointed at the old ones
# (confirmed: address.timezone_id survived fine since time_zones was never
# replaced; country_id/state_id did not, since countries/states were).
#
# Strategy: the CURRENT countries/states tables presumably hold the same
# set of names, just new IDs. So: read the ORIGINAL export's countries.csv
# and states.csv to get old_id -> name (and state's old_country_id for
# disambiguation), read the ORIGINAL export's address.csv to get each
# address row's old country_id/state_id, then re-resolve each to the
# CURRENT id with the same name and UPDATE the live address table.
#
# Usage:
#   DB_PASSWORD=secret ./fix-address-regional-links.sh <db_name> <user_management_csv_dir> [db_host] [db_port] [db_user]
#
# <user_management_csv_dir> is the normalized folder from prepare-csv-dir.sh
# for the "User Management" export (must contain address.csv, countries.csv,
# states.csv — the ORIGINAL historical files, not already-repaired ones).
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

for f in address countries states; do
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
  stage_from_csv "$CSV_DIR/states.csv" "__old_states"
  stage_from_csv "$CSV_DIR/address.csv" "__old_address"

  cat <<'SQL'
-- Resolve country_id: old address.country_id -> old country name -> current country id
UPDATE "address" a
SET country_id = nc.id
FROM "__old_address" oa
JOIN "__old_countries" ocm ON ocm.id::uuid = oa.country_id::uuid
JOIN countries nc ON nc.name = ocm.name
WHERE a.id::uuid = oa.id::uuid
  AND oa.country_id IS NOT NULL AND oa.country_id <> ''
  AND a.country_id IS NULL;

-- Resolve state_id: old address.state_id -> old state name + old state's
-- country name -> current state id (matched by name AND current country_id,
-- to disambiguate states that share a name across countries)
UPDATE "address" a
SET state_id = ns.id
FROM "__old_address" oa
JOIN "__old_states" osm ON osm.id::uuid = oa.state_id::uuid
JOIN "__old_countries" ocm ON ocm.id::uuid = osm.country_id::uuid
JOIN countries nc ON nc.name = ocm.name
JOIN states ns ON ns.name = osm.name AND ns.country_id = nc.id
WHERE a.id::uuid = oa.id::uuid
  AND oa.state_id IS NOT NULL AND oa.state_id <> ''
  AND a.state_id IS NULL;

\echo 'Rows with a resolved country_id now:'
SELECT count(*) FROM "address" WHERE country_id IS NOT NULL;
\echo 'Rows with a resolved state_id now:'
SELECT count(*) FROM "address" WHERE state_id IS NOT NULL;

DROP TABLE "__old_countries";
DROP TABLE "__old_states";
DROP TABLE "__old_address";
SQL
} > "$SQL_FILE"

"${PSQL[@]}" -f "$SQL_FILE"

echo "Done. Compare the two counts above against the original CSV's non-blank counts (418 country_id, 409 state_id) to see how many resolved."
