/* ==================================================================
   DUNS CLI — Verification Script (Section 4a)
   Plan ID:  PLAN-EXAMPLE-0001
   Table:    dbo.CUSTOMERS
   Column:   DUNS_NUM (numeric(9)) -> new_DUNS (char(9), zero-padded)

   MANUAL EXECUTION PATH (Section 6):
   Run this AFTER executing the approved forward script's DDL/batch,
   but BEFORE you decide COMMIT or ROLLBACK. It reads the pending,
   UNCOMMITTED state inside the same open transaction/session —
   run it in the same SSMS query window/session as the write, not
   a new connection, or you will not see uncommitted rows.

   This does not decide COMMIT/ROLLBACK for you. It only produces
   the evidence. Per Section 4, point 6: the user is solely
   responsible for that decision.
   ================================================================== */

-- ------------------------------------------------------------------
-- 1. ROW COUNT CHECK
--    Compare actual rows affected this batch vs. the dry-run's
--    optimizer estimate (Section 5). This is a sanity comparison
--    against an ESTIMATE — order-of-magnitude mismatches matter,
--    small deltas do not.
-- ------------------------------------------------------------------
SELECT
    COUNT(*) AS rows_with_new_DUNS_populated_so_far
FROM dbo.CUSTOMERS
WHERE new_DUNS IS NOT NULL;

-- Compare this figure against:
--   (a) the checkpoint's rows_completed for this plan/table, and
--   (b) the dry run's optimizer EstimateRows (PLAN-EXAMPLE-0001_dryrun.sql)


-- ------------------------------------------------------------------
-- 2. DATA SPOT-CHECK
--    Small before/after sample shown directly, not just pass/fail.
--    Adjust TOP (n) between 5 and 20 as needed.
-- ------------------------------------------------------------------
SELECT TOP 20
    CUST_ID,
    DUNS_NUM                                        AS old_value,
    new_DUNS                                         AS new_value,
    LEN(new_DUNS)                                    AS new_value_length,
    CASE
        WHEN new_DUNS = RIGHT('000000000' + CAST(DUNS_NUM AS VARCHAR(9)), 9)
        THEN 'OK'
        ELSE 'MISMATCH'
    END                                               AS spot_check_result
FROM dbo.CUSTOMERS
WHERE new_DUNS IS NOT NULL
ORDER BY NEWID();   -- random sample; swap for ORDER BY CUST_ID for a deterministic sample


-- ------------------------------------------------------------------
-- 3. NULL / BOUNDARY CHECK
--    Unexpected NULLs, or values still truncated/malformed
--    after the change.
-- ------------------------------------------------------------------

-- 3a. Rows where source had a value but target is still NULL
--     (should be 0 once migration for this batch/table is complete)
SELECT COUNT(*) AS unexpected_nulls_target
FROM dbo.CUSTOMERS
WHERE DUNS_NUM IS NOT NULL
  AND new_DUNS IS NULL;

-- 3b. Rows where new_DUNS is populated but NOT exactly 9 characters
--     (would indicate a padding/truncation bug)
SELECT COUNT(*) AS malformed_length_rows
FROM dbo.CUSTOMERS
WHERE new_DUNS IS NOT NULL
  AND LEN(new_DUNS) <> 9;

-- 3c. Rows where new_DUNS contains non-numeric characters
--     (sanity check that padding didn't introduce junk)
SELECT COUNT(*) AS non_numeric_rows
FROM dbo.CUSTOMERS
WHERE new_DUNS IS NOT NULL
  AND new_DUNS LIKE '%[^0-9]%';


-- ------------------------------------------------------------------
-- 4. CONSTRAINT SANITY CHECK
--    Confirms no constraint was silently bypassed.
-- ------------------------------------------------------------------

-- 4a. Any check constraints on the table currently NOT TRUSTED
--     (would mean SQL Server can't guarantee they hold for existing data)
SELECT
    cc.name                             AS check_constraint_name,
    cc.definition,
    cc.is_not_trusted
FROM sys.check_constraints cc
WHERE cc.parent_object_id = OBJECT_ID('dbo.CUSTOMERS')
  AND cc.is_not_trusted = 1;

-- 4b. Any foreign keys currently NOT TRUSTED
SELECT
    fk.name                             AS fk_name,
    fk.is_not_trusted
FROM sys.foreign_keys fk
WHERE fk.parent_object_id = OBJECT_ID('dbo.CUSTOMERS')
  AND fk.is_not_trusted = 1;


-- ------------------------------------------------------------------
-- 5. SCHEMA METADATA CHECK (DDL only)
--    Re-queries sys.columns inside the open transaction to confirm
--    the live definition matches what was approved in Phase A.
-- ------------------------------------------------------------------
SELECT
    c.name                              AS column_name,
    ty.name                             AS data_type,
    c.max_length,
    c.is_nullable,
    c.column_id
FROM sys.columns c
JOIN sys.types ty
    ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.CUSTOMERS')
  AND c.name = 'new_DUNS';

-- EXPECTED (per approved plan): data_type = char, max_length = 9, is_nullable = 1


/* ==================================================================
   Once all five sections above have been reviewed:
     - If results look correct: issue COMMIT TRANSACTION yourself.
     - If anything looks wrong: issue ROLLBACK TRANSACTION yourself.
   This script does not do either for you.
   ================================================================== */
