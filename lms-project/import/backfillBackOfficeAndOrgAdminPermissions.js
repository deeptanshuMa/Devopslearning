// Deploy into usermgmt's app/scripts/ and run from app/:
//   node scripts/backfillBackOfficeAndOrgAdminPermissions.js --dry-run
//   node scripts/backfillBackOfficeAndOrgAdminPermissions.js
//
// back_office_and_org_admin_permissions.sql added 18 new default_role_permissions
// rows for back_office (previously had ZERO) and 15 new rows for org_admin
// (cross-branch read-only reporting visibility, additive to its existing 18).
// This backfills roles_and_permissions for every existing org (+ branch, for
// back_office) so existing organizations actually get these grants, matching
// addDefultPermissionsByOrganizationScript's logic.
//
// IMPORTANT: several of the reused sub_module_keys (attendance_report,
// exam_result, student, students, list_notice, room...) already exist as
// default_role_permissions rows for OTHER roles (org_branch_admin, teacher).
// A blanket "sub_module_key IN (...)" filter would incorrectly re-select
// those pre-existing rows. Filtering here is done strictly by role_id,
// scoped further for org_admin to only the newly-added keys (its original
// 18 rows must not be re-touched -- they're already backfilled).
require("dotenv").config();

const db = require("../config/database");
const constants = require("../config/constants");
const { getRoleListService, getRoleService } = require("../src/services/roles.service");
const { othersAPIGatway } = require("../utils/helpers/apis.helpers");
const {
  bulkInsertRolePermission,
  bulkInsertUserPermission,
} = require("../src/services/rolePermission.service");
const { findUsersByRolesWithPagination } = require("../src/services/user.service");

const DefaultRolePermission = db.defaultRolePermission;

const DRY_RUN = process.argv.includes("--dry-run");

const NEW_ORG_ADMIN_KEYS = [
  "student", "students", "teacher", "class", "section", "subject",
  "attendance_report", "exam_result", "exam_schedule", "live_class_list",
  "list_notice", "room", "department", "category", "employees",
];

