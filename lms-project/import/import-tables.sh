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
# row. Columns are matched BY NAME, not position, and by INTERSECTION with
# whatever columns the destination table actually has:
#
#   1. Each CSV is first loaded as-is (all columns, all TEXT) into a TEMP
#      staging table shaped to match the file exactly, so `\copy` never has
#      to reconcile column order or type differences at load time.
#   2. Then `INSERT INTO "<table>" (...) SELECT ...::<type>, ... FROM
#      staging` copies over only the columns that exist in BOTH the CSV
#      and the current table, casting each to the table's real column
#      type. Any CSV column with no matching table column is dropped (with
#      a warning); any table column with no matching CSV column is just
#      left NULL/default.
#
# This handles two real issues seen in practice:
#   - Column REORDER: Sequelize's sync() creates columns in
#     model-attribute-definition order, which isn't always the same order
#     the original export was taken in (e.g. a column moved position in
#     the model since then) — a naive positional `\copy` silently shifts
#     every column after the first mismatch.
#   - Column DRIFT: the export may contain columns the current model has
#     since dropped (e.g. `assignments.attachment`/`attachment_type`,
#     superseded by a separate attachments table), or lack columns the
#     model has since added (e.g. `assignments.session_year_id`) — a plain
#     `\copy` errors outright ("column ... does not exist") instead of
#     importing what it safely can.
#
# Run `psql -d <db_name> -c '\dt'` after the schema-creation step to
# confirm real table names (a few models set an explicit `tableName`, e.g.
# `address`, `student_parent` — these don't match the model's variable
# name).
#
# Set TRUNCATE_FIRST=true to empty every target table in this <csv_dir>
# before loading, useful if an earlier partial/failed import already put
# some rows in. All tables in the batch are truncated together in one
# CASCADE statement (see comment in the script) — if some OTHER table
# outside this batch (not one of the CSVs you're importing) has a foreign
# key into one of these tables, CASCADE will empty that table too.

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
PSQL=(psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME")

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

  # If truncating, do ALL tables in ONE combined TRUNCATE statement, before
  # any COPY starts. Truncating tables one at a time (in alphabetical/glob
  # order) fails outright on any table referenced by an FK from another
  # table in this same batch (Postgres always enforces this for TRUNCATE,
  # regardless of session_replication_role) — and naively adding CASCADE to
  # each individual TRUNCATE is worse: it can silently wipe out a table
  # that already got its fresh data loaded earlier in this same run, if
  # that table happens to reference one being truncated later (e.g.
  # "acknowledgement_attachments" sorts and loads before
  # "acknowledgements", which it has an FK to — a later per-table CASCADE
  # truncate of "acknowledgements" would cascade-delete the
  # already-reloaded attachments rows, with nothing left to reload them).
  # Truncating every table in the batch together, up front, avoids that
  # ordering hazard entirely.
  if [ "$TRUNCATE_FIRST" = "true" ]; then
    tablespec=""
    for f in "${csv_files[@]}"; do
      table="$(basename "$f" .csv)"
      if [ -n "$tablespec" ]; then tablespec+=","; fi
      tablespec+="\"${table}\""
    done
    echo "TRUNCATE TABLE ${tablespec} CASCADE;"
  fi

  for f in "${csv_files[@]}"; do
    table="$(basename "$f" .csv)"
    abspath="$(realpath "$f")"
    stage="__import_staging_${table}"

    # Clean the CSV's own header row (strip CRLF/quotes) — this is the
    # file's real, on-disk column order, used only to shape the staging
    # table so `\copy` into it needs no column list at all.
    header_line="$(head -n 1 "$f")"
    IFS=',' read -ra raw_header <<< "$header_line"
    file_cols=()
    for c in "${raw_header[@]}"; do
      c="${c%$'\r'}"; c="${c#\"}"; c="${c%\"}"
      file_cols+=("$c")
    done

    # Query the destination table's real columns + types (a separate,
    # immediate connection — not deferred into the batch SQL file — since
    # we need this to decide what to generate for this table).
    mapfile -t dest_rows < <("${PSQL[@]}" -tAc \
      "SELECT column_name || '|' || data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='${table}' ORDER BY ordinal_position")
    if [ ${#dest_rows[@]} -eq 0 ]; then
      echo "ERROR: table \"${table}\" does not exist in ${DB_NAME} — did sequelize.sync() run against this database?" >&2
      exit 1
    fi
    declare -A dest_type=()
    for row in "${dest_rows[@]}"; do
      dest_type["${row%%|*}"]="${row#*|}"
    done

    keep_cols=()
    dropped_cols=()
    for c in "${file_cols[@]}"; do
      if [ -n "${dest_type[$c]+x}" ]; then
        keep_cols+=("$c")
      else
        dropped_cols+=("$c")
      fi
    done
    if [ ${#dropped_cols[@]} -gt 0 ]; then
      echo "WARNING: ${table}: CSV has column(s) not present in the current table, dropping: ${dropped_cols[*]}" >&2
    fi

    # Staging table: TEXT columns in the file's exact order, so `\copy`
    # needs no column list and can't misalign regardless of the real
    # table's column order or any extra/missing columns.
    stage_cols_def=""
    for c in "${file_cols[@]}"; do
      if [ -n "$stage_cols_def" ]; then stage_cols_def+=","; fi
      stage_cols_def+="\"${c}\" TEXT"
    done

    # INSERT target column list and the matching SELECT expressions, each
    # cast from the staging table's TEXT back to the destination column's
    # real type — this is what actually reconciles order/drift, not the
    # staging copy (which is a dumb, order-preserving passthrough).
    insert_cols=""
    select_exprs=""
    for c in "${keep_cols[@]}"; do
      if [ -n "$insert_cols" ]; then insert_cols+=","; select_exprs+=","; fi
      insert_cols+="\"${c}\""
      select_exprs+="\"${c}\"::${dest_type[$c]}"
    done
    unset dest_type

    echo "\\echo Importing ${table}..."
    echo "CREATE TEMP TABLE \"${stage}\" (${stage_cols_def});"
    echo "\\copy \"${stage}\" FROM '${abspath}' WITH (FORMAT csv, HEADER true)"
    echo "INSERT INTO \"${table}\" (${insert_cols}) SELECT ${select_exprs} FROM \"${stage}\";"
    echo "DROP TABLE \"${stage}\";"
  done
  echo "SET session_replication_role = DEFAULT;"
} > "$SQL_FILE"

psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SQL_FILE"

echo "Done importing ${#csv_files[@]} table(s) into '${DB_NAME}'."
