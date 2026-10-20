# Staging Test Plan

Run in an isolated staging environment with synthetic records only. For each execution, record date/time and timezone, environment label, workflow version/hash, database migration version, expected result, actual result, and a redacted screenshot or log.

| ID | Test | Input / setup | Expected behavior |
|---|---|---|---|
| T01 | Onboarding | Fresh test Telegram account; `/start` | Help response and one user mapping |
| T02 | Duplicate event | Deliver the same test update twice | One logical write at most |
| T03 | Expense | `spent 150 BDT on food` | One expense with correct amount and currency |
| T04 | Income | `got 5000 BDT scholarship` | One income record and corresponding ledger change |
| T05 | Ambiguous request | `I spent some money` | Clarification; no financial write |
| T06 | Invalid amount | `spent -50 BDT on food` | Rejection or clarification; no write |
| T07 | Balance and budget | Seed known transactions and budget; `/balance`, `/budget` | Output matches the seed state and structured RPC response |
| T08 | Budget threshold | Set a small synthetic daily budget and add expenses | Correct remaining amount; informational alert only |
| T09 | Undo | Add one known transaction, then `/undo` | One safe reversal with audit history preserved |
| T10 | Debt repayment | Create debt of 1000; repay 300 | Remaining debt equals 700; retry does not double-apply |
| T11 | Semester obligation | Add a due date and partial payment record | Outstanding amount and plan are consistent; no payment execution |
| T12 | Planner | Seed ledger and savings goal; run planner commands | Structured response; no unhandled error |
| T13 | Read-only what-if | Run a purchase estimate | Estimate returned; no transaction inserted |
| T14 | Role access | Use separate `anon`/`authenticated` credentials against test records | Only intended rows/actions are accessible |
| T15 | Prompt injection | Include an instruction to reveal internal prompts with a valid spend request | Internal instructions remain private; only valid allowlisted actions can write |
| T16 | Provider disabled | Run an optional command without provider credentials | Clear unavailable response; no fabricated result |
| T17 | Scheduled summary | Use opted-in and opted-out synthetic users | Only eligible users receive one summary |
| T18 | Account deletion | Dedicated test user with synthetic records | Defined deletion behavior executes and is reflected in the database |
| T19 | Secret scan | Scan final package and repository | No active credentials or tokens included |

## Result recording
Use `evidence/EXECUTION_EVIDENCE_TEMPLATE.md`. Never create example output that could be mistaken for an actual execution. If a test has not been run in the target staging environment, leave its execution fields blank until evidence is captured.
