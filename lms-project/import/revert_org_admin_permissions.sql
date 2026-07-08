-- Reverts the 15 new org_admin read-only cross-branch reporting keys added
-- earlier this session (see back_office_and_org_admin_permissions.sql /
-- backfillBackOfficeAndOrgAdminPermissions.js). User feedback: the report
-- screens these keys unlocked (students, teacher, class, attendance_report,
-- exam_result, live_class_list, etc.) don't show which branch each row
-- belongs to and have no branch filter -- so read-only "visibility" across
-- branches was actually meaningless/confusing as currently built. Reverted
-- to the pre-session state.
--
-- Does NOT touch back_office (separate, unaffected, still live) or
-- org_admin's original 18 permission rows (pre-existing, unrelated to this
-- session).
--
-- Ran on staging 2026-07-08: deleted 210 users_permissions rows (org_admin_staff),
-- 1005 roles_and_permissions rows, 15 default_role_permissions rows. Confirmed
-- org_admin back to exactly 18 default_role_permissions afterward.
BEGIN;

\echo 'Before counts:'
SELECT 'default_role_permissions' AS table_name, COUNT(*) FROM default_role_permissions drp
  JOIN roles r ON r.id = drp.role_id WHERE r.slug = 'org_admin'
UNION ALL
SELECT 'roles_and_permissions', COUNT(*) FROM roles_and_permissions rp
  JOIN roles r ON r.id = rp.role_id WHERE r.slug = 'org_admin'
UNION ALL
SELECT 'users_permissions (org_admin_staff)', COUNT(*) FROM users_permissions up
  JOIN user_roles ur ON ur.user_id = up.user_id
  JOIN roles r ON r.id = ur.role_id WHERE r.slug = 'org_admin_staff';

DELETE FROM users_permissions
WHERE sub_module_id IN (
  '125b17d2-04f4-41e3-887c-58e0ab2d2cf2', '34f58d20-d749-47bc-8443-a61ffd854fde',
  '6d994d88-db37-46a7-a553-35cd4a706651', '5b4cfa14-9ca9-496c-9b8b-58666cc1f9b1',
  '08f3963d-a078-49e4-a60f-7e22dbcb7253', '72dea6bb-43c8-464d-b7a4-377d244566a0',
  '180fbd4a-a1e6-460e-a4b8-da46d50e6049', 'e5bb9d8c-3994-49a4-bd2a-066d41a5a847',
  '31374055-990b-4092-8241-bb258a63be08', 'f869d962-29a9-42c9-b9e4-a29c55d47c01',
  '677ca644-ba1d-4101-9b84-5f5e6cf59620', '57738fd9-6c31-4e90-8084-bc5712bb21fe',
  '27418a4f-8b11-4f4e-ade7-95ff5c847440', 'caa4c832-3522-4b94-b40d-313f1ca8c947',
  '1d1b4ae6-3c3e-458b-a83e-03d84f70b29b'
)
AND user_id IN (
  SELECT ur.user_id FROM user_roles ur
  JOIN roles r ON r.id = ur.role_id
  WHERE r.slug = 'org_admin_staff'
);

DELETE FROM roles_and_permissions
WHERE role_id = '9a082827-04b3-4f4b-ae4b-c16a288bc3b3'
AND sub_module_id IN (
  '125b17d2-04f4-41e3-887c-58e0ab2d2cf2', '34f58d20-d749-47bc-8443-a61ffd854fde',
  '6d994d88-db37-46a7-a553-35cd4a706651', '5b4cfa14-9ca9-496c-9b8b-58666cc1f9b1',
  '08f3963d-a078-49e4-a60f-7e22dbcb7253', '72dea6bb-43c8-464d-b7a4-377d244566a0',
  '180fbd4a-a1e6-460e-a4b8-da46d50e6049', 'e5bb9d8c-3994-49a4-bd2a-066d41a5a847',
  '31374055-990b-4092-8241-bb258a63be08', 'f869d962-29a9-42c9-b9e4-a29c55d47c01',
  '677ca644-ba1d-4101-9b84-5f5e6cf59620', '57738fd9-6c31-4e90-8084-bc5712bb21fe',
  '27418a4f-8b11-4f4e-ade7-95ff5c847440', 'caa4c832-3522-4b94-b40d-313f1ca8c947',
  '1d1b4ae6-3c3e-458b-a83e-03d84f70b29b'
);

DELETE FROM default_role_permissions
WHERE role_id = '9a082827-04b3-4f4b-ae4b-c16a288bc3b3'
AND sub_module_id IN (
  '125b17d2-04f4-41e3-887c-58e0ab2d2cf2', '34f58d20-d749-47bc-8443-a61ffd854fde',
  '6d994d88-db37-46a7-a553-35cd4a706651', '5b4cfa14-9ca9-496c-9b8b-58666cc1f9b1',
  '08f3963d-a078-49e4-a60f-7e22dbcb7253', '72dea6bb-43c8-464d-b7a4-377d244566a0',
  '180fbd4a-a1e6-460e-a4b8-da46d50e6049', 'e5bb9d8c-3994-49a4-bd2a-066d41a5a847',
  '31374055-990b-4092-8241-bb258a63be08', 'f869d962-29a9-42c9-b9e4-a29c55d47c01',
  '677ca644-ba1d-4101-9b84-5f5e6cf59620', '57738fd9-6c31-4e90-8084-bc5712bb21fe',
  '27418a4f-8b11-4f4e-ade7-95ff5c847440', 'caa4c832-3522-4b94-b40d-313f1ca8c947',
  '1d1b4ae6-3c3e-458b-a83e-03d84f70b29b'
);

\echo 'After counts (org_admin default_role_permissions should be back to 18):'
SELECT r.slug, COUNT(drp.id) AS default_permission_count
FROM roles r
LEFT JOIN default_role_permissions drp ON drp.role_id = r.id
WHERE r.slug IN ('org_admin', 'back_office')
GROUP BY r.slug;

\echo 'roles_and_permissions counts (org_admin should drop by 1005, back_office unaffected):'
SELECT r.slug, COUNT(rp.id) AS roles_and_permissions_count
FROM roles r
JOIN roles_and_permissions rp ON rp.role_id = r.id
WHERE r.slug IN ('org_admin', 'back_office')
GROUP BY r.slug;

COMMIT;
