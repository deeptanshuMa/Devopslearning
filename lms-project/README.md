# LMS (Anantha) — Server Setup Notes

This folder documents the architecture of the Anantha LMS platform (all 8
repos now analyzed) and provides scripts to run the whole stack on a single
VPS using **PM2** (no Docker/Kubernetes), plus a strategy for importing an
existing Postgres/Mongo data export (one CSV per table).

All 8 repos are now accounted for:

| Service | Repo | Live port | Database | Endpoint URL | Swagger URL |
|---|---|---|---|---|---|
| api-gateway | `API-gatway-staging` | 3000 | — | `stag-apigateway.bitsrack.com` | — |
| users | `lms-backend-usermgmt-staging` | 3001 | `user_management` (Postgres) | `stag-usermgmt.bitsrack.com` | `stag-usermgmt.bitsrack.com/swagger-doc` |
| super-admin | `lms-backend-super-admin-staging` | 3002 | `super_admin` (Postgres) | `stag-superadminbck.bitsrack.com` | `stag-superadminbck.bitsrack.com/swagger-doc` |
| organization | `lms-backend-org-staging` | 3003 | `organization` (Postgres) | `stag-orgbck.bitsrack.com` | `stag-orgbck.bitsrack.com/swagger-doc` |
| ticket | `lms-backend-ticket-staging` | 3004 | `tickets` (Postgres) | `stag-ticketbck.bitsrack.com` | `stag-ticketbck.bitsrack.com/swagger-doc` |
| notification | `lms-backend-notifications-staging` | 3005 | `notifications` (**MongoDB**, not Postgres) | `stag-notificationsbck.bitsrack.com` | `stag-notificationsbck.bitsrack.com/swagger-doc` |
| super-admin frontend | `lms-react-super-admin-frontend-staging` | 4000 | — (calls gateway) | — | — |
| organization frontend | `lms-org-frontend-staging` | 4001 | — (calls gateway) | — | — |

These `stag-*.bitsrack.com` URLs are the **existing staging domains** — on
your own VPS you won't have these DNS names/TLS certs unless you set up
your own reverse proxy + domains pointing at this box. Locally/internally
each service is reached at `http://localhost:<port>/`; the gateway is the
single public entry point in the original architecture (individual backend
domains like `stag-usermgmt.bitsrack.com` are just for direct/Swagger
access, not something the frontends call directly).

All 5 backends use **Sequelize**, and 4 of them (users, super-admin,
organization, ticket) run against Postgres — sharing one Postgres
*instance* in staging (`10.106.16.106:5432`, a Kubernetes ClusterIP, not
reachable from a plain VPS) but each with its own **database**. The
**notification** service is the exception: it uses **MongoDB** via
Mongoose, entirely separate from the Postgres side. On the new server
you'll run your own local (or managed) Postgres + MongoDB instances and
point every service's `.env` at them.

## ⚠ Known startup crashes — check these first if a service won't stay up

Two real code bugs (not config issues) will crash these services on a
fresh/empty database:

- **`lms-backend-usermgmt-staging`** — crashes on **every** startup
  against an empty `user_management` DB. A stray, leftover
  `StudentParent.sync({ alter: true })` debug line in
  `models/studentParent.model.js` tries to create that table (which
  references `users`) immediately when the model file loads, before the
  real `users` table exists — throwing `relation "users" does not exist`
  as an unhandled promise rejection that kills the process, racing
  against (and likely beating) the proper `sequelize.sync()` a few lines
  later. **This is very likely the actual root cause of the original
  "migration script not importing the complete DB" report** — full
  diagnosis and one-line fix in `fixes/NOTES.md` item -1.
- **`lms-backend-super-admin-staging`** — crashes a few seconds after
  boot specifically when its `countries` table has zero rows (fresh DB,
  or partial restore). Two stacked bugs in `organization.controller.js`'s
  `importData`. Full diagnosis, operational workaround, and code patch in
  `fixes/NOTES.md` item 0.

## ⚠ Fixed: `import-tables.sh` was silently shifting columns

Caught this importing `Super Admin/countries` into `super_admin_old_restore`
— `\copy "table" FROM file` with no explicit column list maps CSV columns
to the table **by position**, not by name. Sequelize's `sync()` creates
columns in model-attribute-definition order, which isn't always the same
order the original export was taken in (e.g. `countries.model.js` defines
`iso3, iso2, nationality, is_active`, but the CSV has
`iso3, nationality, is_active, createdAt, updatedAt, iso2` — `iso2` moved).
One column out of place shifts everything after it; here it eventually
landed a timestamp into the boolean `is_active` column
(`invalid input syntax for type boolean`). Fixed `import-tables.sh` to
build an explicit, quoted column list from each CSV's own header row, so
`\copy` maps by name instead — verified against a live Postgres instance
with this exact table/CSV, confirming all 250 rows now land in the correct
columns (`is_active` boolean, `iso2`/`nationality` swapped back correctly).
**Re-`git pull`/re-copy `import-tables.sh` before importing anything else.**
Checked the 3 tables already loaded with the old script version
(`acknowledgement_attachments`, `acknowledgement_categories`,
`acknowledgements`) against their models — their CSV column order happens
to match the model's field order exactly, so they're **not** affected and
don't need re-importing. `countries` is the one to redo (with
`TRUNCATE_FIRST=true` since it partially loaded before the error, or just
`DROP`/recreate the table). If you hit column-order issues on other tables
going forward, that's this same class of bug — the fix now handles it
automatically.

