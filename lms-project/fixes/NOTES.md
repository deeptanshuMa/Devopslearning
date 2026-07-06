# Fixes to apply to the source repos

These repos aren't in this git remote's scope, so the fixes are documented
here rather than committed directly to them. Apply manually.

## 1. `lms-backend-usermgmt-staging/app/config/database.js` — disabled seeders

**Only matters if you are NOT restoring a full CSV data dump** (i.e. you're
starting `user_management` from an empty database). If you're importing
real data via `import/import-tables.sh`, skip this — your dump should
already contain the super-admin user, roles, and regional data, and
re-running these seeders on top of restored data isn't necessary.

If you do want a working empty environment (e.g. for a fresh
dev/test box), uncomment the three calls in the `sync().then()` block:

```diff
     setTimeout(function () {
       const {
         addDefaultAdmin,
         addDefaultRegionalDetails,
       } = require("../scripts/defaultUser");

       const { addDefaultModules } = require("../scripts/defaultModules");

-      // addDefaultAdmin();
-      // addDefaultRegionalDetails();
-      // addDefaultModules()
+      addDefaultAdmin();
+      addDefaultRegionalDetails();
+      addDefaultModules();
     }, 3000);
```

Note `addDefaultModules()` (in `app/scripts/defaultModules.js`) currently
starts with a hardcoded `return true;` before doing any work — it's
disabled regardless of whether you call it. If you need the default
main-modules/sub-modules/permissions data it creates, remove that early
return too:

```diff
 const addDefaultModules = async () => {
-  return true
   await MainModules.destroy({ where: {} });
```

(Leaving `return true` in place is harmless if you're restoring real data
that already includes these tables.)

## 2. `API-gatway-staging/app/config/gateway.config.yml` — hardcoded cluster IPs

Replace the `serviceEndpoints` block with `../setup/gateway.config.local.yml`'s
version (or point at wherever each service actually runs, if not localhost).

## 3. Both frontends' `.env` — `NEXT_PUBLIC_API`

`lms-react-super-admin-frontend-staging` and `lms-org-frontend-staging`
both currently point at `https://stag-apigateway.bitsrack.com/`. Change
both to your VPS gateway's URL (e.g. `http://localhost:3000/` if the
frontend runs on the same box, or `https://your-domain/` if behind a
reverse proxy).

**Confirmed real bug in the org frontend's uploaded `.env`:**

```
NEXT_PUBLIC_API = " https://stag-apigateway.bitsrack.com/"
```

There's a **leading space inside the quotes**. Since this is a
double-quoted value, dotenv/Next.js keep it literally — every URL built
from `${NEXT_PUBLIC_API}...` will start with a stray space
(`" https://.../v1/organization"`), which most HTTP clients/browsers will
either mangle or reject outright. When you set this for real, write it
with no space after `=` and none inside the quotes:

```
NEXT_PUBLIC_API=http://localhost:3000/
```

## 3b. Backend `.env` — `API_GATEWAY_URL` still points at the live domain

The super-admin and org `.env` files you shared both have:

```
API_GATEWAY_URL="https://stag-apigateway.bitsrack.com/"
```

You confirmed this should instead point at the new VPS's own local
gateway, i.e. `API_GATEWAY_URL=http://localhost:3000/` (matches
`setup/env-templates/*.env.example`) — otherwise any inter-service call
these backends make through this URL would silently hit the old staging
environment instead of the box you're actually setting up.

## 3c. Backend `.env` — `DB_USER = "postg"` typo

Both the super-admin and org `.env` files you shared have:

```
DB_USER = postg
```

That's not a valid Postgres role on a fresh install — it should be
`postgres` (matches `setup/01-create-databases.sh`, which only creates/sets
the password for the `postgres` role). As shipped, both services would
fail to connect with something like `password authentication failed for
user "postg"` or `role "postg" does not exist`. This is a strong candidate
for part of "project not working" if it's been left this way anywhere.

## 3d. `DB_NAME` suffixed `_old_restore`

