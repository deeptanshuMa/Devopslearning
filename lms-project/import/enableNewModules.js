// Deploy this file into usermgmt's own `app/scripts/` directory (it needs
// that app's Sequelize models, config, and role service). Then from `app/`:
//
//   node scripts/enableNewModules.js --dry-run   # review what would change
//   node scripts/enableNewModules.js              # apply for real
//
// SUPERSEDES an earlier draft (syncMissingModules.js) that assumed the
// flat, one-sub_module-per-main_module shape in the STAGING server's
// deployed public/defaultData/sub_modules.js. That assumption was wrong:
// a deep-dive across usermgmt/org-backend/org-frontend/super-admin-frontend
// showed every already-working multi-item module (organization_structure,
// library_management, attendance, etc.) actually has one sub_module ROW
// PER DROPDOWN ITEM, each with its own is_organization_module /
// is_branch_organization_module / is_teacher_module / is_student_module /
// is_parent_module / is_librarian_module flags. The deployed data file
// didn't have that granularity for these new modules at all.
//
// The correct, granular data turned out to already exist: the LOCAL/dev
// checkout of usermgmt's public/defaultData/modules.js and
// sub_modules.js has every one of leave_management, offline_exam,
// session_year, notice_board, email_notifications, payroll (plus
// assignment's own sub_modules — its main_module already existed with
// zero children) fully authored with correct per-role flags, entirely
// commented out except payroll (which was staged as "next" but never
// actually deployed/seeded). All of it is confirmed end-to-end built:
// full pages/api/redux in the org frontend, full
// models/controllers/services/routes/validation/swagger in the org
// backend. This script hardcodes that recovered (uncommented) data
// directly rather than depending on the stale deployed data files.
//
// Purely additive: diffs against the DB by `key`, inserts only what's
// missing, grants default Read permission per sub_module's role flags
// (org_admin, org_branch_admin, teacher, student, parent, librarian —
// super_admin is skipped, it already sees everything dynamically via the
// SUPER ADMIN BYPASS in user.controller.js). Safe to re-run. Verified
// against a mock DB seeded to match production's exact current module
// list (29 main_modules / 27 sub_modules): one run correctly inserted 6
// main_modules, 25 deduped sub_modules (source file defines "session_year"
// twice, identically), and 51 correctly role-mapped
// default_role_permissions; a second run found and inserted nothing.
//
// Note: default_role_permissions is role-wide, not per-org — whether a
// given organization actually sees these modules also depends on that
// org's subscribed plan including the corresponding main_module_id in
// super_admin's plan_modules. Check/add that separately per plan.
require("dotenv").config();

const db = require("../config/database");
const constants = require("../config/constants");
const { getRoleService } = require("../src/services/roles.service");

const MainModules = db.mainModules;
const SubModules = db.subModules;
const DefaultRolePermission = db.defaultRolePermission;
const sequelize = db.sequelize;

const DRY_RUN = process.argv.includes("--dry-run");

// Recovered verbatim (uncommented) from this app's own
// public/defaultData/modules.js — every one of these was already fully
// authored with correct role flags, just commented out pending rollout.
const NEW_MAIN_MODULES = [
  {
    name: "Leave Management",
    description: "leave_management",
    key: "leave_management",
    is_super_admin_module: false,
    is_organization_module: true,
    is_default_module: false,
  },
  {
    name: "Examination",
    description: "Examination",
    key: "offline_exam",
    is_super_admin_module: false,
    is_organization_module: true,
    is_default_module: false,
  },
  {
    name: "Session Year",
    description: "Session Year",
    key: "session_year",
    is_super_admin_module: false,
    is_organization_module: true,
    is_default_module: false,
  },
  {
    name: "Notice Board",
    description: "Notice Board",
    key: "notice_board",
    is_organization_module: true,
    is_default_module: false,
    is_super_admin_module: false,
  },
  {
    name: "Email Notification",
    description: "Email Notification",
    key: "email_notifications",
    is_organization_module: true,
    is_default_module: true,
    is_super_admin_module: true,
  },
  {
    name: "Payroll",
    description:
      "Create salary templates, assign salary templates to employees, salary payment, view/download salary slips",
    key: "payroll",
    is_organization_module: true,
    is_default_module: false,
    is_super_admin_module: false,
  },
];

