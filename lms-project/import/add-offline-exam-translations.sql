-- Offline exam module: same pattern as leave management -- only the 8
-- sidebar/menu-level FE_OFFLINE_EXAM keys were added earlier this session.
-- All form-level labels/placeholders/validation messages across
-- manageexam, manageExamGrade, examResult, examschedule, uploadExamMarks
-- were still blank, spread across 4 different translation blocks:
--   FE_PLACHOLDER (existing, 7 new keys)
--   FE_OFFLINE_EXAM (existing, 17 new keys)
--   FE_REQUIRED (existing, 14 new keys)
--   FE_EXAM (did not exist at all, 1 key)
BEGIN;

\echo 'Before (FE_EXAM should be null):'
SELECT messages -> 'FE_EXAM' FROM languages WHERE code = 'en';

UPDATE languages
SET messages = jsonb_set(
  messages,
  '{FE_PLACHOLDER}',
  (messages -> 'FE_PLACHOLDER') || '{
    "EXAM_DESCRIPTION": "Enter exam description",
    "GREADE": "Select grade",
    "MAX_PERCENTAGE": "Enter maximum percentage",
    "MIN_PERCENTAGE": "Enter minimum percentage",
    "PASSING_MARKS": "Enter passing marks",
    "SELECT_EXAM": "Select exam",
    "TOTAL_MARKS": "Enter total marks"
  }'::jsonb
)
WHERE code = 'en';

UPDATE languages
SET messages = jsonb_set(
  messages,
  '{FE_OFFLINE_EXAM}',
  (messages -> 'FE_OFFLINE_EXAM') || '{
    "ARE_YOU_SURE_WANT_TO_DELETE": "Are you sure you want to delete this?",
    "ARE_YOU_SURE_WANT_TO_DELETE_GRADE": "Are you sure you want to delete this grade?",
    "ARE_YOU_SURE_WANT_TO_THIS_EXAM": "Are you sure you want to delete this exam?",
    "CREATE_EXAM": "Create Exam",
    "DELETE_EXAM": "Delete Exam",
    "DELETE_SCHEDULE": "Delete Schedule",
    "EDIT_EXAM": "Edit Exam",
    "EXAM_DETAILS": "Exam Details",
    "EXAM_NAME": "Exam Name",
    "GRADE": "Grade",
    "MAX_PERCENTAGE": "Max Percentage",
    "MIN_PERCENTAGE": "Min Percentage",
    "OBTAINED_MARKS": "Obtained Marks",
    "PASSING_MARKS": "Passing Marks",
    "PASSING_POINT_VAL": "Passing point must be less than or equal to max percentage.",
    "TOTAL_MARKS": "Total Marks",
    "VIEW_EXAM": "View Exam"
  }'::jsonb
)
WHERE code = 'en';

UPDATE languages
SET messages = jsonb_set(
  messages,
  '{FE_REQUIRED}',
  (messages -> 'FE_REQUIRED') || '{
    "CLASS": "Class is required.*",
    "DATE": "Date is required.*",
    "DESCRIPTION": "Description is required.*",
    "GRADE": "Grade is required.*",
    "MAX_PERCENTAGE": "Max percentage is required.*",
    "MIN_PERCENTAGE": "Min percentage is required.*",
    "PASSING_MARKS": "Passing marks is required.*",
    "SECTION": "Section is required.*",
    "SELECT_EXAM": "Please select an exam.*",
    "SELECT_STUDENT": "Please select a student.*",
    "STUDENT": "Student is required.*",
    "TOTAL_MARKS": "Total marks is required.*",
    "VALIDATION_FOR_PLUS_MIN": "Max percentage must be greater than min percentage.",
    "VALIDATION_MESSAGE": "This field is required.*"
  }'::jsonb
)
WHERE code = 'en';

-- FE_EXAM did not exist at all -- add it as a new top-level key.
UPDATE languages
SET messages = messages || '{
  "FE_EXAM": {
    "EXAM_SCHEDULE_DETAILS": "Exam Schedule Details"
  }
}'::jsonb
WHERE code = 'en';

\echo 'After:'
SELECT jsonb_pretty(messages -> 'FE_EXAM') FROM languages WHERE code = 'en';
SELECT jsonb_object_keys(messages -> 'FE_PLACHOLDER') FROM languages WHERE code = 'en' AND messages -> 'FE_PLACHOLDER' ? 'SELECT_EXAM';
SELECT jsonb_object_keys(messages -> 'FE_OFFLINE_EXAM') FROM languages WHERE code = 'en';

COMMIT;

-- Follow-up fixes (same day):
-- 1. FE_COMMON.OPTIONAL was missing entirely (used in 20 files app-wide,
--    not offline-exam-specific) -- caused "Select Room (undefined)" on the
--    exam schedule create page.
-- 2. FE_PLACHOLDER.GREADE's placeholder text "Select grade" was misleading:
--    the Grade field on Manage Exam Grade is a free-text Input (type a
--    letter grade like "A"/"B+"), not a dropdown -- the wording made users
--    think it was an empty/broken select. Reworded to "Enter grade (e.g. A, B+, C-)".
UPDATE languages
SET messages = jsonb_set(messages, '{FE_COMMON,OPTIONAL}', '"Optional"'::jsonb)
WHERE code = 'en';

UPDATE languages
SET messages = jsonb_set(messages, '{FE_PLACHOLDER,GREADE}', '"Enter grade (e.g. A, B+, C-)"'::jsonb)
WHERE code = 'en';

-- Follow-up: Manage Exam list's column headers used
-- FE_OFFLINE_EXAM.EXAM_SCHEDULE_CREATED and .PUBLISH_RESULT (in a separate
-- coulmns.tsx file not covered by the earlier audit of the offlineexam/
-- shared folder) -- showed as blank headers with "Yes"/"No" values under them.
UPDATE languages
SET messages = jsonb_set(
  messages,
  '{FE_OFFLINE_EXAM}',
  (messages -> 'FE_OFFLINE_EXAM') || '{
    "EXAM_SCHEDULE_CREATED": "Exam Schedule Created",
    "PUBLISH_RESULT": "Publish Result"
  }'::jsonb
)
WHERE code = 'en';
