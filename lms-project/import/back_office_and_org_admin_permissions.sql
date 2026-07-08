-- Adds default_role_permissions for:
--   1. back_office (currently ZERO permissions -- confirmed active role, 0 users yet)
--   2. org_admin additions: read-only cross-branch reporting visibility
--      (org_admin currently has no visibility into branch operational data at all)
BEGIN;

\echo 'Before counts:'
SELECT r.slug, COUNT(drp.id) AS permission_count
FROM roles r
LEFT JOIN default_role_permissions drp ON drp.role_id = r.id
WHERE r.slug IN ('back_office', 'org_admin')
GROUP BY r.slug;

-- back_office: accounts/admissions/records administration.
-- No academic/curriculum control (no exam creation, no course management, no live classes).
INSERT INTO default_role_permissions (sub_module_id, role_id, role_key, sub_module_key, permissions, "createdAt", "updatedAt")
VALUES
  ('4b295fdc-2e06-47d9-b508-a5701979a529', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'account_settings', '{"Read": true, "Update": true}', NOW(), NOW()),
  ('125b17d2-04f4-41e3-887c-58e0ab2d2cf2', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'student', '{"Read": true, "Write": true, "Update": true}', NOW(), NOW()),
  ('34f58d20-d749-47bc-8443-a61ffd854fde', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'students', '{"Read": true}', NOW(), NOW()),
  ('cb356ddf-72de-47b0-bc47-ba2cd8db6300', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'salary_payment', '{"Read": true, "Write": true}', NOW(), NOW()),
  ('7ea66331-361d-46ff-81a9-c80b7dbc31a2', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'salary_templates', '{"Read": true}', NOW(), NOW()),
  ('9af51dbf-c762-4257-8cd4-e014b3452fa8', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'salary_template_assignment', '{"Read": true}', NOW(), NOW()),
  ('842416be-b2f8-41f4-ad39-2cfd6d0adf6c', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'apply_leave', '{"Read": true, "Write": true, "Delete": true, "Update": true}', NOW(), NOW()),
  ('56eb6786-f9ba-4b95-84bc-3cb347cc015b', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'leave_request', '{"Read": true, "Update": true}', NOW(), NOW()),
  ('180fbd4a-a1e6-460e-a4b8-da46d50e6049', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'attendance_report', '{"Read": true}', NOW(), NOW()),
  ('e5bb9d8c-3994-49a4-bd2a-066d41a5a847', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'exam_result', '{"Read": true}', NOW(), NOW()),
  ('1ff4b70b-755b-4cf0-a4a5-a395530f0905', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'my_attendance', '{"Read": true}', NOW(), NOW()),
  ('1b494de4-e583-418d-a7d2-654e6e7b860d', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'my_notice', '{"Read": true}', NOW(), NOW()),
  ('a1797b26-e699-43af-a6d1-4bba16b864b1', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'my_salaryslips', '{"Read": true}', NOW(), NOW()),
  ('227a2201-1de9-4090-a22f-843c310f7588', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'ticket', '{"Read": true, "Write": true}', NOW(), NOW()),
  ('0a97b013-4331-48d1-8896-55f9256d5261', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'inbox', '{"Read": true, "Update": true}', NOW(), NOW()),
  ('664177f6-c718-4178-934b-d6026742a430', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'email_template', '{"Read": true}', NOW(), NOW()),
  ('8107da0f-bf47-4b1e-969b-ce87392c56e5', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'send_email_notifications', '{"Read": true, "Write": true}', NOW(), NOW()),
  ('677ca644-ba1d-4101-9b84-5f5e6cf59620', '6bcffad6-a948-4b0a-87ef-d036728d1064', 'back_office', 'list_notice', '{"Read": true}', NOW(), NOW());

-- org_admin: read-only cross-branch reporting/oversight visibility (new, additive --
-- does not touch org_admin's existing 18 rows).
INSERT INTO default_role_permissions (sub_module_id, role_id, role_key, sub_module_key, permissions, "createdAt", "updatedAt")
VALUES
  ('125b17d2-04f4-41e3-887c-58e0ab2d2cf2', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'student', '{"Read": true}', NOW(), NOW()),
  ('34f58d20-d749-47bc-8443-a61ffd854fde', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'students', '{"Read": true}', NOW(), NOW()),
  ('6d994d88-db37-46a7-a553-35cd4a706651', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'teacher', '{"Read": true}', NOW(), NOW()),
  ('5b4cfa14-9ca9-496c-9b8b-58666cc1f9b1', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'class', '{"Read": true}', NOW(), NOW()),
  ('08f3963d-a078-49e4-a60f-7e22dbcb7253', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'section', '{"Read": true}', NOW(), NOW()),
  ('72dea6bb-43c8-464d-b7a4-377d244566a0', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'subject', '{"Read": true}', NOW(), NOW()),
  ('180fbd4a-a1e6-460e-a4b8-da46d50e6049', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'attendance_report', '{"Read": true}', NOW(), NOW()),
  ('e5bb9d8c-3994-49a4-bd2a-066d41a5a847', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'exam_result', '{"Read": true}', NOW(), NOW()),
  ('31374055-990b-4092-8241-bb258a63be08', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'exam_schedule', '{"Read": true}', NOW(), NOW()),
  ('f869d962-29a9-42c9-b9e4-a29c55d47c01', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'live_class_list', '{"Read": true}', NOW(), NOW()),
  ('677ca644-ba1d-4101-9b84-5f5e6cf59620', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'list_notice', '{"Read": true}', NOW(), NOW()),
  ('57738fd9-6c31-4e90-8084-bc5712bb21fe', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'room', '{"Read": true}', NOW(), NOW()),
  ('27418a4f-8b11-4f4e-ade7-95ff5c847440', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'department', '{"Read": true}', NOW(), NOW()),
  ('caa4c832-3522-4b94-b40d-313f1ca8c947', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'category', '{"Read": true}', NOW(), NOW()),
  ('1d1b4ae6-3c3e-458b-a83e-03d84f70b29b', '9a082827-04b3-4f4b-ae4b-c16a288bc3b3', 'org_admin', 'employees', '{"Read": true}', NOW(), NOW());

\echo 'After counts:'
SELECT r.slug, COUNT(drp.id) AS permission_count
FROM roles r
LEFT JOIN default_role_permissions drp ON drp.role_id = r.id
WHERE r.slug IN ('back_office', 'org_admin')
GROUP BY r.slug;

COMMIT;
