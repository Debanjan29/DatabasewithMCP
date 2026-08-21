/* ==================================================================
   DUNS CLI — Dry Run (Section 5)
   Plan ID:  PLAN-EXAMPLE-0001
   Table:    dbo.CUSTOMERS
   Column:   DUNS_NUM (numeric(9)) -> new_DUNS (char(9), zero-padded)

   Read-only. No transaction. Ordinary read locks only.
   Uses the SAME predicate as the real migration script.
   ================================================================== */

-- 1. Row preview (TOP 50) — sanity-checks predicate is matching the
--    right KIND of rows, not blast radius.
SELECT TOP 50
    CUST_ID,
    DUNS_NUM,
    RIGHT('000000000' + CAST(DUNS_NUM AS VARCHAR(9)), 9) AS new_DUNS_preview
FROM dbo.CUSTOMERS
WHERE DUNS_NUM IS NOT NULL;

-- 2. Scale estimate — optimizer estimate only, no full scan (default per Section 5)
SET SHOWPLAN_XML ON;
GO
SELECT CUST_ID, DUNS_NUM
FROM dbo.CUSTOMERS
WHERE DUNS_NUM IS NOT NULL;
GO
SET SHOWPLAN_XML OFF;
GO
-- Read EstimateRows from the returned XML plan for the SELECT above.

-- 3. Coarse fallback — total table row count via metadata (instant, no scan)
SELECT
    OBJECT_SCHEMA_NAME(p.object_id) AS schema_name,
    OBJECT_NAME(p.object_id)        AS table_name,
    SUM(p.rows)                     AS total_row_count_metadata
FROM sys.partitions p
WHERE p.object_id = OBJECT_ID('dbo.CUSTOMERS')
  AND p.index_id IN (0,1)
GROUP BY p.object_id;

/* NOTE: True COUNT_BIG(*) against the real predicate is NOT run here
   by default (Section 5) — it's a real scan and can approach the cost
   of the write itself. Only run it as an explicit opt-in if this table
   is small or has a strong index on DUNS_NUM. */
