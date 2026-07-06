#!/usr/bin/env bash
# Normalizes a "one CSV per table" export folder (filenames like
# public_<table>_export_<date>_<time>.csv) into plain <table>.csv files
# ready for import-tables.sh, optionally skipping known-orphaned tables.
#
# See OLD_DB_ANALYSIS.md for why these particular tables are orphaned.
#
# Usage:
#   ./prepare-csv-dir.sh <source_dir> <output_dir> [flags...]
#
# Flags (combine as needed; default is to skip nothing):
#   --skip-legacy-tickets   drop tickets/comments/attachments/issue_types
#                           (use for the "Organization" and "Super Admin"
#                           source folders — that data moved to the
#                           dedicated ticket service; keep this flag OFF
#                           for the "Tickets" source folder itself)
#   --skip-org-branch-mapping
#                           drop user_organization_branch_mappings
#                           (use for the "User Management" source folder —
#                           no model exists for it in the current repo)
#
# Examples:
#   ./prepare-csv-dir.sh "dev_database/Tickets" ./clean/tickets
#   ./prepare-csv-dir.sh "dev_database/Organization" ./clean/organization --skip-legacy-tickets
#   ./prepare-csv-dir.sh "dev_database/Super Admin" ./clean/super_admin --skip-legacy-tickets
#   ./prepare-csv-dir.sh "dev_database/User Management" ./clean/user_management --skip-org-branch-mapping
set -euo pipefail

SRC="${1:?Usage: $0 <source_dir> <output_dir> [flags...]}"
OUT="${2:?Usage: $0 <source_dir> <output_dir> [flags...]}"
shift 2

SKIP_TABLES=()
for flag in "$@"; do
  case "$flag" in
    --skip-legacy-tickets)
      SKIP_TABLES+=("tickets" "comments" "attachments" "issue_types")
      ;;
    --skip-org-branch-mapping)
      SKIP_TABLES+=("user_organization_branch_mappings")
      ;;
    *)
      echo "Unknown flag: $flag" >&2
      exit 1
      ;;
  esac
done

should_skip() {
  local table="$1"
  for skip in "${SKIP_TABLES[@]:-}"; do
    if [ "$table" = "$skip" ]; then
      return 0
    fi
  done
  return 1
}

mkdir -p "$OUT"

shopt -s nullglob
count=0
skipped=0
for f in "$SRC"/*.csv; do
  base="$(basename "$f" .csv)"
  # Strip "public_" prefix and "_export_YYYY-MM-DD_HHMMSS" suffix
  table="$(echo "$base" | sed -E 's/^public_//; s/_export_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$//')"

  if should_skip "$table"; then
    echo "Skipping ${base}.csv (table: ${table})"
    skipped=$((skipped + 1))
    continue
  fi

  cp "$f" "$OUT/${table}.csv"
  count=$((count + 1))
done

echo "Prepared ${count} table CSV(s) in ${OUT} (${skipped} skipped)."
