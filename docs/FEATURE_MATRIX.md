# Feature and Evidence Matrix

| Capability | Included project artifact | Demo guidance |
|---|---|---|
| Telegram intake and command routing | n8n workflow export | Show `/start` and one supported command in the configured demo instance |
| Income and expense logging | Workflow intent validation and core RPC route | Use synthetic transactions and show the resulting ledger state |
| Balance and budget snapshot | Core snapshot route and database function source | Compare returned values against a known synthetic seed state |
| Summaries and budget tracking | Workflow routes and SQL sources | Show a short period with known sample records |
| Debt and repayment tracking | Workflow actions and database function source | Demonstrate a partial repayment and remaining amount |
| Semester obligations and savings goals | Planner route and planner migration source | Use a synthetic fee and goal; state that the plan is informational |
| Forecast and what-if estimates | Planner route and migration source | Show assumptions and confirm that what-if does not create a transaction |
| Account-data deletion | `db/account_deletion_implementation.sql` | Demonstrate only after confirming the matching function and retention behavior in staging |
| FX, travel, price search, optional health support | Provider-dependent workflow branches | Present only routes that are configured and produce actual results |
| Security and access controls | Self-assessment and workflow/database sources | Show role-specific access results and redact all identifiers |

## Evidence standard
Source-code presence describes implementation intent. Demonstration claims should be supported by dated outputs from the same staging configuration shown to reviewers. Use synthetic records, redact identifiers, and include the expected and actual result for each executed test.
