/* ==================================================================
   DUNS CLI — Forward Plan (Phase A — FOR REVIEW ONLY, NOT EXECUTED)
   Plan ID:  PLAN-EXAMPLE-0001
   Table:    dbo.CUSTOMERS
   Stage:    1 (Add column) + 2 (Data migration)
   Operation: Add new_DUNS CHAR(9), backfill zero-padded from DUNS_NUM

   Discloses upfront (per Section 5, CLI instructions):
   - Batched migration is RESUMABLE/IDEMPOTENT, not an instant single
     atomic reversal. See PLAN-EXAMPLE-0001_rollback.sql for the
     corrective action, which is a post-commit action, not a live undo.
   - This requires the migration_checkpoint table to already exist
     (created once via its own separate approved plan — Section 3a).
     If it does not exist yet, that setup plan must be approved first.
   ================================================================== */

-- ------------------------------------------------------------------
-- STAGE 1: Add new column (single-statement DDL, no checkpoint needed)
-- ------------------------------------------------------------------
SET XACT_ABORT ON;
BEGIN TRANSACTION AddColumn_PLAN_EXAMPLE_0001;

    ALTER TABLE dbo.CUSTOMERS
        ADD new_DUNS CHAR(9) NULL;

    -- Schema metadata verification happens in Phase B (Section 4a),
    -- against the live sys.columns, inside this open transaction.

-- STOP: transaction remains open pending explicit COMMIT/ROLLBACK
-- from the user during Phase B execution. Not auto-committed here.


-- ------------------------------------------------------------------
-- STAGE 2: Data migration — batched, idempotent, checkpointed
-- Batch size: 10,000 rows (Section 3 default max)
-- ------------------------------------------------------------------

/* Idempotency note (Section 3a): the predicate below only ever
   touches rows where new_DUNS IS STILL NULL. Re-running this batch
   loop from the start (a "Restart") can never double-apply, which
   is what makes Restart a safe option on resume. */

DECLARE @PlanId       VARCHAR(50) = 'PLAN-EXAMPLE-0001';
DECLARE @TableName    SYSNAME     = 'dbo.CUSTOMERS';
DECLARE @BatchSize    INT         = 10000;
DECLARE @RowsAffected INT         = 1;
DECLARE @LastKey      BIGINT;
DECLARE @RowsDone     BIGINT;

-- On resume: load from checkpoint table instead of starting at 0.
-- (Presented as an explicit Resume/Restart/Abort choice in Phase B,
--  per Section 3a — not inferred automatically here.)
SELECT
    @LastKey  = ISNULL(last_processed_key, 0),
    @RowsDone = ISNULL(rows_completed, 0)
FROM duns_cli.migration_checkpoint
WHERE plan_id = @PlanId AND table_name = @TableName;

IF @LastKey IS NULL
BEGIN
    SET @LastKey = 0;
    SET @RowsDone = 0;
END

WHILE @RowsAffected > 0
BEGIN
    SET XACT_ABORT ON;
    BEGIN TRANSACTION MigrateBatch_PLAN_EXAMPLE_0001;

        ;WITH NextBatch AS (
            SELECT TOP (@BatchSize)
                CUST_ID,
                DUNS_NUM
            FROM dbo.CUSTOMERS
            WHERE new_DUNS IS NULL          -- idempotent predicate
              AND DUNS_NUM IS NOT NULL
              AND CUST_ID > @LastKey
            ORDER BY CUST_ID
        )
        UPDATE c
        SET c.new_DUNS = RIGHT('000000000' + CAST(nb.DUNS_NUM AS VARCHAR(9)), 9)
        OUTPUT inserted.CUST_ID INTO #BatchKeys(CUST_ID)  -- capture for checkpoint
        FROM dbo.CUSTOMERS c
        JOIN NextBatch nb ON nb.CUST_ID = c.CUST_ID;

        SET @RowsAffected = @@ROWCOUNT;

        IF @RowsAffected > 0
        BEGIN
            SELECT @LastKey = MAX(CUST_ID) FROM #BatchKeys;
            SET @RowsDone = @RowsDone + @RowsAffected;

            -- Checkpoint update happens IN THE SAME TRANSACTION as the
            -- data write (Section 3a) — commits/rolls back together.
            MERGE duns_cli.migration_checkpoint AS tgt
            USING (SELECT @PlanId AS plan_id, @TableName AS table_name) AS src
                ON tgt.plan_id = src.plan_id AND tgt.table_name = src.table_name
            WHEN MATCHED THEN UPDATE SET
                last_processed_key = @LastKey,
                rows_completed     = @RowsDone,
                status             = 'in_progress',
                last_updated_at    = SYSUTCDATETIME()
            WHEN NOT MATCHED THEN INSERT
                (plan_id, table_name, phase, last_processed_key, rows_completed, status)
            VALUES
                (@PlanId, @TableName, 'data_migration', @LastKey, @RowsDone, 'in_progress');
        END

        DELETE FROM #BatchKeys;

    -- STOP per batch: in the MCP-executed path (Phase B, Section 4),
    -- each batch's commit is a manual, explicit human decision after
    -- reviewing that batch's terminal report — NOT auto-looped in
    -- production. This WHILE loop illustrates the batch logic; the
    -- actual Phase B execution pauses here every iteration.
    COMMIT TRANSACTION MigrateBatch_PLAN_EXAMPLE_0001;
    -- (Shown as COMMIT here for completeness of the script; Phase B
    --  substitutes the manual COMMIT/ROLLBACK prompt at this point.)
END

-- Mark checkpoint completed once no more unmigrated rows remain
UPDATE duns_cli.migration_checkpoint
SET status = 'completed', last_updated_at = SYSUTCDATETIME()
WHERE plan_id = @PlanId AND table_name = @TableName;

/* ==================================================================
   End of forward plan. Presented alongside:
     - PLAN-EXAMPLE-0001_dryrun.sql
     - PLAN-EXAMPLE-0001_rollback.sql
   per Section 4, Phase A. Awaiting review and explicit approval.
   ================================================================== */
