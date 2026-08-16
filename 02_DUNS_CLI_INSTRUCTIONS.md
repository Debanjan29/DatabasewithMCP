# DUNS Schema CLI — Operating Instructions

## 1. Schema Awareness

- At the start of every session, study the entire database schema.
- Maintain a local cached copy of the schema for reference, so the database isn't queried unnecessarily.
  - This copy must be a **persisted, human-readable file in the workspace** (e.g. JSON or YAML), not an in-memory/in-session-only cache. It has to survive after the session ends, since the whole point is to let a *future* session refer back to it instead of the tool re-querying the live database.
  - On each session start, the tool may load this file into memory for working use — but the on-disk file remains the source of truth, and is what gets refreshed or referred to.
- Every session, ask the user how they want to proceed:
  - Query the live database now and refresh the cached copy, or
  - Use the existing cached copy as-is.
- Never assume — always ask this question before proceeding, unless the user has set a standing preference.
- Row counts during schema cataloging must come from metadata, not a scan. Use SQL Server's tracked row counters (sys.partitions / sys.dm_db_partition_stats) to populate table sizes in the schema cache — never SELECT COUNT(*) for this purpose. A full-table COUNT(*) across every table during routine schema study is unnecessary I/O against a live client system and risks command timeouts on large tables; the metadata-based count is instant regardless of table size and is accurate enough for cataloging and for flagging which tables are large enough to need a maintenance window (see 01_STRICT_REVIEW_SAFE_EXECUTION_POLICY.md, Section 9). This approximate count is not a substitute for the live, predicate-specific scale check already required before executing a specific change (see the same file, Section 5) — that check has its own, separate metadata-first approach for a different purpose.

## 2. Scope of Work

- The purpose of this tool is to perform **DUNS expansion**: DDL changes to tables and associated data migration, driven entirely by user navigation/request.
- **DUNS** = a single attribute, a set of attributes, or any column matching a `%DUN%`-style naming pattern. Treat all of these as in-scope when identifying DUNS-related objects.
- Do not act on any table, column, or object outside what the user has navigated to or explicitly requested.

## 3. Impact Analysis (mandatory, every time)

- Before proposing or describing any change, perform a detailed **impact analysis**:
  - Identify every table, column, constraint, and index affected.
  - Identify every stored procedure (SP) that references the affected objects, and assess how each SP would be impacted if the change is made.
  - Identify any other dependent objects (views, triggers, foreign keys) tied to the change.
  - Surface data-level risk (e.g. truncation, precision loss, row counts affected).
- Present this analysis to the user in full detail before any change is proposed for execution.

## 4. Write Operations

- **No write operation of any kind may be performed without explicit manual approval from the user.**
- This applies to all DDL changes and all data migration steps — no exceptions, no auto-approval, no batching of approvals.
- Read-only operations (schema inspection, discovery, impact analysis) do not require approval and can run freely.
- Once approved, execute only the specific, reviewed change — do not expand scope during execution.

## 5. Transactions, Rollback & Failure Handling

### Transactions
- Wrap every DDL change in an explicit transaction with `SET XACT_ABORT ON`, so any error inside the transaction forces a full rollback instead of leaving the transaction open.
- Scope each transaction to one logical change (one table / one column change) rather than bundling multiple unrelated DUNS changes together — this limits lock duration and blast radius if something fails.
- Flag tables above a configurable size/row-count threshold during impact analysis as requiring a maintenance window rather than a live-hours change, since `ALTER TABLE` takes a schema-modification lock that blocks readers and writers on that table.
- Set an explicit `LOCK_TIMEOUT` on the session running the DDL so a blocked change fails fast and reports back, instead of hanging indefinitely.

### Data migration batching
- Never migrate data in a single large transaction — batch it (e.g. 10k–50k rows per batch) with its own commit per batch.
- Track migration progress in a checkpoint table so a batched migration is resumable if interrupted.
- Make clear in the plan presented for approval that a batched migration is resumable/idempotent, not instantly reversible as a single atomic unit — this must be disclosed upfront, not discovered mid-run.

### Rollback scripts
- Generate the rollback script alongside the forward plan, before execution, and present both together for approval — never generate the rollback script only after something goes wrong.
- For DDL rollbacks, build in a pre-check (e.g. "does any row exceed the old column width?") before reversing a change, since a blind reverse `ALTER` can fail or truncate data if the forward change already allowed wider/different data to be written.
- For data migration rollbacks, write the explicit reverse transformation as code — a database-native "undo" does not exist for data movement once committed.
- Where a non-prod/staging environment is available, run the forward plan and its rollback script there first and confirm the round trip restores the original state, before running the forward plan against the real database. Where no staging environment is available, the rollback script must be peer-reviewed carefully before execution.

### Unexpected scenario handling
- **Schema drift**: immediately before execution, re-verify the live schema still matches what the impact analysis was run against. If it has changed, abort and re-run analysis rather than proceeding on stale assumptions.
- **Connection drop / disconnect mid-transaction**: confirm the open transaction auto-rolls back, and log this explicitly as "rolled back due to disconnect" rather than letting it disappear silently.
- **Deadlocks**: catch deadlock errors (error 1205) specifically and report them as retryable, not fatal.
- **Permissions issues**: verify permissions on all target objects during the impact-analysis/pre-flight stage, not at execution time.
- **Replication / Always On environments**: if the environment uses an Availability Group, confirm replication lag/sync mode before large changes, since DDL runs against the primary and can spike synchronous-replica latency.
- **Post-execution verification**: after every apply, automatically re-query the schema and run row-count/spot-check validation against the pre-change baseline, and record the verification result in the audit log — success is never assumed just because no error was thrown.

## 6. Interaction Model

- The tool is user-navigation-driven: it waits for the user to request or navigate to a specific change rather than proactively suggesting a full migration plan.
- At each step (schema source selection → discovery → impact analysis → approval → execution), pause and wait for explicit user input before moving to the next step.
