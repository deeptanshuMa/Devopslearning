#!/usr/bin/env bash
# Imports a "one CSV per table" Postgres data export into a target database.
#
# All tables in these repos use UUID primary keys (DataTypes.UUIDV4 /
# gen_random_uuid()), so there's no SERIAL sequence to fix up afterwards —
# the only real risk is foreign-key ordering across ~50-80 tables per DB.
# This script sidesteps that by disabling FK/trigger checks for the
# duration of the import (`session_replication_role = replica`, needs the
# `postgres` superuser role) instead of hand-computing a topological load
# order.
#
# PREREQUISITE: start the target service once first (e.g. `node bin/www`)
# so Sequelize's `sync()` creates the empty schema. This script only
# inserts rows into tables that must already exist.
#
# Usage:
#   DB_PASSWORD=secret ./import-tables.sh <db_name> <csv_dir> [db_host] [db_port] [db_user]
#
# Example:
#   DB_PASSWORD=secret ./import-tables.sh user_management ./dumps/user_management
#
# Each file in <csv_dir> must be named "<table_name>.csv" and have a header
# row whose column names match the Postgres table's columns exactly. Run
# `psql -d <db_name> -c '\dt'` after the schema-creation step to confirm
# real table names (a few models set an explicit `tableName`, e.g. `address`,
# `student_parent` — these don't match the model's variable name).
#
# Set TRUNCATE_FIRST=true to empty each target table before loading, useful
# if an earlier partial/failed import already put some rows in.

set -euo pipefail

usage() {
  cat <<EOF
Usage: DB_PASSWORD=... $0 <db_name> <csv_dir> [db_host] [db_port] [db_user]
EOF
}

DB_NAME="${1:?$(usage)}"
CSV_DIR="${2:?$(usage)}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"
DB_USER="${5:-postgres}"
: "${DB_PASSWORD:?Set the DB_PASSWORD environment variable first}"
TRUNCATE_FIRST="${TRUNCATE_FIRST:-false}"

export PGPASSWORD="$DB_PASSWORD"

shopt -s nullglob
csv_files=("$CSV_DIR"/*.csv)
if [ ${#csv_files[@]} -eq 0 ]; then
  echo "No .csv files found in $CSV_DIR" >&2
  exit 1
fi

SQL_FILE="$(mktemp)"
trap 'rm -f "$SQL_FILE"' EXIT

{
  echo "SET session_replication_role = replica;"
  for f in "${csv_files[@]}"; do
    table="$(basename "$f" .csv)"
    abspath="$(realpath "$f")"
    if [ "$TRUNCATE_FIRST" = "true" ]; then
      echo "TRUNCATE TABLE \"${table}\";"
    fi
    echo "\\echo Importing ${table}..."
    echo "\\copy \"${table}\" FROM '${abspath}' WITH (FORMAT csv, HEADER true)"
  done
  echo "SET session_replication_role = DEFAULT;"
} > "$SQL_FILE"

psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SQL_FILE"

echo "Done importing ${#csv_files[@]} table(s) into '${DB_NAME}'."
