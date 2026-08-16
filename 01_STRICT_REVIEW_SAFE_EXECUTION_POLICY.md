# Strict Review & Safe Execution Policy

## 1. Core Rule

**Never change any settings, execute any code, or modify any data without explicit prior user review and approval.**

**All database write operations must be explicitly transaction-wrapped (`BEGIN TRANSACTION ... COMMIT/ROLLBACK`), never relying on implicit/automatic transaction handling from any tool or MCP server.**

This policy applies regardless of *who* ultimately executes the approved script — see Section 6.

---

## 2. Prohibited Autonomous Actions

The following must **never** be performed without explicit prior approval:

- **Role/Privilege changes** — no `ALTER ROLE`, `CREATE ROLE`, `DROP ROLE`, `GRANT`, or `REVOKE`.
- **Unreviewed DML/DDL** — no `INSERT`, `UPDATE`, `DELETE`, `DROP`, `CREATE`, or `ALTER TABLE` without first presenting the exact SQL for review.
- **Reliance on implicit transaction wrapping** — every write must be inside an explicit, manually controlled transaction (see Section 4).
- **Settings & credentials** — no autonomous edits to `.env` files, connection strings, or system configuration without confirmation.
- **Arbitrary code/terminal execution** — no scripts or shell commands run silently without upfront explanation and review.

### Comment handling
Never read, extract, or act on values from commented-out lines (`#`, `//`, `/*`, `--`) in `.env` or configuration files. Only active, uncommented entries are considered valid.

---

## 3. Batching Rule

- Default maximum batch size: **10,000 rows** per commit.
- This limit may only be exceeded if the user explicitly states so within the session, or updates this file directly to change the default. No autonomous override, regardless of table size or perceived low risk.
- Large migrations must be broken into batches using a pattern such as `UPDATE TOP (n) ... ` in a loop, with a separate commit per batch, and a checkpoint/progress marker so the migration is resumable if interrupted.

### 3a. Checkpoint & Resume Handling (Data Migration only)

This applies specifically to column-to-column **data migration** batch loops. Single-statement DDL (adding a column, a future rename) does not need this — it isn't a long-running batch process.

**Checkpoint storage — database, not a file**
- Progress is tracked in a dedicated table, `duns_cli.migration_checkpoint`, created once via its own approved plan (see below) — not auto-created on first use.
- The checkpoint update for a batch happens **inside the same transaction as that batch's data write**, so the checkpoint and the actual migrated rows always commit or roll back together. This is why the checkpoint lives in the database rather than a local file — a local file update can't be made atomic with the database transaction.

```sql
CREATE TABLE duns_cli.migration_checkpoint (
    plan_id               VARCHAR(50)  NOT NULL,
    table_name            SYSNAME      NOT NULL,
    phase                 VARCHAR(20)  NOT NULL DEFAULT 'data_migration',
    last_processed_key    BIGINT       NULL,
    rows_completed         BIGINT      NOT NULL DEFAULT 0,
    estimated_total_rows  BIGINT       NULL,
    status                 VARCHAR(20) NOT NULL DEFAULT 'in_progress',  -- in_progress | completed | failed
    started_at            DATETIME2    NOT NULL DEFAULT SYSUTCDATETIME(),
    last_updated_at       DATETIME2    NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_migration_checkpoint PRIMARY KEY (plan_id, table_name)
);
```

- **Creating this table is itself a write operation** and goes through a normal Phase A/B approval cycle — a one-time setup plan, reused by every future migration plan afterward. It is never silently auto-created.

**Local workspace mirror — for fast inspection, not authoritative**
- After each batch commits, the current checkpoint state is also written to a local JSON file under `.duns-cli/checkpoints/`, purely so progress and failure history can be inspected quickly without querying the database.
- This file also holds structured **failure details** per batch (timestamp, error, what action was taken) — easier to scan than digging through the log file for the same information.
- If the local mirror and the database checkpoint ever disagree, **the database checkpoint wins** — the mirror is a convenience cache, never the source of truth.

