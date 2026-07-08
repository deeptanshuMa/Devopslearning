# Fixes to apply to the source repos

These repos aren't in this git remote's scope, so the fixes are documented
here rather than committed directly to them. Apply manually.

## -1. CRITICAL: `lms-backend-usermgmt-staging` crashes on startup, every time, on any empty/fresh `user_management` DB

This is what's behind:

```
Error
    at Query.run (.../node_modules/sequelize/lib/dialects/postgres/query.js:50:25)
...
    at async student_parent.sync (.../node_modules/sequelize/lib/model.js:942:7) {
  name: 'SequelizeDatabaseError',
  parent: error: relation "users" does not exist
...
  sql: 'CREATE TABLE IF NOT EXISTS "student_parent" (... REFERENCES "users" ("id") ...)'
```

**This is very likely the actual root cause of the original "migration
script not importing the complete DB" symptom** — it's a bug that fires
on every single startup against an empty database, before schema creation
even has a chance to finish.

**Root cause:** `models/studentParent.model.js` has a stray, leftover
debug line at the bottom of the file:

```js
module.exports = (sequelize, DataTypes) => {
  const StudentParent = sequelize.define("student_parent", { ... }, {
    tableName: "student_parent",
    timestamps: false,
  });
  StudentParent.sync({ alter: true })   // <-- this line shouldn't be here
  return StudentParent;
};
```

`config/database.js` requires all 19 model files top-to-bottom
(`db.users` first, `db.student_parent` fourth), then calls one shared
`db.sequelize.sync({ alter: false })` at the very end, once every model
and association is registered — that shared call is what's supposed to
create all tables in dependency order.

But `studentParent.model.js` doesn't wait for that. The instant this file
is `require()`'d (line 28 of `config/database.js`), it independently calls
`StudentParent.sync({ alter: true })` on the spot — trying to
`CREATE TABLE student_parent (... REFERENCES "users" ...)` immediately,
before the `users` table exists (it's only *registered* in memory at this
point via `db.users = require(...)`, not yet created in Postgres — that
only happens later, in the shared `sync()` call at the bottom of the
file). This standalone sync call has no `.catch()` and isn't awaited, so
its rejection (`relation "users" does not exist`) becomes an **unhandled
promise rejection** — which, under Node 18's default
`--unhandled-rejections=throw` behavior (the Dockerfile uses
`node:18.13.0-bullseye-slim`), **crashes the whole process**, racing
against (and likely winning against) the real `db.sequelize.sync()` call
a few lines later that would have created every table correctly. That's
consistent with a database that ends up with some tables created and
others missing depending on how far the real sync got before the crash —
exactly "not importing the complete DB."

This will happen on **every startup** against any database where `users`
doesn't already exist yet — i.e. guaranteed on first boot of a fresh
`user_management` database, every time, until fixed.

**Fix:** delete that one line. The shared `sequelize.sync()` in
`config/database.js` already handles creating `student_parent` (and every
other table) in the correct order via the associations declared later in
that same file — this standalone call serves no purpose and only exists
to break things:

```diff
-  StudentParent.sync({ alter: true })
   return StudentParent;
```

(i.e. just remove the `StudentParent.sync({ alter: true })` line
entirely, nothing needs to replace it.)

This is a one-line fix but it's the highest-priority one in this whole
document — until it's removed, `user_management` cannot reliably finish
creating its schema on a fresh database.

## 0. CRITICAL: `lms-backend-super-admin-staging` crashes the whole process on startup when `countries` is empty

This is what's behind:

```
Error(delete organization branch).. TypeError: Cannot read properties of undefined (reading 'headers')
    at importData (.../src/controller/organization.controller.js:1301:11)
...
Error: Transaction cannot be rolled back because it has been finished with state: commit
    at Transaction.rollback (.../node_modules/sequelize/lib/transaction.js:59:13)
    at importData (.../src/controller/organization.controller.js:1307:25)
```

