-- Adds the 6 missing FE_XXX translation blocks for the new modules, and
-- patches FE_ASSIGNMENT with its 3 missing dropdown sub-item keys.
-- Only touches the 'en' row; existing keys/values in the messages JSONB
-- blob are preserved untouched (merge via ||, not overwrite).
BEGIN;

\echo 'Before:'
SELECT
  messages ? 'FE_LEAVE_MANAGEMENT' AS has_leave_management,
  messages ? 'FE_OFFLINE_EXAM' AS has_offline_exam,
  messages ? 'FE_SESSION_YEAR' AS has_session_year,
  messages ? 'FE_NOTICE_BOARD' AS has_notice_board,
  messages ? 'FE_EMAIL_NOTIFICATIONS' AS has_email_notifications,
  messages ? 'FE_PAYROLL' AS has_payroll
FROM languages WHERE code = 'en';

UPDATE languages
SET messages = messages || '{
  "FE_LEAVE_MANAGEMENT": {
    "LEAVE_MANAGEMENT": "Leave Management",
    "LEAVE_TYPE": "Leave Type",
    "ASSIGN_LEAVE": "Assign Leave",
    "USER_LEAVE": "Users Leave",
    "LEAVE_REQUEST": "Leave Request",
    "APPLY_LEAVE": "Apply Leave"
  },
  "FE_OFFLINE_EXAM": {
    "OFFLINE_EXAM": "Examination",
    "EXAM": "Exam",
    "MANAGE_EXAM": "Manage Exam",
    "MANAGE_EXAM_GRADE": "Manage Exam Grade",
    "EXAM_SCHEDULE": "Exam Schedule",
    "UPLOAD_EXAM_MARKS": "Upload Exam Marks",
    "EXAM_RESULT": "Exam Result",
    "RESULT": "Result"
  },
  "FE_SESSION_YEAR": {
    "SESSION_YEAR": "Session Year"
  },
  "FE_NOTICE_BOARD": {
    "NOTICE_BOARD": "Notice Board",
    "CREATE_NOTICE": "Create Notice",
    "LIST_NOTICE": "List Notice",
    "MY_NOTICE": "My Notice"
  },
  "FE_EMAIL_NOTIFICATIONS": {
    "EMAIL_NOTIFICATIONS": "Email Notification",
    "TEMPLATES": "Templates",
    "SEND_EMAIL_NOTIFICATIONS": "Send Notification"
  },
  "FE_PAYROLL": {
    "PAYROLL": "Payroll",
    "SALARY_TEMPLATES": "Salary Templates",
    "SALARY_TEMPLATE_ASSIGNMENT": "Assignment of Salary Templates",
    "SALARY_PAYMENT": "Salary Payment",
    "MY_SALARYSLIPS": "My Salaryslips"
  }
}'::jsonb
WHERE code = 'en';

UPDATE languages
SET messages = jsonb_set(
  messages,
  '{FE_ASSIGNMENT}',
  (messages -> 'FE_ASSIGNMENT') || '{
    "ASSESMENT_REPORT": "Assesment Report",
    "EVALUATION": "Evaluation",
    "MY-ASSIGNMENT": "My Assignment"
  }'::jsonb
)
WHERE code = 'en';

\echo 'After:'
SELECT
  messages ? 'FE_LEAVE_MANAGEMENT' AS has_leave_management,
  messages ? 'FE_OFFLINE_EXAM' AS has_offline_exam,
  messages ? 'FE_SESSION_YEAR' AS has_session_year,
  messages ? 'FE_NOTICE_BOARD' AS has_notice_board,
  messages ? 'FE_EMAIL_NOTIFICATIONS' AS has_email_notifications,
  messages ? 'FE_PAYROLL' AS has_payroll
FROM languages WHERE code = 'en';

\echo 'FE_ASSIGNMENT after patch:'
SELECT jsonb_pretty(messages -> 'FE_ASSIGNMENT') FROM languages WHERE code = 'en';

COMMIT;