```json
{
  "plan_id": "PLAN-2026-0142",
  "table": "dbo.CUSTOMERS",
  "last_processed_key": 640000,
  "rows_completed": 640000,
  "estimated_total_rows": 812000,
  "status": "in_progress",
  "last_synced_from_db_at": "2026-08-16T14:41:10Z",
  "failures": [
    {
      "batch_number": 42,
      "timestamp": "2026-08-16T14:22:03Z",
      "error": "Deadlock victim (error 1205)",
      "action_taken": "ROLLBACK TRANSACTION; batch retried and succeeded at 14:23:10"
    }
  ]
}
```

**On resume — checked against the database, not the local mirror**
- Before the Phase B pre-execution guardrail (Section 4), check `duns_cli.migration_checkpoint` for this plan/table. If a checkpoint exists in `in_progress` or `failed` state, surface it as part of that same confirmation screen, and present an explicit choice — never inferred:
  - **Resume** (default shown) — continue from `last_processed_key`.
  - **Restart** — reprocess from the beginning. Safe only because every batch predicate is required to be idempotent (see below); still requires its own explicit confirmation.
  - **Abort** — leave the checkpoint untouched, exit.

**Idempotency — the requirement that makes Restart safe**
- Every batch predicate must be written so that re-running it doesn't double-apply (e.g. only touching rows where the target column is still unmigrated). This is a constraint on how every Phase 2 migration script is written, not an optional nicety — it's the only reason "Restart" can ever be offered as a safe option.

**Commit/rollback remains manual**
- Per Section 4, each batch's commit still requires an explicit human `COMMIT`/`ROLLBACK` after reviewing that batch's terminal report. This checkpoint design doesn't change that — it only makes each batch resumable/traceable, not auto-approved. (This cadence can be revisited later if manual-per-batch proves impractical at scale — noted as an open design question, not settled here.)

---

## 4. Transaction Flow (Two-Phase)

Approval and execution are deliberately separated so that **no database lock is ever held open while waiting on a human response.**

### Phase A — Review & Approve (no lock held)
1. Draft the exact SQL script (DDL/DML), fully transaction-wrapped and batched per Section 3.
2. Generate the corresponding rollback script alongside it.
3. Run a **dry run** (see Section 5) — read-only, no transaction, no lock.
4. Present together for review: the exact SQL script, the dry-run output, and the rollback script.
5. **STOP.** Wait for explicit approval before any transaction is opened.

### Phase B — Execute (MCP-executed path)

> **Note:** This phase intentionally holds a transaction open while awaiting the user's commit/rollback decision. This is a deliberate tradeoff — it prioritizes human sign-off on live verification results over minimizing lock duration. Impact analysis and dry-run scale checks (Section 5) should already have flagged large/high-risk tables as maintenance-window items specifically to reduce how often this open-lock window matters in practice.

#### Pre-execution guardrail (mandatory, before `BEGIN TRANSACTION`)

Immediately before this screen is printed, the recovery snapshot check/create step (Section 4b) runs, so its result can be shown as part of the same confirmation:

```
==================================================================
 TARGET CONFIRMATION — REQUIRED BEFORE EXECUTION
------------------------------------------------------------------
 Server:            SQLPROD01.client.local
 Database:          ClientDB_Production
 Environment:        PRODUCTION
 Major table(s):     dbo.CUSTOMERS
 Minor table(s):     dbo.PARENT_LOOKUP (FK child)
                      dbo.CUSTOMER_SUMMARY_VW (view dependency)
                      dbo.sp_GetCustomerDuns (SP dependency)
 Recovery snapshot:   ClientDB_Production_snap_PLAN-2026-0142 (created 14:31:02, per Section 4b)
------------------------------------------------------------------
 Does this match the approved plan? Type CONFIRM to proceed.
==================================================================
```

- "Major table(s)" = the table(s) directly altered by the approved plan.
- "Minor table(s)" = every dependent object surfaced by the Dependency Discovery Procedure (Section 7) for the affected column(s) — FK-related tables (either direction), views, and SPs.
- This check exists specifically to catch wrong-environment execution (e.g. a staging-named connection that actually points at prod) — a common real-world cause of unintended production changes. It is not skippable and is separate from the Phase A approval itself.

Only after this confirmation:

