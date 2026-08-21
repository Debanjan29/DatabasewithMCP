/* ==================================================================
   DUNS CLI — Rollback Script (post-commit corrective action)
   Plan ID:  PLAN-EXAMPLE-0001
   Table:    dbo.CUSTOMERS

   Per Section 10: this is NOT the same mechanism as ROLLBACK
   TRANSACTION. It reverses an already-COMMITTED change.

   Per Section 10, early-stage note: this is the CHEAP case —
   the original column (DUNS_NUM) was never touched, so reverting
   means only clearing/dropping the new column. No data was ever
   at risk on the original attribute.
   ================================================================== */

-- ------------------------------------------------------------------
-- OPTION A: Soft revert — clear migrated data, keep column
--           (use if you may want to re-run migration shortly after)
-- ------------------------------------------------------------------
SET XACT_ABORT ON;
BEGIN TRANSACTION Rollback_ClearData_PLAN_EXAMPLE_0001;

    UPDATE dbo.CUSTOMERS
    SET new_DUNS = NULL
    WHERE new_DUNS IS NOT NULL;

    -- Also clear the checkpoint so a future re-run starts clean
    UPDATE duns_cli.migration_checkpoint
    SET status = 'failed',
        last_processed_key = NULL,
        rows_completed = 0,
        last_updated_at = SYSUTCDATETIME()
    WHERE plan_id = 'PLAN-EXAMPLE-0001'
      AND table_name = 'dbo.CUSTOMERS';

-- STOP: awaiting explicit COMMIT/ROLLBACK per Section 4, same as
-- any other write.


-- ------------------------------------------------------------------
-- OPTION B: Full revert — drop the new column entirely
--           (use if abandoning this migration attempt)
-- ------------------------------------------------------------------
SET XACT_ABORT ON;
BEGIN TRANSACTION Rollback_DropColumn_PLAN_EXAMPLE_0001;

    -- Pre-check per CLI instructions Section 5: confirm no dependency
    -- was created against new_DUNS since it was added (index, default,
    -- check constraint, computed column, SP/view reference). Re-run
    -- the Section 7 dependency discovery queries against new_DUNS
    -- before this DROP — do not assume it's still unreferenced.

    ALTER TABLE dbo.CUSTOMERS
        DROP COLUMN new_DUNS;

    DELETE FROM duns_cli.migration_checkpoint
    WHERE plan_id = 'PLAN-EXAMPLE-0001'
      AND table_name = 'dbo.CUSTOMERS';

-- STOP: awaiting explicit COMMIT/ROLLBACK.

/* ==================================================================
   Choose ONE option at execution time — do not run both.
   Per CLI instructions Section 5: where a staging environment exists,
   this rollback should be round-trip tested there (forward plan ->
   rollback -> confirm original state restored) before ever being
   relied on against production.
   ================================================================== */