Both files use `super_admin_old_restore` / `organization_old_restore`
instead of `super_admin` / `organization`. Reasonable if you're
restoring the old CSV dump into a side-by-side database to verify it
before cutting over the real service — just make sure
`setup/01-create-databases.sh` (or a manual `CREATE DATABASE`) creates
whatever name you actually put in `DB_NAME`, and that you re-point (or
rename the DB) once you're satisfied and ready to go live.

## 4. Stray root-level `test.js` files

`lms-backend-usermgmt-staging/test.js`, `lms-backend-org-staging/test.js`,
and `lms-backend-notifications-staging/test.js` (repo root, not
`app/test/`) look like leftover scratch/debug scripts — `usermgmt`'s is a
duplicate, partially-edited copy of `app/scripts/defaultModules.js`. They
aren't required by anything (`app.js`, `bin/www`, `package.json` scripts
don't reference them). Safe to delete, but left alone here since that's a
repo-hygiene call for you to make, not a functional fix.

## 5. Old CSV export — orphaned tables

See `import/OLD_DB_ANALYSIS.md` for the full breakdown. Short version:
- Skip the `tickets`/`comments`/`attachments`/`issue_types` CSVs found
  inside the `Super Admin` and `Organization` export folders — that data
  lives correctly in the `Tickets` folder now (own service, own DB).
- `user_organization_branch_mappings` (from `User Management`) has no
  model anywhere in the current `usermgmt` repo — decide whether to
  rebuild that model or drop the data.

## 6. `lms-backend-ticket-staging` — duplicate/unused model files

`models/ticket_attachment.model.js`, `models/ticket_comments.model.js`,
`models/issue_types.model.js`, and `models/user_tickets.model.js` are not
required by `config/database.js` (which uses `attachments.model.js`,
`comments.model.js`, and `issueType.model.js` instead) — dead code, safe
to remove if you want to tidy the repo, but harmless if left in place.

## 7. File uploads need a code change if storage isn't real AWS S3

The `.env` files you shared point at `AWS_REGION="europe-1"` and
`AWS_FILE_URL="https://jd758.upcloudobjects.com/"` — that's **UpCloud
Object Storage**, an S3-compatible provider, not AWS. All four
Postgres-backed backends build their S3 client the same way, with no
endpoint override:

```js
// usermgmt: utils/helpers/uploadFile.helper.js
// super-admin: utils/fileUploadHelper.js
// org: utils/uploadFile.helper.js
// ticket: utils/helpers/fileUploadHelper.js
AWS.config.update({
  accessKeyId: process.env.AWS_ACCESS_KEY,
  secretAccessKey: process.env.AWS_SECRET_KEY,
  region: process.env.AWS_REGION,
});
const s3 = new AWS.S3();
```

With `AWS_REGION=europe-1` (not a real AWS region), the SDK will try to
hit a nonexistent `s3.europe-1.amazonaws.com` — every upload (profile
pictures, org logos, ticket attachments, assignments, salary slips, demo
sheets, etc.) will fail until this is patched. In each of the 4 files
above, change it to:

```diff
+// Add AWS_ENDPOINT to .env, e.g. https://jd758.upcloudobjects.com
 AWS.config.update({
   accessKeyId: process.env.AWS_ACCESS_KEY,
   secretAccessKey: process.env.AWS_SECRET_KEY,
   region: process.env.AWS_REGION,
 });
-const s3 = new AWS.S3();
+const s3 = new AWS.S3({
+  endpoint: new AWS.Endpoint(process.env.AWS_ENDPOINT),
+  s3ForcePathStyle: true, // required by most non-AWS S3-compatible providers
+});
```

If you're keeping real AWS S3 for any of these services instead, leave
`AWS_ENDPOINT` unset in that service's `.env` and this change is a no-op
(`new AWS.Endpoint(undefined)` — better to just skip the endpoint/
`s3ForcePathStyle` options entirely when `AWS_ENDPOINT` isn't set, e.g.:

```js
const s3 = new AWS.S3(
  process.env.AWS_ENDPOINT
    ? { endpoint: new AWS.Endpoint(process.env.AWS_ENDPOINT), s3ForcePathStyle: true }
    : {}
);
```
).
