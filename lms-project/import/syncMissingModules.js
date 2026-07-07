// Deploy this file into usermgmt's own `app/scripts/` directory (it needs
// that app's Sequelize models, config, and role service — it can't run
// standalone). Then from `app/`:
//
//   node scripts/syncMissingModules.js --dry-run   # review what would change
//   node scripts/syncMissingModules.js              # apply for real
//
// Purpose: `public/defaultData/modules.js`/`sub_modules.js` define more
// main_modules/sub_modules than ever actually got inserted, because the
// seed guard (`if (existingModules > 0) skip`) added to stop the
// duplicate-reseed bug also means anything appended to those data files
// *after* the original seed ran will never be picked up automatically.
// Confirmed missing in production: leave_management, offline_exam,
// session_year, notice_board, email_notifications, payroll (as
// main_modules), plus their matching sub_modules, plus `assignment`'s own
// sub_module (its main_module already existed, but with zero children).
//
// This script is purely additive: it diffs the data files against what's
// already in the DB by `key`, inserts only what's missing (existing rows
// are never touched), and grants default Read permission on the newly
// added org-facing sub-modules to both org_admin and org_branch_admin via
// default_role_permissions. Safe to re-run — a second run finds nothing
// missing and inserts nothing. Verified locally against a mock DB seeded
// to match production's exact current module list.
//
// Note: default_role_permissions is role-wide, not per-org. Whether a
// given organization's dashboard actually shows these modules also
// depends on that org's plan including the corresponding main_module_id
// in super_admin's plan_modules — check/add that separately per plan.
require("dotenv").config();

const db = require("../config/database");
const constants = require("../config/constants");
const { getRoleService } = require("../src/services/roles.service");

const { ALL_MODULES } = require("../public/defaultData/modules");
const { ALL_SUB_MODULES } = require("../public/defaultData/sub_modules");

const MainModules = db.mainModules;
const SubModules = db.subModules;
const DefaultRolePermission = db.defaultRolePermission;
const sequelize = db.sequelize;

const DRY_RUN = process.argv.includes("--dry-run");

const syncMissingModules = async () => {
  let transaction;

  try {
    console.log(`=== syncMissingModules (${DRY_RUN ? "DRY RUN" : "LIVE"}) ===`);

    transaction = await sequelize.transaction();

    const existingMainModules = await MainModules.findAll({ raw: true, transaction });
    const existingMainKeys = new Set(existingMainModules.map((m) => m.key));

    const missingMainModules = ALL_MODULES.filter((m) => !existingMainKeys.has(m.key));

    console.log(`Main modules already present: ${existingMainModules.length}`);
    console.log(`Main modules missing (to insert): ${missingMainModules.length}`);
    missingMainModules.forEach((m) => console.log(`  + main_module: ${m.key}`));

    let insertedMainModules = [];
    if (missingMainModules.length > 0 && !DRY_RUN) {
      insertedMainModules = await MainModules.bulkCreate(missingMainModules, {
        transaction,
        returning: true,
      });
    }

    const moduleMap = {};
    existingMainModules.forEach((m) => {
      moduleMap[m.key] = m.id;
    });
    insertedMainModules.forEach((m) => {
      moduleMap[m.key] = m.id;
    });
    if (DRY_RUN) {
      missingMainModules.forEach((m) => {
        if (!moduleMap[m.key]) moduleMap[m.key] = `(new-id-for-${m.key})`;
      });
    }

    const existingSubModules = await SubModules.findAll({ raw: true, transaction });
    const existingSubKeys = new Set(existingSubModules.map((s) => s.key));

    const missingSubModules = ALL_SUB_MODULES.filter((s) => !existingSubKeys.has(s.key));

    console.log(`Sub modules already present: ${existingSubModules.length}`);
    console.log(`Sub modules missing (to insert): ${missingSubModules.length}`);
    missingSubModules.forEach((s) =>
      console.log(`  + sub_module: ${s.key} (main_module_key: ${s.main_module_key})`)
    );

    const unresolvable = missingSubModules.filter((s) => !moduleMap[s.main_module_key]);
    if (unresolvable.length > 0) {
      throw new Error(
        `Cannot resolve main_module_id for: ${unresolvable
          .map((s) => s.key)
          .join(", ")}. Their main_module_key isn't in ALL_MODULES / the DB.`
      );
    }

    const formattedSubModules = missingSubModules.map((s) => ({
      ...s,
      main_module_id: moduleMap[s.main_module_key],
      menu_main_module_id: s.menu_main_module_key
        ? moduleMap[s.menu_main_module_key]
        : moduleMap[s.main_module_key],
    }));

    let insertedSubModules = [];
    if (formattedSubModules.length > 0 && !DRY_RUN) {
      insertedSubModules = await SubModules.bulkCreate(formattedSubModules, {
        transaction,
        returning: true,
      });
    }

    // Default role permissions for the newly inserted org-facing sub-modules,
    // granted to both org_admin and org_branch_admin.
    const orgAdminDetails = await getRoleService({ slug: constants.ROLES_SLUG.ORG_ADMIN });
    const orgBranchAdminDetails = await getRoleService({
      slug: constants.ROLES_SLUG.ORG_BRANCH_ADMIN,
    });

    if (!orgAdminDetails) throw new Error("org_admin role not found");
    if (!orgBranchAdminDetails) throw new Error("org_branch_admin role not found");

    const subModulesForPermissions = DRY_RUN
      ? missingSubModules.map((s, i) => ({ ...s, id: `(new-id-for-${s.key})` }))
      : insertedSubModules;

    const rolePermissionArr = [];
    subModulesForPermissions.forEach((sm) => {
      if (sm.is_organization_module === true) {
        [orgAdminDetails, orgBranchAdminDetails].forEach((role) => {
          rolePermissionArr.push({
            sub_module_id: sm.id,
            role_id: role.id,
            role_key: role.slug,
            sub_module_key: sm.key,
            permissions: { Read: true },
          });
        });
      }
    });

    console.log(`Default role permissions to insert: ${rolePermissionArr.length}`);
    rolePermissionArr.forEach((p) => console.log(`  + ${p.role_key} -> ${p.sub_module_key}`));

    if (rolePermissionArr.length > 0 && !DRY_RUN) {
      await DefaultRolePermission.bulkCreate(rolePermissionArr, { transaction });
    }

    if (DRY_RUN) {
      await transaction.rollback();
      console.log("=== DRY RUN complete, nothing written (transaction rolled back) ===");
    } else {
      await transaction.commit();
      console.log("=== Sync complete and committed ===");
    }
  } catch (err) {
    console.error("=== syncMissingModules ERROR ===");
    console.error(err);
    if (transaction) {
      try {
        await transaction.rollback();
      } catch (rollbackErr) {
        console.error("Rollback error:", rollbackErr);
      }
    }
    process.exit(1);
  }
};

module.exports = { syncMissingModules };

if (require.main === module) {
  (async () => {
    try {
      await syncMissingModules();
      process.exit(0);
    } catch (err) {
      console.error("Fatal error:", err);
      process.exit(1);
    }
  })();
}
