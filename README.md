# Student Finance AI Agent

**Competition package | International Track | Student Finance Assistant**

## Project overview
Student Finance AI is a conversational personal-finance assistant for students. It combines Telegram as the user interface, n8n for workflow orchestration, and Supabase/PostgreSQL functions for ledger operations and planning. Natural-language requests are mapped to a constrained set of actions; numeric and categorical inputs are validated before database operations.

The product is a **virtual ledger and planning assistant**. It does not connect to bank accounts, hold funds, or execute payments. Forecasts are estimates based on entries recorded by the user.

## Main capabilities represented in the source package
- Record income and expenses
- View balance snapshots, budgets, summaries, and debts
- Track semester obligations and savings goals
- Estimate spending pace and compare what-if scenarios
- Support account-data deletion through the included implementation artifact
- Provide optional quote/search and health-support routes when separately configured

Optional integrations are configuration-dependent. Only demonstrate a route when it is enabled and returns the expected result in the demo environment.

## Architecture
Telegram update → n8n event handling and routing → constrained intent parsing and validation → allowlisted Supabase RPC → structured result → Telegram response.

## Package contents
- `workflow/` — sanitized n8n workflow export
- `db/` — SQL implementation sources and deployment notes
- `docs/TECHNICAL_DOCUMENTATION.md` — system architecture, algorithm, assumptions, and deployment guidance
- `docs/SECURITY_SELF_ASSESSMENT.md` — security design, controls, and deployment checklist
- `docs/FEATURE_MATRIX.md` — capability and evidence scope
- `tests/TEST_PLAN.md` — reproducible test cases for an isolated environment
- `evidence/EXECUTION_EVIDENCE_TEMPLATE.md` — structured record for dated, redacted test runs
- `presentation/` — competition deck and demo script

## Deployment outline
1. Create an isolated Supabase staging project and obtain the matching complete schema/migration set from the project owner.
2. Review migration prerequisites and apply SQL in the documented order in staging first.
3. Store Supabase, Telegram, and model-provider credentials in the n8n credential store. Do not place secrets in workflow JSON, screenshots, or source control.
4. Import the sanitized workflow; bind credentials privately and replace the Supabase project-reference placeholder in RPC URLs.
5. Run the test plan using synthetic data and a dedicated test account.
6. Save dated, redacted execution outputs and screenshots in `evidence/`.
7. Export the final workflow and source bundle, run a secret scan, and publish the repository link required by the competition.

## Data protection principles
- Least-privilege access and server-side credentials
- User-scoped records and database-side ownership checks
- Idempotency for supported event/write paths
- Data minimization for LLM and external-provider calls
- Synthetic demo records and redacted logs
- Explicit user control over optional sensitive profile data

## Scope and release boundary
This package documents a prototype implementation. A reproducible deployment requires the complete schema for the target database, private credential binding, and test evidence from the exact staging configuration used for demonstration. These are environment-specific deployment artifacts and should not be replaced with illustrative screenshots or simulated claims.