1. `BEGIN TRANSACTION; SET XACT_ABORT ON;`
2. Execute the approved DDL/DML.
3. Run verification (see Section 4a) against the **uncommitted** transaction state.
4. Print a clear terminal summary of the execution and verification results (format below), and simultaneously write the same summary to a timestamped log file.
5. **STOP.** The transaction remains open. The user reviews the terminal output and explicitly issues one of:
   - `COMMIT` → agent sends `COMMIT TRANSACTION;`
   - `ROLLBACK` → agent sends `ROLLBACK TRANSACTION;`
6. The agent never decides commit/rollback on the user's behalf, even if verification appears to pass cleanly. **The user is solely responsible for the commit/rollback decision.**
7. Append the final outcome (`COMMITTED` or `ROLLED BACK`, with timestamp) to the same log file.

#### Terminal output format

```
==================================================================
 DUNS CLI — Execution Report
 Plan ID:        <plan-id>
 Table:          dbo.CUSTOMERS
 Operation:      Add new_DUNS + backfill from DUNS_NUM
 Started:        2025-01-15 14:32:07
==================================================================

[STEP] BEGIN TRANSACTION — OK

[STEP] Executing approved script...
  -> ALTER TABLE dbo.CUSTOMERS ADD new_DUNS VARCHAR(13) NULL;   OK
  -> UPDATE TOP (10000) dbo.CUSTOMERS SET new_DUNS = DUNS_NUM
     WHERE new_DUNS IS NULL;                                    OK (10,000 rows)

[STEP] Verification (uncommitted state)
  - Estimated rows (optimizer estimate, pre-execution):  ~800,000
  - Actual rows affected this batch:           10,000
  - Sample check (5 of 10,000 rows):
      CUST_ID=10231  DUNS_NUM=123456789     -> new_DUNS=123456789      OK
      CUST_ID=10245  DUNS_NUM=987654321     -> new_DUNS=987654321      OK
      ...
  - NULL/boundary check:                       0 unexpected NULLs
  - Schema metadata check:                     new_DUNS VARCHAR(13) NULL  [MATCHES APPROVED PLAN]

------------------------------------------------------------------
 TRANSACTION OPEN — AWAITING YOUR DECISION
 Type COMMIT to finalize, or ROLLBACK to undo this batch.
------------------------------------------------------------------
```

#### Log file

- Path: `.duns-cli/logs/<plan-id>_<YYYYMMDD_HHMMSS>.log`
- Contains the full terminal output above, plus the final `COMMITTED`/`ROLLED BACK` line with its own timestamp, appended once the user responds.
- For data migration batches (Section 3a), each batch also appends a checkpoint line, e.g.:
  `[BATCH 64] rows 630,001–640,000 — COMMITTED — checkpoint: last_key=640000, rows_completed=640,000/~812,000 (est.)`
- One log file per execution attempt — never overwritten or appended across separate runs, so the audit trail stays per-attempt.

### Phase B — Manual execution path

If the user takes the approved script away to run manually (Section 6), the agent is not present for commit/rollback and does not produce this terminal report — its responsibility ends at delivering the approved, correctly-formed script and rollback script.

## 4a. Verification (used in Phase B, MCP-executed path)

Verification runs *inside* the still-open transaction, so it reads the pending/uncommitted state — this is what allows it to catch problems before anything becomes permanent. It includes, as applicable to the change:

- **Row count check** — actual rows affected in this batch vs. the optimizer's estimated row count from the dry run (Section 5); this is a sanity comparison against an estimate, not an exact figure, so material order-of-magnitude mismatches are what matters, not small deltas.
- **Data spot-check** — a small sample (e.g. 5–20 rows) of before/after values shown directly, not just a pass/fail count.
- **NULL/boundary check** — unexpected NULLs, or values that still appear truncated/malformed after the change.
- **Constraint sanity check** — confirms no constraint was silently bypassed.
- **Schema metadata check** (DDL only) — re-queries `sys.columns` (or equivalent) inside the transaction to confirm the live definition now matches what was approved in Phase A.

All verification output is included in the terminal report and log file before the commit/rollback prompt is shown — the user's decision is meant to be made with this evidence in front of them, not blind.

## 4b. Pre-Execution Recovery Snapshot

Before executing an approved migration plan, a database-level recovery point is created automatically — but only within the boundaries of what was already approved in Phase A, and only if one doesn't already exist for that plan.

