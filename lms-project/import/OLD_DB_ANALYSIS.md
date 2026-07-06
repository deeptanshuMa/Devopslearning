# Old dev database export — analysis

`Olddev_database.zip` contains `dev_database/` with **one CSV per table**,
grouped into 4 folders, dated 2024-04-10:

```
dev_database/
  Organization/     37 CSVs
  Super Admin/      21 CSVs
  Tickets/           4 CSVs
  User Management/  17 CSVs
```

No "Notification" folder — see why below.

Filename pattern is `public_<table_name>_export_<date>_<time>.csv`, e.g.
`public_users_export_2024-04-10_184114.csv` → table `users`. Stripping that
prefix/suffix gives you the exact Postgres table name for every file
checked against the current models (Sequelize's default pluralization
happens to line up with every filename here — verified by cross-checking
model `tableName`/`define()` calls against the CSV names).

## Folder → database mapping

| Folder | Target service DB | Notes |
|---|---|---|
| `User Management` | `user_management` (usermgmt, :3001) | one orphaned table, see below |
| `Super Admin` | `super_admin` (super-admin, :3002) | 4 files are legacy/orphaned, see below |
| `Organization` | `organization` (org, :3003) | 4 files are legacy/orphaned, see below |
| `Tickets` | `tickets` (ticket, :3004) | maps cleanly 1:1 to the new ticket service's 4 models |
| *(none)* | `notification` (:3005) | notification service uses **MongoDB**, not Postgres — this CSV export can't apply to it. If you need old notification data, you'd need a `mongodump`/`mongoexport` from the old Mongo instance instead, not a CSV. |

## Orphaned / legacy tables — do not import as-is

The ticketing feature used to live inside `Super Admin` and `Organization`
(their DBs each have their own copy of `tickets`, `comments`,
`attachments`, `issue_types` in this old dump) before it was split out into
the dedicated `lms-backend-ticket-staging` service. The **current**
`super-admin` and `org` model sets have no models for these tables at all,
so `sequelize.sync()` will never create them in `super_admin` or
`organization` — importing these 4 files into either DB will fail with
`relation "..." does not exist`, and if it didn't fail it'd just be stale,
superseded data anyway. Skip these 8 files entirely; the correct home for
this data is the `Tickets/` folder → `tickets` DB (ticket service):

- `Super Admin/public_tickets_export_*.csv` — skip
- `Super Admin/public_comments_export_*.csv` — skip
- `Super Admin/public_attachments_export_*.csv` — skip
- `Super Admin/public_issue_types_export_*.csv` — skip
- `Organization/public_tickets_export_*.csv` — skip
- `Organization/public_comments_export_*.csv` — skip
- `Organization/public_attachments_export_*.csv` — skip (org also has real
  `assignment_attachments` / `assignment_submissions_attachments` files —
  those are unrelated and should still be imported)
- `Organization/public_issue_types_export_*.csv` — skip

`prepare-csv-dir.sh` (below) already excludes these by default.

## Orphaned table with no current model at all

`User Management/public_user_organization_branch_mappings_export_*.csv` —
`lms-backend-usermgmt-staging/app/config/database.js` has a commented-out
reference to a `user_organization_branch.model.js` that **does not exist**
in the repo (the file was removed, only the dangling `require()` comment
is left). There is currently no table for this data anywhere in the
codebase. Options:

1. Skip this file (default in the prep script) — you lose this historical
   mapping data until/unless the feature is rebuilt.
2. Recreate `models/user_organization_branch.model.js` and re-wire it in
   `config/database.js` before importing, if this data is still needed
   (check the CSV's columns first to know what to rebuild).

This is a product decision, not an infra one — flagged here rather than
guessed at.

## Using `prepare-csv-dir.sh` + `import-tables.sh` together

```bash
# 1. Normalize filenames and drop orphaned tables into a clean staging dir
./prepare-csv-dir.sh "dev_database/User Management" ./clean/user_management --skip-org-branch-mapping
./prepare-csv-dir.sh "dev_database/Super Admin"      ./clean/super_admin     --skip-legacy-tickets
./prepare-csv-dir.sh "dev_database/Organization"     ./clean/organization    --skip-legacy-tickets
./prepare-csv-dir.sh "dev_database/Tickets"          ./clean/tickets

# 2. Start each service once so sync() creates the empty schema, then stop it

# 3. Import
DB_PASSWORD=secret ./import-tables.sh user_management ./clean/user_management
DB_PASSWORD=secret ./import-tables.sh super_admin      ./clean/super_admin
DB_PASSWORD=secret ./import-tables.sh organization     ./clean/organization
DB_PASSWORD=secret ./import-tables.sh tickets          ./clean/tickets
```