## ⚠ Fixed: `TRUNCATE_FIRST=true` failed on tables with foreign keys

Follow-up bug in the same script, hit next: truncating tables one at a
time (in alphabetical/glob order) fails outright the moment one table in
the batch is referenced by another via FK — e.g.
`TRUNCATE TABLE "acknowledgement_categories"` errors with "cannot truncate
a table referenced in a foreign key constraint" because `acknowledgements`
references it. Adding a per-table `CASCADE` would have "fixed" the error
but introduced a worse, silent bug: `acknowledgement_attachments` sorts
and loads *before* `acknowledgements` alphabetically, so a later
per-table `CASCADE` truncate of `acknowledgements` would have
cascade-deleted the attachments rows that had just been freshly reloaded a
moment earlier in the same run — with nothing left to reload them, since
that file was already processed. Fixed `import-tables.sh` to truncate
every table in the batch together in a single combined `TRUNCATE TABLE
t1, t2, ..., tN CASCADE` statement, up front, before any `\copy` runs —
verified against a live 3-table FK chain
(`acknowledgement_attachments → acknowledgements → acknowledgement_categories`)
run through `TRUNCATE_FIRST=true` twice in a row: all three end up with
their correct row counts (4/25/18) both times, no data loss.
**Re-`git pull`/re-copy `import-tables.sh` again** if you copied it before
this fix.

## ⚠ Fixed: `import-tables.sh` errored on genuine schema drift (extra/missing CSV columns)

Hit importing `Organization/assignments`: the CSV has 23 columns
including `attachment_type` and `attachment`, but the current
`assignments` model has neither (it has since gained
`session_year_id` instead, presumably after single-file attachments were
replaced by the separate `assignment_attachments` table) — a plain
`\copy` with a column list errors outright with `column "attachment_type"
of relation "assignments" does not exist`. This isn't a one-off: schema
drift between a ~1.5-year-old export and the current models is a real,
recurring possibility across the remaining tables, not just this one.

Rewrote `import-tables.sh`'s import step to be robust to this generally,
not just patch this one table: each CSV now loads first into a `TEMP`
staging table shaped to match the file exactly (every column as `TEXT`,
in the file's own order — so the load step itself can never fail on
order or type), then an `INSERT INTO "<table>" (...) SELECT ...::<type>
FROM staging` copies over only the columns that exist in **both** the CSV
and the current table, casting each back to its real column type. Any
CSV column absent from the table is dropped with a printed warning; any
table column absent from the CSV is just left `NULL`/default. This
subsumes the two earlier fixes (column reorder, FK-safe batch truncate)
under one mechanism rather than three separate patches.

Verified against three live scenarios in a real Postgres 16 instance:
`Organization/assignments` (2 dropped columns, warning printed, all 3 rows
land correctly with `session_year_id` NULL as expected), `Super
Admin/countries` (the earlier column-reorder case, still resolves
correctly), and the `acknowledgement_*` FK chain with `TRUNCATE_FIRST=true`
run twice consecutively (still correct row counts, no data loss). **Re-pull
`import-tables.sh` once more** before continuing with `Organization` or
any remaining folder.

## ⚠ Fixed: `import-tables.sh` failed whole tables over individual bad legacy rows

Next thing hit in `Organization`: `authors` has 15 of 40 rows with a
completely blank `name` (the model requires `allowNull: false`).
**Correction, see the entry below** — these turned out not to all be
orphaned junk; 10 of the 15 are referenced by real `books` rows.
Separately, `course_ratings` has 2 of 9 rows with a real
star rating (5, 4) but a blank `comment`, even though `comment` is also
`allowNull: false` in the model — a real, legitimate user action (rating
without writing a review) that the model's constraint is arguably too
strict to allow. Either way, a plain `INSERT` fails the **entire table's**
import the moment it reaches one such row, rather than loading the rows
that are actually fine.

