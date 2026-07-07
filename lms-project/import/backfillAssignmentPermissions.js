// Deploy into usermgmt's app/scripts/ and run from app/:
//   node scripts/backfillAssignmentPermissions.js --dry-run
//   node scripts/backfillAssignmentPermissions.js
//
// addAssignmentSubModules.js only created the 4 new sub_modules and their
// global default_role_permissions template rows. Unlike addNewModule (used
// for the other 6 modules), it did NOT backfill roles_and_permissions for
// existing organizations/branches or users_permissions for existing staff,
// because addAssignmentSubModules.js couldn't go through addNewModule at
// all (main_module_id resolution crash on a pre-existing main_module).
//
// This replicates addDefultPermissionsByOrganizationScript and
// addDefultStaffPermissionScript's exact logic (verbatim, verified against
// the version that just ran successfully for the other 6 modules), but
// scoped ONLY to the 4 new assignment sub_module keys, via a WHERE
// sub_module_key IN (...) filter -- NOT the unscoped
// addDefultPermissionsByOrganization/-Branch HTTP endpoints, which pull
// every org-facing default_role_permission unconditionally and would
// duplicate everything already backfilled for existing orgs.
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

const ASSIGNMENT_KEYS = ["assesment_report", "assignment_list", "evaluation", "my-assignment"];

const backfillAssignmentPermissions = async () => {
  try {
    console.log(`=== backfillAssignmentPermissions (${DRY_RUN ? "DRY RUN" : "LIVE"}) ===`);

    // --- Org/branch backfill (roles_and_permissions) ---
    const defaultRolesPermissions = [
      constants.ROLES_SLUG.ORG_BRANCH_ADMIN,
      constants.ROLES_SLUG.TEACHER,
      constants.ROLES_SLUG.STUDENT,
      constants.ROLES_SLUG.LIBRARIAN,
      constants.ROLES_SLUG.PARENT,
      constants.ROLES_SLUG.BACK_OFFICE,
    ];

    const sortBy = constants.PAGINATION.DEFAULT_SORTBY;
    const sortOrder = constants.PAGINATION.DEFAULT_SORTORDER;
    const order = [[sortBy, sortOrder]];

    const roleData = await getRoleListService({ slug: defaultRolesPermissions }, order, 0, 20);
    const getOrgRoleId = roleData.map((e) => e.id.toString());

    const defaultRolePermissionDataJSON = (
      await DefaultRolePermission.findAll({
        where: { sub_module_key: ASSIGNMENT_KEYS },
        raw: true,
      })
    ).filter((e) => getOrgRoleId.includes(e.role_id.toString()));

    console.log(`Scoped default_role_permissions rows (org-facing roles only): ${defaultRolePermissionDataJSON.length}`);
    defaultRolePermissionDataJSON.forEach((e) => console.log(`  - role_id ${e.role_id} -> ${e.sub_module_key}`));

    // othersAPIGatway calls req?.header("Authorization") -- a plain {} has
    // no .header() method and would throw before the HTTP call is even
    // made. This stub matches what an unauthenticated internal script call
    // looks like (the /add-new-module call that already ran successfully
    // used no Authorization header either).
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
      const checkOrg = defaultFalsePermissions.filter((e) => e.organization_id == orgBranch.organization_id);
      checkOrg.forEach((e) => {
        const obj = { ...e, organization_branch_id: orgBranch.id };
        defaultFalsePermissionsOrgBranch.push(obj);
      });
    }

    const rolesAndPermissionsToInsert = [...defaultFalsePermissions, ...defaultFalsePermissionsOrgBranch];
    console.log(`roles_and_permissions rows to insert: ${rolesAndPermissionsToInsert.length}`);

    if (!DRY_RUN) {
      await bulkInsertRolePermission(rolesAndPermissionsToInsert);
    }

    // --- Staff backfill (users_permissions), org_branch_admin_staff only ---
    // (no super_admin/org_admin flagged rows exist among the 4 assignment
    // keys, so those two staff tiers have nothing to backfill here.)
    const orgBranchAdminDetails = await getRoleService({ slug: constants.ROLES_SLUG.ORG_BRANCH_ADMIN });
    const orgBranchAdminStaffDetails = await getRoleService({ slug: constants.ROLES_SLUG.ORG_BRANCH_ADMIN_STAFF });

    const rolePermissionOrgBranchAdminArr = defaultRolePermissionDataJSON.filter(
      (e) => orgBranchAdminDetails.id.toString() == e.role_id.toString()
    );

    const page = constants.PAGINATION.DEFAULT_PAGE;
    const pageSize = constants.PAGINATION.DEFAULT_PAGESIZE;
    const offset = (page - 1) * +pageSize;

    const orgBranchAdminStaffList = await findUsersByRolesWithPagination(
      {},
      { role_id: orgBranchAdminStaffDetails.id },
      order,
      offset,
      10000
    );

    console.log(`org_branch_admin_staff accounts: ${orgBranchAdminStaffList.length}`);
    console.log(`Permission rows to backfill per staff member: ${rolePermissionOrgBranchAdminArr.length}`);

    const staffPermissionsToInsert = [];
    orgBranchAdminStaffList.forEach((staffUser) => {
      rolePermissionOrgBranchAdminArr.forEach((e) => {
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
    console.error("=== backfillAssignmentPermissions ERROR ===", err);
    process.exit(1);
  }
};

module.exports = { backfillAssignmentPermissions };

if (require.main === module) {
  (async () => {
    try {
      await backfillAssignmentPermissions();
      process.exit(0);
    } catch (err) {
      console.error("Fatal error:", err);
      process.exit(1);
    }
  })();
}