- **Included in what's approved, not a separate silent action.** The Phase A plan presented for review explicitly states that a snapshot will be taken before execution. Approving the plan approves this step along with it — it is not something the tool does independently outside the approval it already has.
- **Check-before-create.** Immediately before Phase B begins, check whether a valid snapshot already exists for this `plan_id`. If one does, reuse it and log its name rather than creating a duplicate. Only create a new one if none exists yet.
- **Mechanism — native database snapshot**, since it's fast and cheap (copy-on-write, near-instant creation, grows only as data changes afterward):

```sql
CREATE DATABASE <db>_snap_<plan_id>
ON (NAME = <db>, FILENAME = 'D:\Snapshots\<db>_snap_<plan_id>.ss')
AS SNAPSHOT OF <db>;
```

- **Log the snapshot name and creation timestamp** into the plan record and log file, so the revert path (`RESTORE DATABASE <db> FROM DATABASE_SNAPSHOT = '<snapshot_name>'`) always references a specific, known recovery point rather than "whatever the last one was."
- **Known limitation, stated plainly rather than silently assumed away:** a database snapshot lives on the same instance/disk as the live database — it protects against a bad migration, not against disk/instance failure. It is the default recovery point for this framework's revert needs, not a substitute for the client's own off-box backup strategy.
- **Edition/feature availability isn't assumed.** If native database snapshots aren't supported on the target SQL Server edition, the tool must flag this explicitly during Phase A rather than silently skipping the recovery-point step — at minimum, confirming a recent full backup exists becomes a manual prerequisite called out in the plan.

---

## 5. Dry Run

- Before Phase A approval, generate a read-only preview using the **same predicate/logic** as the real write (same `WHERE`/`JOIN` conditions), limited to **`TOP 50` rows**.
- Purpose: sanity-check that the predicate is matching the right kind of rows — not a full blast-radius count. `TOP 50` will not reveal whether the true match set is 5,000 or 5,000,000 rows.
- **The dry-run query is AI-generated**, mechanically derived from the same predicate as the approved DML/DDL script (not hand-authored separately). Because it is generated code, it must be shown to the user and reviewed alongside the main script during Phase A — it is not exempt from review just because it's read-only, since a derivation error here could either mask or duplicate a bug in the real script.
- **Scale estimate — default is metadata-only, not a full scan:**
  - Default: get the SQL Server query optimizer's **estimated row count** for the real predicate (e.g. via `SET SHOWPLAN_XML ON` / `STATISTICS XML` without execution), which uses existing statistics and touches no data pages. Near-zero cost.
  - Optional, coarse fallback: total table row count via `sys.dm_db_partition_stats` (metadata-only, instant) — gives table size, not predicate-matched count, but useful context.
  - **True `COUNT_BIG(*)` with the real predicate is not run by default.** It performs a real scan/seek and can approach the cost of the write itself on large or poorly-indexed tables. It's available only as an explicit opt-in, flagged during impact analysis for cases where precision matters more than speed (e.g. small tables, or tables with a strong supporting index on the predicate).
- Runs outside any transaction — ordinary read locks only, no blocking of other sessions.

---

## 6. Execution Path Is Not Fixed to the Tool/MCP

The agent does not assume it is the one executing the approved script. Two valid paths exist:

- **Tool/MCP-executed:** the agent runs Phase B itself, following Section 4 exactly, including automated verification and logging.
- **Manually executed:** the user takes the approved script (with its rollback script) and runs it themselves via SSMS, another GUI, or another client.

**What must hold true regardless of execution path** (script-level requirements):
- Explicitly transaction-wrapped with `XACT_ABORT ON`
- Batched per Section 3
- Accompanied by a tested/reviewed rollback script
- Preceded by the dry run and impact analysis, both already presented and approved

**What only applies when the agent itself executes** (Phase B specifics):
- The `BEGIN → execute → verify → report → await user COMMIT/ROLLBACK` sequence
- Producing the terminal report and timestamped log file
- Sending the literal `COMMIT`/`ROLLBACK` statement — but only on the user's explicit instruction, never decided autonomously

If the user chooses manual execution, the agent's responsibility ends at delivering a correctly-formed, approved script — it should state this explicitly rather than assume it will also run or verify the change.