Extended `import-tables.sh` to check, per table, which of the columns
being imported are `NOT NULL` in the destination (via
`information_schema.columns.is_nullable`), print a warning naming the
column and an approximate count of affected rows, and add a
`WHERE col1 IS NOT NULL AND col2 IS NOT NULL ...` clause to the `INSERT`
so only rows that are actually NULL in a required column get skipped —
every other row in the table still loads. This is a blunt, generic safety
net (it can't tell "junk row" from "constraint that's stricter than it
should be" apart) — it just refuses to let one bad row block 38 good
ones. If you want the `course_ratings` rows without comments back later,
that's a call between relaxing `comment`'s `allowNull` in the model or
manually giving those 2 rows a placeholder comment — noted here, not
decided for you.

Verified against both live in Postgres 16: `authors` imports 25/40 (15
skipped, warned), `course_ratings` imports 7/9 (2 skipped, warned), and in
both cases every row that *did* land has no NULL in the column that was
being enforced.

## ⚠ Correction: the `authors` skip broke `books` — 10 of the 15 weren't orphans

Got this wrong above: I checked whether **one** of the 15 blank-name
author IDs was referenced by any `books` row, found it wasn't, and
generalized that to all 15 without checking the other 14. After
restarting `org-backend`, its sync failed again — this time on
`books_author_id_fkey`: `Key (author_id)=(eece42b7-...) is not present in
table "authors"`. Checked properly this time: **10 of the 15** skipped
author IDs are referenced by real `books.author_id` values, and
`author_id` is `NOT NULL` on `books`, so unlike `city_id` it can't just be
cleared — the book needs *an* author row to point at.

Confirmed `course_ratings` doesn't have this problem: nothing in
`org/config/database.js` associates any other table to it (no
`hasMany`/`belongsTo` targeting `course_ratings`), so that skip is safe as
documented above. `authors` was the one exception, precisely because it's
a real parent table (`author.hasMany(book, { foreignKey: "author_id" })`)
in a way `course_ratings` isn't.

**Fix**: `import/fix-orphaned-authors.sql` reinstates all 15 skipped
`authors` rows with `name = 'Unknown Author'` (satisfies the `NOT NULL`
constraint, preserves their original IDs so `books.author_id` resolves).
Run it against `organization_old_restore` (or `organization`), then
restart `org-backend` again.

**Lesson for future tables**: `import-tables.sh`'s NOT-NULL-skip safety
net (previous section) is blunt by design — it doesn't know whether a
skipped row is referenced elsewhere. Before trusting a "rows skipped"
warning for any table, check the model's `config/database.js` for
`hasMany`/`belongsTo` associations pointing at that table — if something
else references it, dropped rows can resurface as a dangling FK
elsewhere, exactly like this.

## ⚠ Fixed: usermgmt's own reseed orphaned `address.country_id`/`state_id`

Found while chasing the org-create timezone dropdown bug (see below): the
running `usermgmt` service's own startup reseed **replaced** the entire
`countries`/`states`/`cities` tables with freshly-generated rows (same row
counts — 250/5084/150,573 — but new random UUIDs and today's
`createdAt`, not the historical 2023/2024 timestamps), rather than
skipping because CSV-imported data already existed. `time_zones` (427
rows) was never touched by that reseed and still resolves fine. But
`address.country_id`/`state_id` — pointing at the now-deleted historical
country/state rows — ended up `NULL` for all 433 rows (418 originally had
a `country_id`, 409 a `state_id`, confirmed against the original CSV),
apparently zeroed out by something in the currently-deployed usermgmt
code once those references stopped resolving (not something
`import-tables.sh` did — the import itself completed cleanly with no
warnings for this table).

**Fix**: `import/fix-address-regional-links.sh` — since the reseeded
`countries`/`states` presumably contain the same *names*, just new IDs,
it reads the original `address.csv`/`countries.csv`/`states.csv` (the
normalized folder from `prepare-csv-dir.sh`) to recover each address
row's old country/state **name** via its old ID, then re-resolves that
name against the *current* `countries`/`states` tables and updates the
live `address` rows accordingly (state matched by name **and** current
`country_id` together, to disambiguate any state names that repeat across
countries). Verified end-to-end in Postgres 16 against the exact
Australia/Tasmania row from the real export: after reseeding
`countries`/`states` with brand-new IDs and nulling the address row (to
reproduce the bug), the script correctly re-resolved both fields back to
the new Australia/Tasmania rows by name.

Usage:
```bash
DB_PASSWORD=... bash fix-address-regional-links.sh user_management_old_restore ./clean/user_management
```
(needs `address.csv`, `countries.csv`, `states.csv` in that directory —
the same one already used for the original import). Any address whose
historical country/state name doesn't have an exact-match row in the
current tables won't resolve — worth spot-checking the before/after
counts the script prints against the original 418/409.

**This will very likely recur on the real production cutover** unless
usermgmt's regional-data reseed is prevented from running against a
database that's just been restored from the CSV export — worth disabling
that reseed call (or fixing its "already exists" check) before the actual
final migration, not just patching around it in this test copy.

## ⚠ Fixed: `time_zones.country_id` — the actual org-create TimeZone dropdown bug

The address fix above didn't resolve the org-create "TimeZone: Nothing
found" dropdown — because that dropdown queries a completely different
table. It calls `GET /v1/regional/timezones/:country_id` (a usermgmt
route), which reads `time_zones` directly — not `address`.

**First version of this fix was wrong** — it assumed `time_zones` was
untouched by usermgmt's reseed and still pointed at old country IDs, so
it tried to resolve by matching the *live* `country_id` against the old
export. That found 0 matches, because the real state turned out to be
simpler and worse: `time_zones.country_id` is genuinely **`NULL`** in the
live table (same nulling that hit `address.country_id`/`state_id` earlier
also hit this column — `time_zones`' own `id`s and row count are
untouched, just this one FK column was wiped).

**Corrected fix**: since the old value is gone from the live row, the
script now goes back to the *original* `time_zones.csv` export and
matches by `time_zones.id` (unchanged) to recover each row's old
`country_id`, resolves that to a name via the original `countries.csv`,
then finds the current country with that name and updates the live row —
same name-remapping idea as the address fix, just keyed off the row's own
id instead of the (missing) old foreign key. Verified in Postgres 16 with
a synthetic India/US case reproducing the actual bug (live rows present
with real `id`s, `country_id` genuinely `NULL`): 0 resolved before, all 3
resolved correctly by name after (`Asia/Kolkata` → India,
`America/New_York`/`America/Chicago` → United States).

Usage:
```bash
DB_PASSWORD=... bash fix-timezones-country-links.sh user_management_old_restore ./clean/user_management
```
(needs `countries.csv` **and** `time_zones.csv` in that directory now,
not just `countries.csv`). The script prints a before/after count of how
many `time_zones` rows resolve against the current `countries` table —
`still_broken` should be 0 (or very close) afterward. Same caveat as the
address fix: a historical country name with no exact match in the current
table won't resolve.

## ⚠ Architectural issue: super-admin's regional IDs don't match what the frontend submits

Hit trying to create a new organization: `insert or update on table
"organizations" violates foreign key constraint
"organizations_city_id_fkey"`. This isn't a historical-data repair like
the previous fixes — it's a **structural mismatch** that will block
*every* new organization creation until fixed.

The org-create form's Country/State/City/TimeZone dropdowns all come from
usermgmt's `/v1/regional/*` routes (confirmed earlier for the TimeZone
one) — but the `organizations` table these values get submitted to lives
in `super-admin`, which has its **own separate** `countries`/`states`/
`cities` tables with different IDs (each service seeds/imports regional
data independently). Checked directly: the submitted `country_id` and
`state_id` didn't exist in super-admin's tables at all (`0` each);
`timezone_id` happened to resolve only because both services' `time_zones`
are untouched historical data from the same original system. `cities` in
super-admin was always empty (never in any CSV export), so city selection
was guaranteed to fail outright.

