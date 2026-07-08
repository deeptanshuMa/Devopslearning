#!/usr/bin/env bash
# Deduplicates countries/states in org-backend's database, which ended up
# with two full copies of every row (same name, different ids) from the
# same class of non-idempotent reseed bug already fixed for
# main_modules/sub_modules (see dedup-modules.sh). Unlike that fix, the
# canonical id here can't be picked arbitrarily ("lowest id wins") --
# usermgmt maintains its own copy of countries/states with its own
# enforced FK from address.country_id/state_id, and the two databases only
# work together if the ids for the same country/state match across both.
# So canonical = whichever of org-backend's duplicate ids also exists in
# usermgmt's copy.
#
# Root cause of the bulk-student-import 500: org-backend looks up
# country/state ids by name in its own (duplicated) table
# (regionalDetails.service.js's findAll has no ORDER BY, so it returns
# both duplicate rows) and student.controller.js's .find() picks
# whichever comes back first; when that's the orphaned copy, usermgmt
# rejects the resulting address insert because that id isn't in ITS OWN
# countries/states table.
#
# cities is NOT duplicated (confirmed matching row counts in both
# databases) so it's left alone except for remapping its state_id where it
# pointed at an orphaned state row.
#
# Usage:
#   DB_PASSWORD=secret ./dedup-regional-data.sh <usermgmt_db> <org_db> [db_host] [db_port] [db_user]
set -euo pipefail

usage() {
  cat <<EOF
Usage: DB_PASSWORD=... $0 <usermgmt_db> <org_db> [db_host] [db_port] [db_user]
EOF
}

USERMGMT_DB="${1:?$(usage)}"
ORG_DB="${2:?$(usage)}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"
DB_USER="${5:-postg}"
: "${DB_PASSWORD:?Set the DB_PASSWORD environment variable first}"

export PGPASSWORD="$DB_PASSWORD"
PSQL_UM=(psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$USERMGMT_DB")
PSQL_ORG=(psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$ORG_DB")

echo "=== Step 1: export usermgmt's canonical countries/states ($USERMGMT_DB) ==="
"${PSQL_UM[@]}" <<'SQL'
\copy (SELECT id, name FROM countries) TO '/tmp/dedup_canonical_countries.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT id, name, country_id FROM states) TO '/tmp/dedup_canonical_states.csv' WITH (FORMAT csv, HEADER true)
SQL

echo ""
echo "=== Step 2: dedup within org-backend ($ORG_DB) ==="
"${PSQL_ORG[@]}" <<'SQL'
BEGIN;

CREATE TEMP TABLE __canon_countries (id UUID, name TEXT);
\copy __canon_countries FROM '/tmp/dedup_canonical_countries.csv' WITH (FORMAT csv, HEADER true)

CREATE TEMP TABLE __canon_states (id UUID, name TEXT, country_id UUID);
\copy __canon_states FROM '/tmp/dedup_canonical_states.csv' WITH (FORMAT csv, HEADER true)

\echo 'Before counts:'
SELECT 'countries' AS table_name, count(*) FROM countries
UNION ALL SELECT 'states', count(*) FROM states
UNION ALL SELECT 'cities', count(*) FROM cities;

-- Map every org country row (both duplicates) to its usermgmt-canonical id
-- by name.
CREATE TEMP TABLE __country_map AS
SELECT o.id AS old_id, c.id AS canon_id
FROM countries o
JOIN __canon_countries c ON c.name = o.name;

\echo 'Country names in org DB with no canonical match in usermgmt (should be empty):'
SELECT DISTINCT name FROM countries WHERE name NOT IN (SELECT name FROM __canon_countries);

-- Remap every column referencing countries.id to the canonical id.
UPDATE organization_branches t SET country_id = m.canon_id
FROM __country_map m WHERE t.country_id = m.old_id AND t.country_id <> m.canon_id;

UPDATE states t SET country_id = m.canon_id
FROM __country_map m WHERE t.country_id = m.old_id AND t.country_id <> m.canon_id;

UPDATE time_zones t SET country_id = m.canon_id
FROM __country_map m WHERE t.country_id = m.old_id AND t.country_id <> m.canon_id;

DELETE FROM countries c USING __country_map m
WHERE c.id = m.old_id AND c.id <> m.canon_id;

\echo 'countries remaining (should be 250, matching usermgmt):'
SELECT count(*) FROM countries;

-- Now that states.country_id is canonical, map every org state row to its
-- usermgmt-canonical id by (name, country_id).
CREATE TEMP TABLE __state_map AS
SELECT o.id AS old_id, c.id AS canon_id
FROM states o
JOIN __canon_states c ON c.name = o.name AND c.country_id = o.country_id;

\echo 'State (name, country_id) pairs in org DB with no canonical match in usermgmt (should be empty):'
SELECT DISTINCT s.name, s.country_id FROM states s
WHERE NOT EXISTS (
  SELECT 1 FROM __canon_states c WHERE c.name = s.name AND c.country_id = s.country_id
);

UPDATE cities t SET state_id = m.canon_id
FROM __state_map m WHERE t.state_id = m.old_id AND t.state_id <> m.canon_id;

UPDATE organization_branches t SET state_id = m.canon_id
FROM __state_map m WHERE t.state_id = m.old_id AND t.state_id <> m.canon_id;

DELETE FROM states s USING __state_map m
WHERE s.id = m.old_id AND s.id <> m.canon_id;

\echo 'After counts (should match usermgmt: 250 countries, 5084 states; cities unchanged):'
SELECT 'countries' AS table_name, count(*) FROM countries
UNION ALL SELECT 'states', count(*) FROM states
UNION ALL SELECT 'cities', count(*) FROM cities;

COMMIT;
SQL

echo ""
echo "Done. Confirm 'countries' = 250 and 'states' = 5084 above (matching usermgmt exactly), and that both 'no canonical match' checks returned zero rows."