**Root cause — two bugs stacked together in `organization.controller.js`:**

`importData` (`src/controller/organization.controller.js:1288`) is
dual-purposed: it's wired as a normal Express route
(`router.get("/import", importData)` in `organization.router.js`) *and*
called directly with **zero arguments** from
`scripts/defaultValues.js:36` (`addDefaultRegionalDetails()`, which
`config/database.js` calls unconditionally 3 seconds after every
`sequelize.sync()`, whenever `super_admin.countries` is empty):

```js
// defaultValues.js
const addDefaultRegionalDetails = async () => {
  const regionalDetailsExist = await getCountOfCountriesService();
  if (regionalDetailsExist) {
    console.log("Regional Details Already Existed.!");
  } else {
    importData();   // <-- called with no req/res
  }
};
```

1. When called this way, `req` is `undefined` inside `importData`. The
   success-path response line —
   `sendResponse(req, res, ..., req.headers.lang)` — evaluates
   `req.headers.lang` as an argument and throws `TypeError: Cannot read
   properties of undefined (reading 'headers')` before `sendResponse` is
   even reached. This throws inside the `try`, so it always ends up in
   the `catch`.
2. `transaction.commit()` a few lines earlier is called **without
   `await`**. By the time the `catch` block runs, that commit has already
   resolved (or is racing to). The `catch` unconditionally calls `await
   transaction.rollback()`, which throws `Transaction cannot be rolled
   back because it has been finished with state: commit` — a **second,
   unhandled** error thrown inside an async catch block with nothing
   further to catch it, which crashes the entire Node process (this is
   why you saw two separate stack traces — the second one killed the
   service, not just the request).