**Fix**: no new script needed — reused `import/import-tables.sh` as-is,
just **without** `TRUNCATE_FIRST`, to additively copy usermgmt's current
`countries`/`states`/`cities` into super-admin's tables *alongside* the
existing historical rows (not replacing them). This means:
- Existing historical `organizations.country_id`/`state_id` references
  keep resolving against the old rows, untouched — no remapping needed,
  unlike the address/timezone fixes.
- New org-creation submissions (using usermgmt-sourced IDs) now also
  resolve, since those exact IDs are now present too.
- `import-tables.sh`'s existing FK-bypass (`session_replication_role =
  replica`) means file processing order doesn't matter even though
  `cities` alphabetically sorts before `countries`/`states` that it
  depends on.

Verified end-to-end in Postgres 16 with a synthetic case matching this
exact scenario (destination db with its own old country/state + an
existing organization referencing them, source db with fresh IDs
including a city): after the additive import, the old historical
organization still resolved correctly against its original rows, **and**
a brand-new organization insert using the source db's IDs (country,
state, and city) succeeded.

Commands used:
```bash
mkdir -p /tmp/sync_usermgmt_regional
PGPASSWORD=... psql -h localhost -U postgres -d user_management_old_restore -c "\copy countries TO '/tmp/sync_usermgmt_regional/countries.csv' WITH (FORMAT csv, HEADER true)"
PGPASSWORD=... psql -h localhost -U postgres -d user_management_old_restore -c "\copy states TO '/tmp/sync_usermgmt_regional/states.csv' WITH (FORMAT csv, HEADER true)"
PGPASSWORD=... psql -h localhost -U postgres -d user_management_old_restore -c "\copy cities TO '/tmp/sync_usermgmt_regional/cities.csv' WITH (FORMAT csv, HEADER true)"

# NOTE: no TRUNCATE_FIRST — this must be additive
DB_PASSWORD=... bash import/import-tables.sh super_admin_old_restore /tmp/sync_usermgmt_regional
```

**This is a design-level issue, not just a migration artifact** — as long
as different services keep independent regional tables while a shared
frontend sources dropdowns from just one of them, this will keep
happening for any new record that stores a country/state/city/timezone
reference. `org`'s `organization_branches.city_id` (already nulled once
for historical data, see the city_id fix above) will hit the exact same
problem the next time someone creates a branch through the live app —
worth running the same additive sync against `organization_old_restore`
before that becomes the next support thread, and worth reconsidering the
regional-data architecture for the real production system (e.g. a single
shared regional-data service, or consistently seeding all services from
the same fixed-ID source) rather than patching this repeatedly per table.

## Key problem found: "migration script not importing the complete DB"

There is **no real migration system** in any of these repos — no
`sequelize-cli`, no `.sequelizerc`, no `/migrations` folder. Every backend's
`app/config/database.js` just calls:

```js
db.sequelize.sync({ alter: false })
```

This only creates/updates tables to match the Sequelize model definitions.
It never imports data. Separate one-off seed scripts exist in
`app/scripts/` (`defaultUser.js`, `defaultModules.js`, `defaultValues.js`,
`cscEntry.js`) that create a default super-admin user, default roles, and
country/state/city reference data — but **only `lms-backend-super-admin-staging`
and `lms-backend-org-staging` actually call these seeders**. In
`lms-backend-usermgmt-staging`, the calls are commented out:

```js
// config/database.js (usermgmt) — as shipped
setTimeout(function () {
  const { addDefaultAdmin, addDefaultRegionalDetails } = require("../scripts/defaultUser");
  const { addDefaultModules } = require("../scripts/defaultModules");
  // addDefaultAdmin();
  // addDefaultRegionalDetails();
  // addDefaultModules()
}, 3000);
```

So on a fresh `user_management` database you get empty tables: no
super-admin user, no roles, no regional data. See `fixes/` for the exact
patch. Note also that `defaultModules.js`'s `addDefaultModules()` has a
hardcoded `return true;` as its first line — it's a no-op even if called,
so don't rely on it; use the real data import instead (see below).

**Bottom line:** these seed scripts were never meant to import a production
data dump — they only bootstrap an empty environment with minimal defaults.
To restore your actual CSV export, use the import scripts in `import/`
instead of relying on `sync()` + seeders.

## Other things that will break a straight lift-and-shift to a new server

1. **Hardcoded Kubernetes-internal IPs** in
   `API-gatway-staging/app/config/gateway.config.yml` → `serviceEndpoints`
   (e.g. `http://10.99.9.117:3001/`). These must be replaced with
   `http://localhost:<port>/` for a single-VPS PM2 deployment. A ready
   template is in `setup/gateway.config.local.yml`.
