# LMS (Anantha) — Server Setup Notes

This folder documents the architecture of the Anantha LMS platform (5 repos
analyzed from staging exports) and provides scripts to run the whole stack
on a single VPS using **PM2** (no Docker/Kubernetes), plus a strategy for
importing an existing Postgres data export (one CSV per table).

Source repos analyzed (staging branch):

| Repo | Role | Port | Postgres DB |
|---|---|---|---|
| `API-gatway-staging` | Express Gateway — routes `/v1/*` to backend services | 3000 | — |
| `lms-backend-usermgmt-staging` | Users, roles, permissions, regional data | 3001 | `user_management` |
| `lms-backend-super-admin-staging` | Orgs, plans, modules, acknowledgements | 3002 | `super_admin` |
| `lms-backend-org-staging` | Classes, courses, attendance, exams, library, salary, leave | 3003 | `organization` |
| `lms-react-super-admin-frontend-staging` | Next.js 13 admin UI | 4000 | — (calls gateway) |

**Not yet provided** (gateway is already configured to proxy to these — routes
will 502 until these exist):

- Tickets backend — expected on port 3004, DB likely `tickets` or similar
- Notification backend — expected on port 3005, DB likely `notification`
- Organization frontend (separate from the super-admin frontend)

All backend services use **Sequelize** against Postgres and share a single
Postgres *instance* but each has its own **database**. In the staging
manifests this instance is `10.106.16.106:5432` — a Kubernetes ClusterIP,
not reachable from a plain VPS. On the new server you'll run your own local
(or managed) Postgres instance and point every service's `.env` at it.

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
3. **RabbitMQ dependency**: `lms-backend-usermgmt-staging` expects
   `RABBITMQ_URL`. Install/run RabbitMQ locally or point at a managed
   instance, otherwise user-creation/notification flows can fail.
4. **Frontend** ships pointed at the live staging gateway
   (`https://stag-apigateway.bitsrack.com/`) — change `NEXT_PUBLIC_API` to
   your VPS gateway URL.

## Layout of this folder

```
lms-project/
  README.md                        - this file
  setup/
    00-prereqs.sh                  - installs Node 18, Postgres, RabbitMQ, PM2 (Ubuntu/Debian)
    01-create-databases.sh         - creates the 3 databases + role
    ecosystem.config.js            - PM2 process list for gateway + 3 backends + frontend
    gateway.config.local.yml       - gateway config with localhost service endpoints
    env-templates/                 - one .env.example per service, localhost-based
  import/
    import-tables.sh               - imports one-CSV-per-table dumps into a target DB
                                      (no sequence reset needed — every table
                                      uses UUID primary keys, confirmed across
                                      all 3 backends' models)
  fixes/
    NOTES.md                       - exact diffs/lines to change in each repo (seed calls, gateway IPs, frontend API URL)
```

## Suggested order of operations

1. Run `setup/00-prereqs.sh` on the VPS.
2. Run `setup/01-create-databases.sh` to create `user_management`,
   `super_admin`, `organization` (add more if you bring in tickets/notification).
3. Copy each backend repo onto the server (e.g. `/opt/lms/<service>`), copy
   the matching template from `setup/env-templates/` to `app/.env` and fill
   in real values (DB password, JWT secret, AWS keys, etc. — keep these out
   of git).
4. `npm install` inside each repo's `app/` directory.
5. Start each service once with plain `node bin/www` (or `npm start`) so
   Sequelize's `sync()` creates the empty schema in each database. Stop it
   again once you see "Database sync successfully" in the logs.
6. Import your CSV dump with `import/import-tables.sh` (see that script's
   header for usage) — do this **after** schema creation, **before**
   starting the services under PM2 permanently.
7. Update `API-gatway-staging/app/config/gateway.config.yml` using
   `setup/gateway.config.local.yml` as a reference (or replace it directly).
8. Update the frontend's `NEXT_PUBLIC_API` to your gateway's address.
9. `pm2 start setup/ecosystem.config.js` (edit the `cwd` paths first to
   match wherever you placed each repo).

See `import/import-tables.sh` for exactly how to handle the per-table CSV
restore, including why sequence resets are required.
