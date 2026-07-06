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