2. **Secrets/config are baked into each repo's `app/.env`**, copied into the
   Docker image at build time — there's no external secret injection. On the
   VPS you edit these `.env` files directly (templates in
   `setup/env-templates/`).
3. **RabbitMQ dependency**: `lms-backend-usermgmt-staging` and
   `lms-backend-ticket-staging` both expect `RABBITMQ_URL`. Install/run
   RabbitMQ locally or point at a managed instance, otherwise
   user-creation/notification/ticket flows can fail.
4. **Both frontends** ship pointed at the live staging gateway
   (`https://stag-apigateway.bitsrack.com/`) — change `NEXT_PUBLIC_API` in
   both to your VPS gateway URL.
5. **Notification uses MongoDB**, not Postgres — a separate install/service
   from the other 4 backends (see `setup/02-create-mongo-db.sh`).
6. **Duplicate/dead model files in the ticket repo**: `models/` has both
   `attachments.model.js` (used) and `ticket_attachment.model.js` (unused),
   both `comments.model.js` (used) and `ticket_comments.model.js` (unused),
   both `issueType.model.js` (used) and `issue_types.model.js` (unused), plus
   an unused `user_tickets.model.js`. Only the ones wired into
   `config/database.js` matter (`tickets`, `attachments`, `issueType`,
   `comments`) — harmless but confusing if you go looking for the wrong
   file. Also note this repo runs `sequelize.sync({ alter: true })` (not
   `alter: false` like the others) — it will attempt schema alterations on
   every restart.

## Findings from the real `.env` files (all 5 backends + both frontends)

All 7 `.env` files have now been reviewed — full detail in
`fixes/NOTES.md` items 3–3d and 7:

- **Real bug**: org frontend's `NEXT_PUBLIC_API` has a literal leading
  space baked into the quoted value — breaks every API URL built from it.
- **Real bug**: super-admin, org, and ticket `.env` all have
  `DB_USER = postg` (should be `postgres`) — Postgres auth will fail as
  shipped. (usermgmt's original staging `.env` has this correct already;
  no new copy of it has been shared for the VPS setup yet.)
- Super-admin, org, ticket, and notification `API_GATEWAY_URL` all still
  point at the live `stag-apigateway.bitsrack.com` — confirmed this should
  be `http://localhost:3000/` for a fully self-contained VPS.
- `DB_NAME` uses a `super_admin_old_restore` / `organization_old_restore`
  convention for super-admin/org (ticket's `.env` keeps the plain
  `tickets` name) — reads as a deliberate side-by-side restore-verification
  step before cutover; reflected as a comment in the env templates.
- **Storage provider changed**: `AWS_REGION=europe-1` +
  `AWS_FILE_URL=https://jd758.upcloudobjects.com/` is **UpCloud Object
  Storage**, not AWS — confirmed identical across super-admin, org, and
  ticket. All 4 Postgres-backed backends construct their S3 client with no
  endpoint override — uploads will fail outright until the upload helper
  in each is patched to accept a custom endpoint. Exact before/after patch
  in `fixes/NOTES.md` item 7; env templates now include an `AWS_ENDPOINT`
  variable for this.
- Notification's `.env` is in good shape: `DB_URL` already points at
  `127.0.0.1:27017/notifications` with credentials matching
  `setup/02-create-mongo-db.sh`'s expectations. Only the `API_GATEWAY_URL`
  fix above applies to it.

## CSV data audit

