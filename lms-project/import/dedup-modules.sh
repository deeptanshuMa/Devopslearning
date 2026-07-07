#!/usr/bin/env bash
# Deduplicates main_modules/sub_modules in usermgmt, which ended up with two
# full copies of every module (same name/key, different ids) from a past
# non-idempotent module-seeding run (same root cause class as the regional
# data reseed bug fixed earlier — a seed step that didn't correctly detect
# "already exists" on some prior run).
#
# For each duplicate group (grouped by `key`), picks the row with the
# lowest `id` as canonical, remaps every reference to the canonical row,
# de-duplicates any resulting duplicate permission rows, then deletes the
# now-unreferenced extra module/sub_module rows. Also remaps the *unenforced*
# cross-database reference super_admin's plan_modules.main_module_id, since
# that column isn't a real FK but still points at these ids.
#
# Everything runs inside a single transaction per database — if anything
# looks wrong, nothing commits.
#
# Usage:
#   DB_PASSWORD=secret ./dedup-modules.sh <usermgmt_db> <super_admin_db> [db_host] [db_port] [db_user]
set -euo pipefail

usage() {
  cat <<EOF
Usage: DB_PASSWORD=... $0 <usermgmt_db> <super_admin_db> [db_host] [db_port] [db_user]
EOF
}

USERMGMT_DB="${1:?$(usage)}"
SUPERADMIN_DB="${2:?$(usage)}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"
DB_USER="${5:-postg}"
: "${DB_PASSWORD:?Set the DB_PASSWORD environment variable first}"

