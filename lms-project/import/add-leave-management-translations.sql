-- Adds the 45 missing FE_LEAVE_MANAGEMENT sub-keys used throughout the leave
-- management forms (assign leave, apply leave, leave type, leave request) --
-- only the 6 sidebar/menu-level keys were added earlier this session
-- (LEAVE_MANAGEMENT, LEAVE_TYPE, ASSIGN_LEAVE, USER_LEAVE, LEAVE_REQUEST,
-- APPLY_LEAVE), leaving every field label/validation message in the actual
-- forms blank. Merge via ||, non-destructive to the existing 6 keys.
BEGIN;

\echo 'Before (key count):'
SELECT jsonb_object_keys(messages -> 'FE_LEAVE_MANAGEMENT') FROM languages WHERE code = 'en';

UPDATE languages
SET messages = jsonb_set(
  messages,
  '{FE_LEAVE_MANAGEMENT}',
  (messages -> 'FE_LEAVE_MANAGEMENT') || '{
    "APPLICANT": "Applicant",
    "APPLY_DATE": "Apply Date",
    "APPLY_LEAVE_DETAILS": "Apply Leave Details",
    "APPROVE_REJECT_LEAVES": "Approve/Reject Leaves",
    "ARE_YOU_SURE_UPDATE_LEAVE_FOR_OLD_USER": "Are you sure you want to update leave for existing users?",
    "ARE_YOU_SURE_WANT_DELETE_APPLY_LEAVE": "Are you sure you want to delete this leave application?",
    "ARE_YOU_SURE_WANT_DELETE_ASSIGN_LEAVE": "Are you sure you want to delete this assigned leave?",
    "ARE_YOU_SURE_WANT_DELETE_LEAVE_REQUEST": "Are you sure you want to delete this leave request?",
    "ARE_YOU_SURE_WANT_DELETE_LEAVE_TYPE": "Are you sure you want to delete this leave type?",
    "ASSIGN_LEAVE_DETAILS": "Assign Leave Details",
    "ATTACHMENT": "Attachment",
    "COMMENTS": "Comments",
    "CREATE_LEAVE_TYPE": "Create Leave Type",
    "DATE_OF_END": "End Date",
    "DATE_OF_START": "Start Date",
    "DAYS": "Days",
    "DAYS_REQURIED": "Days Required",
    "DAYS_REQURIED_INTEGER": "Days required must be a whole number.",
    "DELETE_APPLY_LEAVE": "Delete Apply Leave",
    "DELETE_ASSIGN_LEAVE": "Delete Assign Leave",
    "DELETE_LEAVE_REQUEST": "Delete Leave Request",
    "DELETE_LEAVE_TYPE": "Delete Leave Type",
    "DOCUMENT": "Document",
    "EDIT_APPLY_LEAVE": "Edit Apply Leave",
    "EDIT_ASSIGN_LEAVE": "Edit Assign Leave",
    "EDIT_LEAVE_TYPE": "Edit Leave Type",
    "EDIT_USER_LEAVES": "Edit User Leaves",
    "END_DATE": "End Date",
    "END_DATE_REQ": "End date is required.*",
    "ENTER_DAYS": "Enter days",
    "ENTER_LEAVE_TYPE": "Enter leave type",
    "ENTER_REASON": "Enter reason",
    "LEAVE_ROLE_MESSAGE": "Please select a role.*",
    "LEAVE_TYPE_DETAILS": "Leave Type Details",
    "LEAVE_TYPE_MAX_MESSAGE": "Leave type name should not exceed 50 characters.",
    "LEAVE_TYPE_MESSAGE": "Please enter a leave type.*",
    "LEAVE_TYPE_SELECT": "Please select a leave type.*",
    "MAX_DAYS_REQUIRED": "Maximum days required",
    "NO_NEGATIVE_VALUES": "Negative values are not allowed.",
    "NUMBER_OF_DAYS": "Number of Days",
    "NUMBER_OF_LEAVES": "Number of Leaves",
    "REASON": "Reason",
    "REASON_REQ": "Reason is required.*",
    "REVIEW_BY": "Reviewed By",
    "ROLE": "Role",
    "START_DATE": "Start Date",
    "START_DATE_REQ": "Start date is required.*",
    "USER_TYPE_MESSAGE": "Please select a user type.*",
    "VIEW_APPLY_LEAVE": "View Apply Leave",
    "VIEW_ASSIGN_LEAVE": "View Assign Leave",
    "VIEW_LEAVE_TYPE": "View Leave Type"
  }'::jsonb
)
WHERE code = 'en';

\echo 'After (key count):'
SELECT jsonb_pretty(messages -> 'FE_LEAVE_MANAGEMENT') FROM languages WHERE code = 'en';

COMMIT;