const backfillBackOfficeAndOrgAdmin = async () => {
  try {
    console.log(`=== backfillBackOfficeAndOrgAdmin (${DRY_RUN ? "DRY RUN" : "LIVE"}) ===`);

    const backOfficeRole = await getRoleService({ slug: constants.ROLES_SLUG.BACK_OFFICE });
    const orgAdminRole = await getRoleService({ slug: constants.ROLES_SLUG.ORG_ADMIN });

    const backOfficeRows = await DefaultRolePermission.findAll({
      where: { role_id: backOfficeRole.id },
      raw: true,
    });

    const orgAdminRows = (
      await DefaultRolePermission.findAll({
        where: { role_id: orgAdminRole.id },
        raw: true,
      })
    ).filter((e) => NEW_ORG_ADMIN_KEYS.includes(e.sub_module_key));

    console.log(`back_office rows to backfill: ${backOfficeRows.length}`);
    console.log(`org_admin (new-keys-only) rows to backfill: ${orgAdminRows.length}`);

    const defaultRolePermissionDataJSON = [...backOfficeRows, ...orgAdminRows];

    const fakeReq = { header: () => undefined };

    const orgListUrl = `${process.env.API_GATEWAY_URL}v1/organization/all-script`;
    const allOrgList = await othersAPIGatway(fakeReq, {}, "get", orgListUrl, {});

    const orgBranchListUrl = `${process.env.API_GATEWAY_URL}v1/organization-branch/all-script`;
    const allOrgBranchList = await othersAPIGatway(fakeReq, {}, "get", orgBranchListUrl, {});

    if (!Array.isArray(allOrgList) || !Array.isArray(allOrgBranchList)) {
      throw new Error(
        "othersAPIGatway did not return arrays -- check API_GATEWAY_URL reachability and route responses before proceeding"
      );
    }

    console.log(`Organizations: ${allOrgList.length}, branches: ${allOrgBranchList.length}`);

    const defaultFalsePermissions = [];
    const defaultFalsePermissionsOrgBranch = [];

    for (let index = 0; index < allOrgList.length; index++) {
      const orgDeat = allOrgList[index];
      defaultRolePermissionDataJSON.forEach((e) => {
        const obj = { ...e, organization_branch_id: null, organization_id: orgDeat.id };
        delete obj.id;
        defaultFalsePermissions.push(obj);
      });
    }

    for (let index = 0; index < allOrgBranchList.length; index++) {
      const orgBranch = allOrgBranchList[index];
      const checkOrg = defaultFalsePermissions.filter(
        (e) => e.organization_id == orgBranch.organization_id && e.role_id.toString() === backOfficeRole.id.toString()
      );
      checkOrg.forEach((e) => {
        const obj = { ...e, organization_branch_id: orgBranch.id };
        defaultFalsePermissionsOrgBranch.push(obj);
      });
    }

    const rolesAndPermissionsToInsert = [...defaultFalsePermissions, ...defaultFalsePermissionsOrgBranch];
    console.log(`roles_and_permissions rows to insert: ${rolesAndPermissionsToInsert.length}`);
    console.log(`  (org-level: ${defaultFalsePermissions.length}, branch-level for back_office: ${defaultFalsePermissionsOrgBranch.length})`);

    if (!DRY_RUN) {
      await bulkInsertRolePermission(rolesAndPermissionsToInsert);
    }

    // --- Staff backfill (users_permissions) ---
    // org_branch_admin_staff derives from back_office? No -- back_office has
    // its own accounts directly (not a staff-delegate tier), same as
    // org_branch_admin itself. Only org_admin_staff needs users_permissions
    // backfilled for org_admin's new keys.
    const orgAdminStaffDetails = await getRoleService({ slug: constants.ROLES_SLUG.ORG_ADMIN_STAFF });

    const page = constants.PAGINATION.DEFAULT_PAGE;
    const pageSize = constants.PAGINATION.DEFAULT_PAGESIZE;
    const offset = (page - 1) * +pageSize;
    const sortBy = constants.PAGINATION.DEFAULT_SORTBY;
    const sortOrder = constants.PAGINATION.DEFAULT_SORTORDER;
    const order = [[sortBy, sortOrder]];

    const orgAdminStaffList = await findUsersByRolesWithPagination(
      {},
      { role_id: orgAdminStaffDetails.id },
      order,
      offset,
      10000
    );

    console.log(`org_admin_staff accounts: ${orgAdminStaffList.length}`);
    console.log(`Permission rows to backfill per staff member: ${orgAdminRows.length}`);

    const staffPermissionsToInsert = [];
    orgAdminStaffList.forEach((staffUser) => {
      orgAdminRows.forEach((e) => {
        const permissions = { ...e.permissions };
        Object.keys(permissions).forEach((k) => {
          permissions[k] = false;
        });
        staffPermissionsToInsert.push({
          permissions,
          sub_module_id: e.sub_module_id,
          user_id: staffUser.id,
          organization_id: staffUser.organization_id,
          organization_branch_id: staffUser.organization_branch_id,
        });
      });
    });

    console.log(`users_permissions rows to insert: ${staffPermissionsToInsert.length}`);

    if (!DRY_RUN) {
      await bulkInsertUserPermission(staffPermissionsToInsert);
    }

    console.log(DRY_RUN ? "=== DRY RUN complete, nothing written ===" : "=== Backfill complete ===");
  } catch (err) {
    console.error("=== backfillBackOfficeAndOrgAdmin ERROR ===", err);
    process.exit(1);
  }
};

module.exports = { backfillBackOfficeAndOrgAdmin };

if (require.main === module) {
  (async () => {
    try {
      await backfillBackOfficeAndOrgAdmin();
      process.exit(0);
    } catch (err) {
      console.error("Fatal error:", err);
      process.exit(1);
    }
  })();
}