export PGPASSWORD="$DB_PASSWORD"
PSQL_UM=(psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$USERMGMT_DB")
PSQL_SA=(psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$SUPERADMIN_DB")

echo "=== Step 1: dedup within usermgmt ($USERMGMT_DB) ==="
"${PSQL_UM[@]}" <<'SQL'
BEGIN;

-- Capture the FULL old id -> key mapping (every row, including
-- duplicates) before anything is deleted, so the cross-database
-- plan_modules remap (step 2) can resolve any stale id, canonical or not,
-- back to its current canonical replacement.
\copy (SELECT id, key FROM main_modules) TO '/tmp/dedup_main_modules_old_ids.csv' WITH (FORMAT csv, HEADER true)

-- Canonical main_module per key: lowest id wins (MIN() has no UUID
-- overload, so pick via DISTINCT ON ordered by id instead).
CREATE TEMP TABLE __main_module_canon AS
SELECT DISTINCT ON (key) key, id AS canon_id
FROM main_modules
ORDER BY key, id;

-- Canonical sub_module per key: lowest id wins.
CREATE TEMP TABLE __sub_module_canon AS
SELECT DISTINCT ON (key) key, id AS canon_id
FROM sub_modules
ORDER BY key, id;

\echo 'Duplicate main_modules groups (key, count):'
SELECT key, count(*) FROM main_modules GROUP BY key HAVING count(*) > 1 ORDER BY key;

\echo 'Duplicate sub_modules groups (key, count):'
SELECT key, count(*) FROM sub_modules GROUP BY key HAVING count(*) > 1 ORDER BY key;

-- Remap sub_modules' own FKs to canonical main_modules.
UPDATE sub_modules sm
SET main_module_id = mc.canon_id
FROM main_modules m
JOIN __main_module_canon mc ON mc.key = m.key
WHERE sm.main_module_id = m.id
  AND sm.main_module_id <> mc.canon_id;

UPDATE sub_modules sm
SET menu_main_module_id = mc.canon_id
FROM main_modules m
JOIN __main_module_canon mc ON mc.key = m.key
WHERE sm.menu_main_module_id = m.id
  AND sm.menu_main_module_id <> mc.canon_id;

-- Remap permission tables' sub_module_id to canonical sub_modules, then
-- drop any resulting duplicate rows (same natural key, now same
-- sub_module_id) before we can safely delete the old sub_module rows.

UPDATE default_role_permissions t
SET sub_module_id = sc.canon_id
FROM sub_modules s
JOIN __sub_module_canon sc ON sc.key = s.key
WHERE t.sub_module_id = s.id
  AND t.sub_module_id <> sc.canon_id;

DELETE FROM default_role_permissions a
USING default_role_permissions b
WHERE a.id > b.id
  AND a.role_id = b.role_id
  AND a.sub_module_id = b.sub_module_id;

UPDATE roles_and_permissions t
SET sub_module_id = sc.canon_id
FROM sub_modules s
JOIN __sub_module_canon sc ON sc.key = s.key
WHERE t.sub_module_id = s.id
  AND t.sub_module_id <> sc.canon_id;

DELETE FROM roles_and_permissions a
USING roles_and_permissions b
WHERE a.id > b.id
  AND a.role_id = b.role_id
  AND a.sub_module_id = b.sub_module_id
  AND coalesce(a.organization_id::text, '') = coalesce(b.organization_id::text, '')
  AND coalesce(a.organization_branch_id::text, '') = coalesce(b.organization_branch_id::text, '');

UPDATE users_permissions t
SET sub_module_id = sc.canon_id
FROM sub_modules s
JOIN __sub_module_canon sc ON sc.key = s.key
WHERE t.sub_module_id = s.id
  AND t.sub_module_id <> sc.canon_id;

DELETE FROM users_permissions a
USING users_permissions b
WHERE a.id > b.id
  AND a.user_id = b.user_id
  AND a.sub_module_id = b.sub_module_id;

-- Now safe to delete the non-canonical sub_modules and main_modules rows.
DELETE FROM sub_modules s
USING __sub_module_canon sc
WHERE s.key = sc.key AND s.id <> sc.canon_id;

DELETE FROM main_modules m
USING __main_module_canon mc
WHERE m.key = mc.key AND m.id <> mc.canon_id;

\echo 'main_modules remaining, by key (should all be 1 now):'
SELECT key, count(*) FROM main_modules GROUP BY key HAVING count(*) > 1;

\echo 'sub_modules remaining, by key (should all be 1 now):'
SELECT key, count(*) FROM sub_modules GROUP BY key HAVING count(*) > 1;

-- Export the final key -> canonical id mapping for main_modules, so the
-- cross-database plan_modules remap (step 2) can use it.
\copy (SELECT key, id FROM main_modules) TO '/tmp/dedup_main_modules_canon.csv' WITH (FORMAT csv, HEADER true)

COMMIT;
SQL

echo ""
echo "=== Step 2: remap super-admin's plan_modules.main_module_id ($SUPERADMIN_DB) ==="
"${PSQL_SA[@]}" <<SQL
BEGIN;

CREATE TEMP TABLE __old_main_modules (id UUID, key TEXT);
\copy __old_main_modules FROM '/tmp/dedup_main_modules_old_ids.csv' WITH (FORMAT csv, HEADER true)

CREATE TEMP TABLE __main_module_canon (key TEXT, id UUID);
\copy __main_module_canon FROM '/tmp/dedup_main_modules_canon.csv' WITH (FORMAT csv, HEADER true)

\echo 'plan_modules rows before remap, by whether main_module_id resolves to the current (post-dedup) table:'
SELECT
  count(*) FILTER (WHERE mc.id IS NOT NULL) AS already_current,
  count(*) FILTER (WHERE mc.id IS NULL) AS stale_or_null
FROM plan_modules pm
LEFT JOIN __main_module_canon mc ON mc.id = pm.main_module_id;

UPDATE plan_modules pm
SET main_module_id = mc.id
FROM __old_main_modules om
JOIN __main_module_canon mc ON mc.key = om.key
WHERE pm.main_module_id = om.id
  AND pm.main_module_id <> mc.id;

\echo 'plan_modules rows after remap:'
SELECT
  count(*) FILTER (WHERE mc.id IS NOT NULL) AS resolves_now,
  count(*) FILTER (WHERE mc.id IS NULL) AS still_stale
FROM plan_modules pm
LEFT JOIN __main_module_canon mc ON mc.id = pm.main_module_id;

COMMIT;
SQL

echo ""
echo "Done. 'still_stale' in the last count should be 0 (or explainable by NULL main_module_id rows, which is normal)."