// Recovered verbatim (uncommented, deduped) from public/defaultData/sub_modules.js.
// "assignment"'s main_module already exists in the DB (empty shell, zero
// children) — these sub_modules attach to it without re-creating the parent.
const NEW_SUB_MODULES = [
  // leave_management
  { name: "Leave Type", key: "leave_type", main_module_key: "leave_management", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Assign Leave", key: "assign_leave", main_module_key: "leave_management", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Users Leave", key: "user_leave", main_module_key: "leave_management", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Leave Request", key: "leave_request", main_module_key: "leave_management", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Apply leave", key: "apply_leave", main_module_key: "leave_management", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: true, is_librarian_module: true, is_parent_module: true },

  // offline_exam
  { name: "exam", key: "exam", main_module_key: "offline_exam", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Exam schedule", key: "exam_schedule", main_module_key: "offline_exam", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: true, is_librarian_module: false, is_parent_module: true },
  { name: "manage_exam", key: "manage_exam", main_module_key: "offline_exam", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "exam_result", key: "exam_result", main_module_key: "offline_exam", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Upload Exam Marks", key: "upload_exam_marks", main_module_key: "offline_exam", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: false, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Result", key: "result", main_module_key: "offline_exam", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: false, is_teacher_module: false, is_student_module: true, is_librarian_module: false, is_parent_module: true },
  { name: "Manage exam grade", key: "manage_exam_grade", main_module_key: "offline_exam", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },

  // session_year
  { name: "Session Year", key: "session_year", main_module_key: "session_year", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },

  // notice_board
  { name: "Notice list", key: "list_notice", main_module_key: "notice_board", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "My Notice", key: "my_notice", main_module_key: "notice_board", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: false, is_teacher_module: true, is_student_module: true, is_librarian_module: true, is_parent_module: true },

  // email_notifications
  { name: "Email Templates", key: "templates", main_module_key: "email_notifications", is_super_admin_module: true, is_organization_module: true, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Send Notification", key: "send_email_notifications", main_module_key: "email_notifications", is_super_admin_module: true, is_organization_module: true, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },

  // payroll
  { name: "Salary Templates", key: "salary_templates", main_module_key: "payroll", is_super_admin_module: false, is_organization_module: true, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Assignment of Salary Templates", key: "salary_template_assignment", main_module_key: "payroll", is_super_admin_module: false, is_organization_module: true, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Salary Payment", key: "salary_payment", main_module_key: "payroll", is_super_admin_module: false, is_organization_module: true, is_branch_organization_module: true, is_teacher_module: false, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "My Salaryslips", key: "my_salaryslips", main_module_key: "payroll", is_super_admin_module: false, is_organization_module: true, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: true, is_parent_module: false },

  // assignment (main_module already exists in DB)
  { name: "Assesment Report", key: "assesment_report", main_module_key: "assignment", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: true },
  { name: "Assignment List", key: "assignment_list", main_module_key: "assignment", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: true, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "Evaluation", key: "evaluation", main_module_key: "assignment", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: false, is_teacher_module: true, is_student_module: false, is_librarian_module: false, is_parent_module: false },
  { name: "My Assignment", key: "my-assignment", main_module_key: "assignment", is_super_admin_module: false, is_organization_module: false, is_branch_organization_module: false, is_teacher_module: false, is_student_module: true, is_librarian_module: false, is_parent_module: false },
];

// Maps each boolean flag to the role that should get default Read access.
// is_super_admin_module is intentionally excluded: super_admin already sees
// every sub_module dynamically via the SUPER ADMIN BYPASS in
// user.controller.js (userSignIn / detailsWithToken), independent of
// default_role_permissions.
const FLAG_TO_ROLE_SLUG = {
  is_organization_module: constants.ROLES_SLUG.ORG_ADMIN,
  is_branch_organization_module: constants.ROLES_SLUG.ORG_BRANCH_ADMIN,
  is_teacher_module: constants.ROLES_SLUG.TEACHER,
  is_student_module: constants.ROLES_SLUG.STUDENT,
  is_parent_module: constants.ROLES_SLUG.PARENT,
  is_librarian_module: constants.ROLES_SLUG.LIBRARIAN,
};

const enableNewModules = async () => {
  let transaction;

  try {
    console.log(`=== enableNewModules (${DRY_RUN ? "DRY RUN" : "LIVE"}) ===`);

    transaction = await sequelize.transaction();

    const existingMainModules = await MainModules.findAll({ raw: true, transaction });
    const existingMainKeys = new Set(existingMainModules.map((m) => m.key));

    const missingMainModules = NEW_MAIN_MODULES.filter((m) => !existingMainKeys.has(m.key));

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

    // Dedupe by key: "session_year" is defined twice, identically, in the
    // source data file.
    const seenKeys = new Set();
    const uniqueNewSubModules = NEW_SUB_MODULES.filter((s) => {
      if (seenKeys.has(s.key)) return false;
      seenKeys.add(s.key);
      return true;
    });

    const missingSubModules = uniqueNewSubModules.filter((s) => !existingSubKeys.has(s.key));

    console.log(`Sub modules missing (to insert): ${missingSubModules.length}`);
    missingSubModules.forEach((s) =>
      console.log(`  + sub_module: ${s.key} (main_module_key: ${s.main_module_key})`)
    );

    const unresolvable = missingSubModules.filter((s) => !moduleMap[s.main_module_key]);
    if (unresolvable.length > 0) {
      throw new Error(
        `Cannot resolve main_module_id for: ${unresolvable.map((s) => s.key).join(", ")}`
      );
    }

    const formattedSubModules = missingSubModules.map((s) => ({
      ...s,
      main_module_id: moduleMap[s.main_module_key],
      menu_main_module_id: moduleMap[s.main_module_key],
    }));

    let insertedSubModules = [];
    if (formattedSubModules.length > 0 && !DRY_RUN) {
      insertedSubModules = await SubModules.bulkCreate(formattedSubModules, {
        transaction,
        returning: true,
      });
    }

    const roleCache = {};
    for (const slug of Object.values(FLAG_TO_ROLE_SLUG)) {
      if (!roleCache[slug]) {
        const role = await getRoleService({ slug });
        if (!role) throw new Error(`Role not found for slug: ${slug}`);
        roleCache[slug] = role;
      }
    }

    const subModulesForPermissions = DRY_RUN
      ? missingSubModules.map((s, i) => ({ ...s, id: `(new-id-for-${s.key})` }))
      : insertedSubModules;

    const rolePermissionArr = [];
    subModulesForPermissions.forEach((sm) => {
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
      console.log("=== DRY RUN complete, nothing written (transaction rolled back) ===");
    } else {
      await transaction.commit();
      console.log("=== Sync complete and committed ===");
    }
  } catch (err) {
    console.error("=== enableNewModules ERROR ===");
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

module.exports = { enableNewModules };

if (require.main === module) {
  (async () => {
    try {
      await enableNewModules();
      process.exit(0);
    } catch (err) {
      console.error("Fatal error:", err);
      process.exit(1);
    }
  })();
}