**Net effect: every time `super_admin`'s `countries` table is empty at
startup, this service will crash ~3 seconds after boot.** This will
happen on a truly fresh database (before you've imported anything) and
will keep happening on every restart until `countries` has at least one
row.

**Operational workaround (no code change, use this now):** since the old
CSV export's `Super Admin/public_countries_export_*.csv` has 250 rows
(see `import/CSV_AUDIT.md`), importing it via `import/import-tables.sh`
before/after the first boot resolves the trigger condition —
`getCountOfCountriesService()` will return >0 and `importData()` won't be
called again. The very first boot against a brand-new empty database will
still crash 3 seconds in (expected — `sequelize.sync()` will have already
finished creating the schema by then, so this is harmless: let it crash,
import your CSVs, then restart).

**Real fix (recommended regardless):** patch `importData` to (a) not
touch `req`/`res` when they're absent, and (b) not blindly roll back an
already-committed transaction:

```diff
 const importData = async (req, res) => {
+  let transaction;
   try {
     transaction = await sequelize.transaction();
-    // const fileData = await importStudentService(req?.file);
     await bulkCountriesEntry();
-    transaction.commit();
-    return sendResponse(
-      req,
-      res,
-      constants.WEB_STATUS_CODE.OK,
-      constants.STATUS_CODE.SUCCESS,
-      "REQUEST.ADDED",
-      null,
-      req.headers.lang
-    );
+    await transaction.commit();
+    if (res) {
+      return sendResponse(
+        req,
+        res,
+        constants.WEB_STATUS_CODE.OK,
+        constants.STATUS_CODE.SUCCESS,
+        "REQUEST.ADDED",
+        null,
+        req?.headers?.lang
+      );
+    }
   } catch (err) {
-    console.log("Error(delete organization branch)..", err);
-
-    if (transaction) {
-      await transaction.rollback();
-    }
-    return sendResponse(
-      req,
-      res,
-      constants.WEB_STATUS_CODE.SERVER_ERROR,
-      constants.STATUS_CODE.FAIL,
-      "GENERAL.GENERAL_ERROR_CONTENT",
-      { message: err?.message },
-      req.headers.lang
-    );
+    console.log("Error(import regional data)..", err);
+    if (transaction && !transaction.finished) {
+      await transaction.rollback();
+    }
+    if (res) {
+      return sendResponse(
+        req,
+        res,
+        constants.WEB_STATUS_CODE.SERVER_ERROR,
+        constants.STATUS_CODE.FAIL,
+        "GENERAL.GENERAL_ERROR_CONTENT",
+        { message: err?.message },
+        req?.headers?.lang
+      );
+    }
   }
 };
```

(The `transaction && !transaction.finished` guard — Sequelize sets
`transaction.finished` to `"commit"` or `"rollback"` once it's done —
is the general-purpose fix for "rollback after already-committed", worth
applying anywhere else this pattern shows up.)

**Same anti-pattern (un-awaited `transaction.commit()` + unconditional
`rollback()` in `catch`) also appears, unpatched, at**
`organization.controller.js:662`, `:1326` (`updateRegionalDetails` — safe
in practice, since it never touches `req`/`res`), `:1373`, and
`languages.controller.js:234`. None of these are currently known to
crash the process the way `importData` does (they're not called
argument-less from a startup script), but they're the same latent risk if
a rollback is ever attempted after a commit that already resolved. Worth
an `await` + `!transaction.finished` pass across the file if you're
touching this code anyway.

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

The super-admin, org, **and ticket** `.env` files you shared all have:

```
API_GATEWAY_URL="https://stag-apigateway.bitsrack.com/"
```

(Notification's has the same thing, just without the `s` — `http://stag-apigateway.bitsrack.com/`.)

You confirmed this should instead point at the new VPS's own local
gateway, i.e. `API_GATEWAY_URL=http://localhost:3000/` (matches
`setup/env-templates/*.env.example`) — otherwise any inter-service call
these backends make through this URL would silently hit the old staging
environment instead of the box you're actually setting up. Applies to
**all 5** backends now that all their `.env` files have been reviewed.

**Confirmed live in usermgmt too**, via its own runtime log:

```
***othersAPIGatway call***
methodName, apiUrl,data........ get https://stag-apigateway.bitsrack.com/v1/language/details-code/en {}
```

So usermgmt's deployed `.env` (not yet shared directly, but proven by this
log) still has the same `API_GATEWAY_URL=https://stag-apigateway.bitsrack.com/`
issue — this specific call (`othersAPIGatway`, fetching a language-details
lookup) is currently going out to the internet and back instead of
staying on `localhost:3000`. Fix the same way as the other 4.

## 3c. Backend `.env` — `DB_USER = "postg"` typo

The super-admin, org, **and ticket** `.env` files you shared all have:

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

## Fixed: Assign Salary Template Filter button permanently disabled for Branch Admin

File: `lms-org-frontend/app/src/app/(hydrogen)/payroll/assign-salary-template/page.tsx`

`formData.branch_id` only exists when `userRoleSlug === Roles.OrgAdmin` (see
`initialFormData` construction). But the Filter button's `disabled` check used
an unrelated flag `isStaffAdmin` (which actually tracks whether the *selected
target role in the dropdown* is "Org Admin Staff", not the logged-in user's
own role) to decide whether to require `branch_id`. For any non-OrgAdmin
login (e.g. Branch Admin), `formData.branch_id` is always `undefined`, so
`!formData.branch_id` was always `true`, permanently disabling Filter
regardless of role selection.

Fix: use the same `userRoleSlug === Roles.OrgAdmin || userRoleSlug === Roles.OrganizationAdminStaff`
condition already used elsewhere in this file (initialFormData, and the
branch-reset useEffect) to decide whether `branch_id` is required, instead of
the unrelated `isStaffAdmin` flag.

```
- disabled={isStaffAdmin ? !formData.role_id : (!formData.role_id || !formData.branch_id)}
+ disabled={(userRoleSlug === Roles.OrgAdmin || userRoleSlug === Roles.OrganizationAdminStaff) ? (!formData.role_id || !formData.branch_id) : !formData.role_id}
```

Applied on staging, rebuilt, confirmed clean restart.
