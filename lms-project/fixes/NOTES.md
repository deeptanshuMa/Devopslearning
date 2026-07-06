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

## 3. Frontend `.env` — `NEXT_PUBLIC_API`

Currently `https://stag-apigateway.bitsrack.com/`. Change to your VPS
gateway's URL (e.g. `http://localhost:3000/` if the frontend runs on the
same box, or `https://your-domain/` if behind a reverse proxy).

## 4. Stray root-level `test.js` files

`lms-backend-usermgmt-staging/test.js` and `lms-backend-org-staging/test.js`
(repo root, not `app/test/`) look like leftover scratch/debug scripts —
`usermgmt`'s is a duplicate, partially-edited copy of
`app/scripts/defaultModules.js`. They aren't required by anything
(`app.js`, `bin/www`, `package.json` scripts don't reference them). Safe to
delete, but left alone here since that's a repo-hygiene call for you to
make, not a functional fix.