Beyond the folder/filename structure covered above, the actual CSV
contents were audited row-by-row: 27,784 total rows across 81 files, zero
ragged rows, zero duplicate/blank primary keys, zero encoding issues, and
zero orphaned foreign keys across every relationship checked. Full
results (including a refined look at the small amount of real-but-legacy
data sitting in `Organization`'s ticket-related CSVs) in
`import/CSV_AUDIT.md`.

## Old DB CSV export (`Olddev_database.zip`)

Contains one CSV per table, in 4 folders: `User Management`, `Super Admin`,
`Organization`, `Tickets` — mapping 1:1 to those 4 Postgres databases (no
folder for `notification`, since that's MongoDB, not a CSV-exportable
Postgres DB in this dump).

Two things to know before importing — full detail in
`import/OLD_DB_ANALYSIS.md`:

- The `Super Admin` and `Organization` folders each contain leftover
  `tickets`/`comments`/`attachments`/`issue_types` CSVs from **before**
  ticketing was split into its own service. Neither service has models for
  these anymore, so importing them will fail (`relation does not exist`).
  The real, current data for those tables is in the `Tickets` folder →
  import that into the `tickets` DB instead.
- `User Management/public_user_organization_branch_mappings_export_*.csv`
  has no corresponding model anywhere in the current `usermgmt` codebase
  (the model file was deleted, only a dangling commented-out `require()`
  remains) — there's no table to import it into as-is.

`import/prepare-csv-dir.sh` handles the filename normalization
(`public_<table>_export_<timestamp>.csv` → `<table>.csv`) and can skip
both of the above via flags; see that script and
`import/OLD_DB_ANALYSIS.md` for exact usage.

## ⚠ Fixed: duplicate `main_modules`/`sub_modules` (every module seeded twice)

Found while testing role-permission lists: usermgmt's `main_modules`/
`sub_modules` each had **two full copies** of every module (same
name/key, different ids) — same root cause class as the regional-data
reseed bug above (a seed step, `addDefaultModules`, that didn't correctly
detect "already exists" on some earlier run before the pattern was
fixed). This showed up as duplicate entries in module listings and
duplicate keys in `rolePermission` arrays (e.g. `organization_list`
appearing twice).

**Fix**: `import/dedup-modules.sh` — for each duplicate group (by
`key`), keeps the lowest-id row as canonical, remaps every FK reference
(`sub_modules.main_module_id`/`menu_main_module_id`,
`default_role_permissions.sub_module_id`,
`roles_and_permissions.sub_module_id`, `users_permissions.sub_module_id`)
to the canonical row, de-duplicates any resulting duplicate permission
rows, then deletes the now-unreferenced extras. Also remaps the
*unenforced* cross-database reference `super_admin`'s
`plan_modules.main_module_id` (not a real FK, but still points at these
ids, and would silently break plan→module resolution otherwise). Runs
inside a transaction per database. Verified end-to-end in Postgres 16
against synthetic data reproducing the exact pattern (duplicate main
module + subs, duplicate permission rows across three tables, a
cross-database `plan_modules` reference to a to-be-deleted duplicate) —
every table collapsed to one row per unique relationship with no data
loss, and the cross-database reference correctly followed the surviving
canonical id.

Usage:
```bash
DB_PASSWORD=... bash dedup-modules.sh user_management_old_restore super_admin_old_restore
```

## ⚠ Fixed: 6 fully-built modules were never seeded — deliberately staged, not a bug

Found while investigating "org branch admin dashboard is missing Assignment,
Session Year, Payroll, Notice Board, etc." An initial hypothesis (that
`public/defaultData/modules.js`/`sub_modules.js` just needed a flat,
one-sub_module-per-main_module catch-up insert, mirroring the shape of the
STAGING server's deployed data files) turned out to be wrong — a deep dive
across `lms-backend-usermgmt`, `lms-backend-org`, `lms-org-frontend`, and
`lms-react-super-admin-frontend` (frontend pages/routes, backend
models/controllers/services/routes, and the actual role-permission
matching logic in `sidebar.tsx`/`ProtectedRoute`) found:

- Every already-working multi-item module (`organization_structure`,
  `library_management`, `attendance`, etc.) actually has **one sub_module
  row per dropdown item** (e.g. `organization_structure` has 7: `department`,
  `room`, `class`, `section`, `subject`, `assign_subject`,
  `assign_class_teacher`), each with its own
  `is_organization_module`/`is_branch_organization_module`/`is_teacher_module`/
  `is_student_module`/`is_parent_module`/`is_librarian_module` flags — not
  one flat row per top-level menu item. The deployed data file didn't have
  that granularity for the 6 missing modules at all.
- `leave_management`, `offline_exam`, `session_year`, `notice_board`,
  `email_notifications`, and `payroll` are **fully built end-to-end**: real
  pages/API clients/Redux slices in the org frontend, and complete
  models/controllers/services/routes/validation/Swagger docs in the org
  backend. Nothing is unfinished.
- The correct, granular seed data already existed — in the **local/dev**
  checkout of usermgmt's `public/defaultData/modules.js`/`sub_modules.js`
  (materially more complete than what's deployed to staging), every one of
  these modules was fully authored with correct per-role flags, but
  **commented out**, except `payroll` (staged as "next" but never actually
  deployed/seeded). `assignment`'s own sub_modules were commented out too,
  which is why its main_module existed with zero children.

**The real fix turned out to already exist and be already deployed**: a
`POST /v1/role-permission/add-new-module` endpoint
(`addNewModule` in `rolePermission.controller.js`, marked `// script for
new module add`) that bulk-inserts whatever's currently in
`ALL_MODULES`/`ALL_SUB_MODULES`, generates `default_role_permissions` from
per-key whitelists (already correctly updated for every key these 6
modules need — the developer had fully prepared this, just never
triggered it), and then backfills `roles_and_permissions` for every
**existing** organization/branch and `users_permissions` (disabled by
default) for every existing staff account. Confirmed via `git log`/`git
blame` on `lms-backend-usermgmt` (the `staging` branch, real commit
history) that this is the exact mechanism used to create every
already-working multi-item module, most recently Payroll
(commit `8fb8cb3`, "Created Payroll Module").

Two important wrinkles found before touching anything:

1. **`addNewModule` has no existence-check** — it unconditionally
   `bulkCreate`s whatever's in the data files. The staging server's
   deployed `modules.js`/`sub_modules.js` are a diverged, hand-maintained
   flat snapshot (not deployed from this repo — confirmed staging's own
   `/home/staging/lms-backend-usermgmt-staging` isn't even a git checkout)
   containing **all 33 modules already active**, not just the 6 missing
   ones. Calling the endpoint as-is would have re-created all 29
   already-existing modules as duplicates — the exact bug `dedup-modules.sh`
   already fixed once. Fix: replace the server's two data files with
   minimal versions containing *only* the 6 new main_modules / 21 new
   sub_modules before calling the endpoint (`import/new-modules-payload.js`,
   `import/new-sub-modules-payload.js`).
2. **`addNewModule` resolves each sub_module's `main_module_id` only from
   the batch of main_modules it just created in that same call** — it
   never looks up pre-existing ones. Since `assignment`'s main_module
   already exists, including its sub_modules in the endpoint call would
   crash (`mainModuleObj[0].id` on an empty array). Fix:
   `import/addAssignmentSubModules.js` — a small separate script that
   inserts just `assignment`'s 4 sub_modules directly, mapping the same
   per-role flags to `default_role_permissions`.

Both verified in a mock harness reproducing the endpoint's actual
bulk-create/resolve logic and production's exact current module list: the
endpoint-equivalent call correctly produces 35 main_modules / 48
sub_modules with no crashes, and `addAssignmentSubModules.js` then adds
the remaining 4 sub_modules + 7 correctly role-mapped permissions,
idempotently.

Deployment sequence (on the staging server):
```bash
# 1. Back up first — the endpoint has no transaction wrapping and no
#    idempotency guard, so it must only be called once.
pg_dump ... > backup_before_new_modules.sql   # both usermgmt and super_admin DBs

# 2. Back up and replace the two data files with the minimal payload
cd /home/staging/lms-backend-usermgmt-staging/app
cp public/defaultData/modules.js public/defaultData/modules.js.bak
cp public/defaultData/sub_modules.js public/defaultData/sub_modules.js.bak
cp /path/to/new-modules-payload.js public/defaultData/modules.js
cp /path/to/new-sub-modules-payload.js public/defaultData/sub_modules.js

# 3. Restart so the edited files actually load (require() is cached)
pm2 restart stag-usermgmt-backend

# 4. Trigger it — no gateway route exists for this path, call it directly
curl -X POST http://localhost:3001/v1/role-permission/add-new-module

# 5. Add assignment's sub_modules (can't go through the endpoint above)
cp addAssignmentSubModules.js scripts/addAssignmentSubModules.js
node scripts/addAssignmentSubModules.js --dry-run   # review first
node scripts/addAssignmentSubModules.js              # apply
```

Note: `roles_and_permissions`/`users_permissions` backfill is per-org, so
whether a given organization actually sees these modules also still
depends on that org's subscribed plan including the corresponding
`main_module_id` in super_admin's `plan_modules`. Check/add that
separately per plan if needed.

## Layout of this folder

```
lms-project/
  README.md                        - this file
  setup/
    00-prereqs.sh                  - installs Node 18, Postgres, MongoDB, RabbitMQ, PM2 (Ubuntu/Debian)
    01-create-databases.sh         - creates the 4 Postgres databases + role
    02-create-mongo-db.sh          - creates the Mongo user/db for the notification service
    ecosystem.config.js            - PM2 process list for gateway + 5 backends + 2 frontends
    gateway.config.local.yml       - gateway config with localhost service endpoints
    env-templates/                 - one .env.example per service, localhost-based
  import/
    import-tables.sh               - imports one-CSV-per-table dumps into a target Postgres DB
                                      (no sequence reset needed — every table
                                      uses UUID primary keys, confirmed across
                                      all 4 Postgres-backed services' models)
    prepare-csv-dir.sh             - normalizes the old DB export's filenames into <table>.csv,
                                      with flags to drop known-orphaned tables
    fix-orphaned-authors.sql       - reinstates 15 skipped authors rows that books.author_id needs
    fix-address-regional-links.sh  - repairs address.country_id/state_id after usermgmt's own
                                      reseed replaced countries/states with new IDs
    fix-timezones-country-links.sh - repairs time_zones.country_id after the same reseed
                                      (this is the one that actually fixes the org-create
                                      TimeZone dropdown)
    dedup-modules.sh               - collapses duplicate main_modules/sub_modules (every
                                      module seeded twice) back to one row each, remapping
                                      all FK references first
    new-modules-payload.js         - replaces usermgmt's public/defaultData/modules.js before
                                      calling POST /v1/role-permission/add-new-module: only the
                                      6 never-seeded main_modules (leave_management, offline_exam,
                                      session_year, notice_board, email_notifications, payroll)
    new-sub-modules-payload.js     - replaces public/defaultData/sub_modules.js the same way:
                                      only those 6 modules' 21 sub_modules, per-dropdown-item
                                      granularity, correct per-role flags
    addAssignmentSubModules.js     - deploy into usermgmt's app/scripts/: adds assignment's 4
                                      missing sub_modules directly (can't go through
                                      add-new-module since assignment's main_module already
                                      exists) plus correct per-role default permissions
    backfillAssignmentPermissions.js - deploy into usermgmt's app/scripts/: backfills
                                      roles_and_permissions (existing orgs/branches) and
                                      users_permissions (existing org_branch_admin_staff)
                                      for assignment's 4 sub_modules, scoped via
                                      sub_module_key IN (...) -- NOT the unscoped
                                      addDefultPermissionsByOrganization/-Branch endpoints
    add-translations-en.sql        - adds missing FE_XXX translation blocks for the 6 new
                                      modules + patches FE_ASSIGNMENT's 3 missing sub-keys
                                      (fixes icon-only sidebar / "Create Undefined" buttons)
    back_office_and_org_admin_permissions.sql - adds default_role_permissions: back_office
                                      (had ZERO permissions despite being an active,
                                      selectable role) gets a full accounts/admissions/
                                      records scope -- still live. Also originally added
                                      15 read-only cross-branch reporting keys to org_admin,
                                      but those were REVERTED (see revert_org_admin_permissions.sql)
                                      -- the report screens don't show which branch each row
                                      belongs to and have no branch filter, so read-only
                                      "visibility" across branches was meaningless as built.
    backfillBackOfficeAndOrgAdminPermissions.js - deploy into usermgmt's app/scripts/:
                                      backfills roles_and_permissions for all existing
                                      orgs+branches (back_office) / orgs (org_admin's new
                                      keys only, since reverted -- see above) and
                                      users_permissions for org_admin_staff, following the
                                      same scoped-by-role_id pattern as
                                      backfillAssignmentPermissions.js (several reused
                                      sub_module_keys already existed for other roles, so a
                                      blanket key filter would have double-counted)
    revert_org_admin_permissions.sql - undoes exactly the 15 org_admin keys above (not
                                      back_office) after user feedback that cross-branch
                                      read-only reports were confusing with no branch
                                      context/filter -- ran on staging, confirmed org_admin
                                      back to its original 18 default_role_permissions
    OLD_DB_ANALYSIS.md             - folder-by-folder breakdown of the old CSV export
    CSV_AUDIT.md                   - row-by-row data audit (row counts, FK integrity, encoding)
  fixes/
    NOTES.md                       - exact diffs/lines to change in each repo (seed calls, gateway IPs, frontend API URLs)
```

## Suggested order of operations

1. Run `setup/00-prereqs.sh` on the VPS.
2. Run `setup/01-create-databases.sh` to create `user_management`,
   `super_admin`, `organization`, `tickets` (Postgres), and
   `setup/02-create-mongo-db.sh` for the notification service's Mongo db.
3. Copy each of the 5 backend repos + 2 frontend repos onto the server
   (e.g. `/opt/lms/<service>`), copy the matching template from
   `setup/env-templates/` to `app/.env` and fill in real values (DB
   password, JWT secret, AWS keys, etc. — keep these out of git).
4. `npm install` inside each repo's `app/` directory.
5. Start each Postgres-backed service once with plain `node bin/www` (or
   `npm start`) so Sequelize's `sync()` creates the empty schema in each
   database. Stop it again once you see "Database sync successfully" in
   the logs. (Notification doesn't need this step — Mongo/Mongoose creates
   collections on first write.)
6. Prepare and import your CSV dump: run `import/prepare-csv-dir.sh` on
   each of the 4 old-DB export folders, then `import/import-tables.sh` per
   database — see `import/OLD_DB_ANALYSIS.md` for the exact commands and
   which tables to skip. Do this **after** schema creation, **before**
   starting the services under PM2 permanently.
7. Update `API-gatway-staging/app/config/gateway.config.yml` using
   `setup/gateway.config.local.yml` as a reference (or replace it directly)
   — it already has route entries for `tickets` and `notification`.
8. Update `NEXT_PUBLIC_API` in both frontends' `.env` to your gateway's
   address.
9. `pm2 start setup/ecosystem.config.js` (edit the `cwd` paths first to
   match wherever you placed each repo).

See `import/import-tables.sh` and `import/OLD_DB_ANALYSIS.md` for exactly
how to handle the per-table CSV restore.

## Networking: firewall the backend ports

usermgmt's logs already show a request for
`/wp-content/plugins/hellopress/wp_filemanager.php` — that's not part of
this app (there's no WordPress anywhere in this stack); it's an automated
vulnerability scanner probing for exposed WordPress installs, and it
correctly got a 404. Harmless on its own, but it means **the raw Node
ports are reachable from the public internet** and are already getting
scanned. Before going further:

- Only the reverse proxy / whatever serves your public domain(s) should
  be open on 80/443. Ports 3000–3005 (backends + gateway) and 4000–4001
  (frontends) should be firewalled to localhost/internal traffic only
  (e.g. `ufw allow from <trusted IPs> to any port <port>` or simply don't
  open them in your cloud provider's security group — PM2/Node doesn't
  need them exposed directly if a reverse proxy in front of the gateway is
  what's actually public).
- If you do want direct per-service access (e.g. for the Swagger URLs in
  the service table above), put them behind the same reverse proxy with
  TLS + the existing `BASIC_AUTH_PASSWORD` protecting `/swagger-doc`,
  rather than exposing the raw port.
