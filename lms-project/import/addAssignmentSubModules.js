require("dotenv").config();

const db = require("../config/database");
const constants = require("../config/constants");
const { getRoleService } = require("../src/services/roles.service");

const MainModules = db.mainModules;
const SubModules = db.subModules;
const DefaultRolePermission = db.defaultRolePermission;
const sequelize = db.sequelize;

const DRY_RUN = process.argv.includes("--dry-run");

// assignment's main_module already exists (created empty at some point).
// addNewModule can't add sub_modules to a PRE-EXISTING main_module (it only
// resolves main_module_id from the batch it just bulk-created in the same
// call), so these 4 are inserted directly instead, matching addNewModule's
// own role-permission mapping (is_branch_organization_module -> org_branch_admin,
// is_teacher_module -> teacher, is_student_module -> student,
// is_parent_module -> parent), all recovered verbatim from
// public/defaultData/sub_modules.js.
const ASSIGNMENT_SUB_MODULES = [
  { name: "Assesment Report", key: "assesment_report", is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: true },
  { name: "Assignment List", key: "assignment_list", is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Evaluation", key: "evaluation", is_organization_module: false, is_branch_organization_module: false, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "My Assignment", key: "my-assignment", is_organization_module: false, is_branch_organization_module: false, is_teacher_module: false, is_student_module: true, is_librarian_module: false, is_parent_module: false },
];

const FLAG_TO_ROLE_SLUG = {
  is_organization_module: constants.ROLES_SLUG.ORG_ADMIN,
  is_branch_organization_module: constants.ROLES_SLUG.ORG_BRANCH_ADMIN,
  is_teacher_module: constants.ROLES_SLUG.TEACHER,
  is_student_module: constants.ROLES_SLUG.STUDENT,
  is_parent_module: constants.ROLES_SLUG.PARENT,
  is_librarian_module: constants.ROLES_SLUG.LIBRARIAN,
};

const addAssignmentSubModules = async () => {
  let transaction;
  try {
    console.log(`=== addAssignmentSubModules (${DRY_RUN ? "DRY RUN" : "LIVE"}) ===`);
    transaction = await sequelize.transaction();

    const assignmentMain = await MainModules.findAll({ raw: true, transaction }).then(
      (rows) => rows.find((m) => m.key === "assignment")
    );
    if (!assignmentMain) {
      throw new Error("assignment main_module not found — expected it to already exist");
    }

    const existingSubModules = await SubModules.findAll({ raw: true, transaction });
    const existingSubKeys = new Set(existingSubModules.map((s) => s.key));

    const missing = ASSIGNMENT_SUB_MODULES.filter((s) => !existingSubKeys.has(s.key));
    console.log(`Sub modules missing (to insert): ${missing.length}`);
    missing.forEach((s) => console.log(`  + sub_module: ${s.key}`));

    const formatted = missing.map((s) => ({
      ...s,
      main_module_key: "assignment",
      main_module_id: assignmentMain.id,
      menu_main_module_id: assignmentMain.id,
    }));

    let inserted = [];
    if (formatted.length > 0 && !DRY_RUN) {
      inserted = await SubModules.bulkCreate(formatted, { transaction, returning: true });
    }

    const roleCache = {};
    for (const slug of Object.values(FLAG_TO_ROLE_SLUG)) {
      if (!roleCache[slug]) {
        const role = await getRoleService({ slug });
        if (!role) throw new Error(`Role not found for slug: ${slug}`);
        roleCache[slug] = role;
      }
    }

    const subsForPerms = DRY_RUN
      ? missing.map((s, i) => ({ ...s, id: `(new-id-for-${s.key})` }))
      : inserted;

    const rolePermissionArr = [];
    subsForPerms.forEach((sm) => {
      Object.entries(FLAG_TO_ROLE_SLUG).forEach(([flag, roleSlug]) => {
        if (sm[flag] === true) {
          const role = roleCache[roleSlug];
          rolePermissionArr.push({
            sub_module_id: sm.id,
            role_id: role.id,
            role_key: role.slug,
            sub_module_key: sm.key,
            permissions: { Read: true },
          });
        }
      });
    });

    console.log(`Default role permissions to insert: ${rolePermissionArr.length}`);
    rolePermissionArr.forEach((p) => console.log(`  + ${p.role_key} -> ${p.sub_module_key}`));

    if (rolePermissionArr.length > 0 && !DRY_RUN) {
      await DefaultRolePermission.bulkCreate(rolePermissionArr, { transaction });
    }

    if (DRY_RUN) {
      await transaction.rollback();
      console.log("=== DRY RUN complete, nothing written ===");
    } else {
      await transaction.commit();
      console.log("=== Complete and committed ===");
    }
  } catch (err) {
    console.error("=== addAssignmentSubModules ERROR ===", err);
    if (transaction) await transaction.rollback().catch(() => {});
    process.exit(1);
  }
};

module.exports = { addAssignmentSubModules };

if (require.main === module) {
  (async () => {
    try {
      await addAssignmentSubModules();
      process.exit(0);
    } catch (err) {
      console.error("Fatal error:", err);
      process.exit(1);
    }
  })();
}
