# Database Artifacts and Deployment Order

This folder contains SQL implementation sources for the Student Finance AI prototype. Apply them only in an isolated staging project after matching prerequisites to the target database.

## Included
- `stage_Audit_functions_source_OWNER_PROVIDED.sql` — available multi-function SQL source with prerequisites noted in its header.
- `student_finance_planner_migration.sql` — additive planner migration for `public.student_planner_handle`; confirm the required base function exists before applying it.
- `account_deletion_implementation.sql` — account-data deletion implementation artifact.

## Deployment sequence
1. Obtain the complete schema and migration history matching the target Supabase project.
2. Review function bodies, row-level security policies, grants, triggers, and extensions.
3. Apply the schema and migrations in a disposable staging project in the documented order.
4. Run the regression and access-control tests with synthetic data.
5. Apply to production only through the project owner's approved change process, with a backup and rollback plan.
6. Keep service-role credentials, bot tokens, and provider API keys in private credential storage, never in this repository.