---

## 7. Dependency Discovery Procedure

For any table involved in a DUNS-related change (most commonly: adding a `new_DUNS` column and migrating data from the original DUNS column), run this fixed checklist during impact analysis, before any change is proposed for approval. This is a repeatable procedure applied per table, not custom-written per request.

1. **Indexes** on the column, including columns used only as `INCLUDE` (non-key) columns.
2. **Foreign keys**, checked in both directions — where the column is the referencing (child) column, and where it is the referenced (parent) column.
3. **Default constraints and check constraints** referencing the column (check constraint bodies require a text match against `sys.check_constraints.definition`, since they aren't linked to columns directly in metadata).
4. **Computed columns** whose definition references the column.
5. **Views, stored procedures, functions, and triggers** with a structural dependency on the column, via `sys.sql_expression_dependencies`. Where `referenced_minor_name` is unresolved (common with `SELECT *`), flag as "possible dependency — unresolved" for manual review rather than clearing it.
6. **Triggers**, checked explicitly against `sys.triggers`/`sys.sql_modules`, since trigger logic isn't always fully surfaced by the dependency view above.
7. **Dynamic SQL blind spot** — run a text-search fallback across all module definitions (`sys.sql_modules.definition LIKE '%COLUMN_NAME%'`) to catch references inside `EXEC(@sql)` / `sp_executesql` calls that static dependency views cannot see. Treat matches as "needs manual review — possible dynamic SQL reference," not as automatically safe or unsafe.
8. **Synonyms, replication, and Change Data Capture (CDC)** — check for synonyms pointing at the table, and whether the table is under CDC or transactional replication, since either changes what a column addition/migration requires downstream.

All eight checks are logged into the impact analysis report for that table, before the change is eligible for Phase A approval.

---

## 8. Stored Procedure Updates

- Run the Dependency Discovery Procedure (Section 7) against any SP flagged as referencing the affected table/column, and list potential breaking changes explicitly.
- An offer to test-execute an SP after commit only applies to **read-only/validation SPs**. Any SP with write potential must go through the same Phase A/B approval flow as any other write — it is never auto-executed as a "quick post-commit check."

---

## 9. DDL-Specific Constraint

- Explicitly warn about **Schema Modification (Sch-M) locks** before proposing any `ALTER TABLE`, since this blocks all readers and writers on the table for the duration of the change.
- For tables above a size/row-count threshold (to be set in config), flag the change as requiring a maintenance window rather than a live-hours change.

## 10. Rollback Script — Scope Note

A rollback script (Section 4, Phase A) is a **post-commit corrective action**, not the same mechanism as `ROLLBACK TRANSACTION`. It applies to any approved write — DDL or DML — but its risk and complexity are not uniform across the migration lifecycle (see `03_DUNS_MIGRATION_LIFECYCLE.md`):

- Early-stage changes (adding a new column, migrating data into it) are cheap to reverse by design, since the original column is never touched — reverting typically means clearing or dropping only the new column.
- Later-stage changes carry progressively more risk to reverse cleanly, since more of the system may already depend on the change. Detailed guidance for those later stages is deferred until they're actually being planned.

## 11. Workspace & File Layout

```
.duns-cli/
├── config/
│   └── duns-cli.config.yaml
│
├── schema-cache/
│   └── schema-snapshot_<YYYYMMDD_HHMMSS>.json     # persisted, human-readable schema copy (Section 1)
│
├── plans/
│   └── <plan-id>.json                              # Phase A approved plan record
│
├── rollback/
│   └── <plan-id>_rollback.sql                      # reviewed alongside the plan in Phase A
│
├── checkpoints/
│   └── <plan-id>_<table>.json                      # local mirror of DB checkpoint + failures (Section 3a)
│
├── logs/
│   └── <plan-id>_<YYYYMMDD_HHMMSS>.log              # per-execution terminal report, timestamped (Section 4)
│
└── audit/
    └── audit.log                                    # append-only: every read/plan/approve/apply
```

Database-side (tool-owned schema, separate from client business tables):

```
duns_cli.migration_checkpoint     -- source of truth for in-progress data migrations (Section 3a)
```
