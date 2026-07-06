# Old DB CSV export — data audit

Automated pass over all 81 CSV files in `Olddev_database.zip` (27,784 total
data rows). Checked: header/column consistency, ragged rows, duplicate or
blank primary keys, encoding/BOM issues, and foreign-key referential
integrity within each database group. Full methodology: parsed every file
with Python's `csv` module (not just line-counting, so quoted
newlines/commas in text fields don't skew results), diffed each row's
column count against the header, and cross-checked ID sets between
related tables in the same folder.

## Structural quality: clean

- **No ragged rows** in any of the 81 files (every row's column count
  matches its header).
- **No duplicate or blank primary keys** in any file.
- **No encoding problems** — every file is valid UTF-8, no BOM.
- Every file's column headers line up with the current model's fields for
  the tables that are actually still in use (spot-checked against
  `sequelize.define()` calls).

## Referential integrity: clean

Checked 13 parent/child relationships across the `User Management`,
`Tickets`, `Super Admin`, and `Organization` folders (e.g.
`user_roles.user_id → users.id`, `tickets.issue_type_id → issue_types.id`,
`organization_admins.organization_id → organizations.id`,
`classes.organization_branch_id → organization_branches.id`, etc.) — **zero
orphaned foreign keys** in every single one.

One minor note: `User Management/user_roles` has 18 rows (out of 433) with
a **blank** `user_id` — not an FK violation (nothing points at a
nonexistent row), just incomplete data; those rows will import fine as
long as the column allows nulls, but they're not meaningfully associated
with a user.

## Empty tables (0 data rows, header only)

These import cleanly as no-ops — nothing to lose either way:

- `User Management/user_organization_branch_mappings` — the one flagged in
  `OLD_DB_ANALYSIS.md` as having no matching model in the current
  `usermgmt` repo. Since the export itself has zero rows, this is now a
  non-issue regardless of whether you rebuild the model.
- `Super Admin/attachments`, `Super Admin/comments`,
  `Super Admin/issue_types`, `Super Admin/tickets` — confirms these are
  pure leftover schema with **no data**, from before ticketing moved to
  its own service. Safe to skip with zero data loss (as already
  recommended in `OLD_DB_ANALYSIS.md`).
- `Organization/assignment_attachments`,
  `Organization/assignment_submissions_attachments`,
  `Organization/assignment_submissions`, `Organization/syllabuses` — these
  ARE current, in-use tables in the `org` backend; they're just empty in
  this particular export (no assignments/syllabus data existed yet at
  export time). Nothing to do — sync() will create them, import will have
  nothing to load.

## Update on the `Organization` folder's legacy ticket tables

Earlier analysis recommended skipping
`Organization/{tickets,comments,attachments,issue_types}` as orphaned.
Refining that: unlike the `Super Admin` copies (which are empty), the
`Organization` copies **do have data** — 6 tickets, 11 comments, 5 issue
types, 6 attachments. Checked further:

- **Zero ID overlap** with the real `Tickets` folder's data (63 tickets,
  36 comments, 47 issue types, 13 attachments) — these are genuinely
  different records, not duplicates already migrated.
- **Schema mismatch**: `Organization/tickets` has 10 columns; the current
  ticket service's `tickets` table has 14 (missing `is_read`,
  `assigned_to`, `organization_branch_id`, `organization_id`) — this data
  predates the current ticket schema.
- **Content**: all 6 tickets are dated 2023-11-20 with descriptions like
  "Ticket 1 Testing 1", "dsdasd", "Latest Testing 1000" — QA/dev smoke-test
  data, not real user tickets.

Recommendation unchanged: **skip these 4 files** (as `prepare-csv-dir.sh
--skip-legacy-tickets` already does) — the data is low-value test content
and structurally incompatible with the current ticket schema anyway. If
you do want to preserve it for historical record, it would need manual
column-mapping (backfilling `organization_id`/`organization_branch_id`/
`assigned_to`/`is_read`) rather than a straight CSV import — not something
to automate for 6 test rows.

## Largest tables (sanity check — nothing unusual, just for scale)

| Table | Rows |
|---|---|
| `states` (duplicated per-service reference data) | 5,084 each in `user_management`, `super_admin`, `organization` |
| `plan_modules` (Super Admin) | 2,477 |
| `roles_and_permissions` (User Management) | 1,414 |
| `teacher_section` (Organization) | 486 |
| `users` (User Management) | 415 |

## Bottom line

The export is structurally sound and internally consistent — you can
import it with confidence using `prepare-csv-dir.sh` +
`import-tables.sh` as documented in `OLD_DB_ANALYSIS.md`. The only real
judgment calls are the already-documented orphan tables, and none of them
represent meaningful data loss.
