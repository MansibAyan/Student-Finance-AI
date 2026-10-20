# Security Self-Assessment

## Assessment scope
This document describes the controls represented in the available workflow and SQL artifacts and the operational safeguards required for deployment. It is a project self-assessment, not a third-party certification or penetration-test report.

## Security model
| Component / role | Intended access | Control objective |
|---|---|---|
| Telegram user | Own virtual-ledger actions through the bot | Bind sender identity to one application user; do not trust a user-supplied account ID |
| n8n runtime | Invoke approved database functions | Keep credentials in the credential store; restrict editor access; redact execution data |
| Supabase server credential | Server-side RPC execution only | Never expose service-role credentials to clients, public repositories, or demo materials |
| `anon` / `authenticated` roles | Only explicitly approved direct database access | Use least privilege, RLS policies, and explicit function/table grants |
| LLM and optional external services | Minimum request data needed for the task | Avoid secrets and unnecessary personal data; configure optional services deliberately |

## Controls represented in the project artifacts
- Intent and category allowlists are used before supported database actions.
- Numeric and required-field validation is present in the workflow path.
- Structured RPC actions separate workflow parsing from database-side business rules.
- Idempotency/event-deduplication mechanisms are represented for supported write paths.
- Credentials are removed from the shareable workflow export and must be bound privately during deployment.
- The product is presented as a virtual ledger; it does not initiate payments.
- Optional health-profile handling includes explicit consent commands in the workflow source.
- Account-data deletion implementation SQL is included as a separate source artifact.

## Deployment control checklist
1. Keep Supabase service credentials and bot/provider tokens only in private credential stores.
2. Confirm effective grants and RLS behavior for each database role using separate test credentials.
3. Review each exposed function, especially `SECURITY DEFINER` functions, for ownership checks, safe `search_path`, and least-privilege execute grants.
4. Confirm the workflow's project-reference URLs and credential bindings in the target n8n instance.
5. Exercise balance/budget snapshots, duplicate delivery, retries, undo, debt repayment, pending confirmations, planner actions, and account deletion using synthetic test records.
6. Review n8n execution retention and redact financial message content from logs and screenshots.
7. Disable optional provider-dependent routes until credentials, rate limits, privacy handling, and output behavior are configured.
8. Keep backups and a rollback plan for schema changes; apply migrations in staging before production.

## Operational considerations
- A complete schema export and exact migration history must accompany a reproducible deployment.
- Runtime behavior depends on the target database schema, migration version, private credentials, and enabled provider integrations.
- Database access policies must be assessed from effective grants and real role-specific requests, not from policy definitions alone.
- Workflow and database changes should be versioned together so the RPC contract remains consistent.
- Logs and demo screenshots should use synthetic records and exclude credentials, personal identifiers, and private financial details.

## Conclusion
The implementation follows a layered design with workflow validation, server-side database operations, credential separation, and data-minimization principles. Deployment should use the checklist above as a release control, and any demo claims should match the exact configuration and dated execution evidence included with the submission.
