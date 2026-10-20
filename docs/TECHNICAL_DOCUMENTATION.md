# Technical Documentation

## 1. Problem and intended users
Students often need a simple way to record spending, income, budgets, debts, semester obligations, and savings targets. Student Finance AI provides a conversational interface to a virtual ledger and basic planning aids. It is not a bank, does not access bank balances, and does not initiate transfers.

## 2. System architecture
- **Interface:** Telegram bot.
- **Orchestration:** n8n handles incoming updates, routing, user setup, supported event deduplication, RPC calls, response formatting, and scheduled-summary logic.
- **Language layer:** an LLM chain maps supported free-text requests into constrained intent data. Code nodes validate intent, amount, currency, category, date, and required fields before forming an action.
- **Data layer:** Supabase/PostgreSQL functions act as the persistence and business-rule layer. The workflow uses `app_handle` for core finance actions and `student_planner_handle` for planner actions where configured.
- **Optional services:** FX, travel, price search, payment quotes, and health-support routes require their own credentials, configuration, privacy review, and testing.

## 3. Core request algorithm
1. Receive a Telegram update and identify its event.
2. Apply duplicate-event handling where supported.
3. Map the sender to an application user.
4. Parse direct commands deterministically where possible.
5. For free text, request a constrained intent representation; treat user content as data, not instructions to the workflow.
6. Validate the action against allowlists and numeric/date constraints. Clarify ambiguous requests instead of writing them.
7. Construct an allowlisted database action and idempotency key for supported write paths.
8. Execute the database function and interpret its structured response.
9. Return a clear message that distinguishes ledger figures and estimates from actual bank balances or completed payments.

## 4. Data domains
The project inventory includes users, transactions, accounts, budgets, daily budget history, debts and repayments, semester obligations, savings goals, recurring transactions, pending actions, processed events, audit records, user settings, notification data, quote/price data, and optional health-support data. The exact schema must match the target Supabase project; a table inventory is not a substitute for a full schema export.

## 5. Consistency and duplicate handling
Available project artifacts describe idempotency keys for supported financial write paths and event-level deduplication. These mechanisms should be exercised under repeated delivery, retries, and concurrent requests in staging. Failure/retry behavior should be checked for each operation that crosses a workflow/database boundary.

## 6. Financial assumptions
- Balance and budget figures are derived from entries in the virtual ledger.
- Forecasts extrapolate recorded spending and are estimates, not guarantees.
- Affordability and what-if calculations are decision-support aids.
- Manually entered quotes may be stale; provider prices and fees can differ.
- No operation should imply that money moved unless the user completed that action outside this system.

## 7. Privacy and safe operation
Financial messages may contain personal information. Minimize free-text retention, send only necessary fields to model or search providers, restrict workflow-editor access, keep credentials server-side, and redact logs. Optional health-related functions require explicit consent and appropriate access/retention controls; disable them when those controls are not in place.

## 8. Deployment and reproducibility
Use an isolated staging project, verify migration prerequisites against the target schema, privately bind credentials, and replace the project-reference placeholder before importing the workflow. Run the accompanying test plan with synthetic data. Include dated redacted logs from the exact configuration used in the presentation. Do not apply review-draft SQL to production without confirming prerequisites and target version.
