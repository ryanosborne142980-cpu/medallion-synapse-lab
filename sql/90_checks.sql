-- Data checks. Run against lab after any layer change:
--   python scripts/run_sql.py sql/90_checks.sql
-- Checks live as views in the qa schema (query them any time, e.g. SELECT * FROM qa.checks).
-- This file (re)creates them, prints the results, and THROWs if any check is FAIL so scripts
-- and /verify get a non-zero exit. Expected counts come from each _manifest.json in the lake.
-- Serverless can't load lake data into temp tables, hence views instead of #tables.
-- Add silver/gold checks as new views and include them in qa.checks.

IF SCHEMA_ID(N'qa') IS NULL EXEC (N'CREATE SCHEMA qa');
GO

-- Snapshot manifests: 0x0b as row terminator reads each whole JSON file as one row.
CREATE OR ALTER VIEW qa.manifest AS
SELECT
    CAST(m.filepath(1) AS varchar(40))                    AS dataset,
    CAST(m.filepath(2) AS varchar(10))                    AS ingest_date,
    CAST(JSON_VALUE(m.doc, '$.record_count') AS bigint)   AS record_count,
    CAST(JSON_VALUE(m.doc, '$.rejected_count') AS bigint) AS rejected_count
FROM OPENROWSET(
    BULK 'landing/*/ingest_date=*/_manifest.json',
    DATA_SOURCE = 'lake',
    FORMAT = 'CSV',
    FIELDTERMINATOR = '0x0b',
    FIELDQUOTE = '0x0b',
    ROWTERMINATOR = '0x0b'
) WITH (doc varchar(max)) AS m;
GO

-- ===== Bronze: reconciliation and keys =====
CREATE OR ALTER VIEW qa.bronze_checks AS
WITH counts AS (
    SELECT 'nfip_claims' AS dataset, ingest_date,
           COUNT_BIG(*) AS n,
           COUNT_BIG(*) - COUNT_BIG(DISTINCT id) AS dupes,
           SUM(CASE WHEN source_format = 'jsonl_rejected' THEN 1 ELSE 0 END) AS recovered
    FROM bronze.nfip_claims GROUP BY ingest_date
    UNION ALL
    SELECT 'disaster_declarations', ingest_date,
           COUNT_BIG(*), COUNT_BIG(*) - COUNT_BIG(DISTINCT id), 0
    FROM bronze.disaster_declarations GROUP BY ingest_date
)
-- Bronze rows per snapshot = manifest record_count (nothing quarantined in bronze).
SELECT 'bronze' AS layer, 'row_count = manifest' AS check_name, m.dataset, m.ingest_date,
       m.record_count AS expected, ISNULL(c.n, 0) AS actual
FROM qa.manifest AS m LEFT JOIN counts AS c ON c.dataset = m.dataset AND c.ingest_date = m.ingest_date
UNION ALL
-- Records recovered from _rejected/ JSONL = manifest rejected_count.
SELECT 'bronze', 'recovered jsonl rows = manifest', m.dataset, m.ingest_date,
       m.rejected_count, ISNULL(c.recovered, 0)
FROM qa.manifest AS m LEFT JOIN counts AS c ON c.dataset = m.dataset AND c.ingest_date = m.ingest_date
UNION ALL
-- id unique within each snapshot.
SELECT 'bronze', 'duplicate ids per snapshot', c.dataset, c.ingest_date, 0, c.dupes
FROM counts AS c;
GO

-- ===== Bronze: possible string truncation =====
-- A column whose longest value fills its declared length may be truncated (declared lengths
-- have ~2x headroom). Fix by widening it in sql/10_bronze.sql. Generated from the catalog so
-- new columns are covered automatically; expected = declared bytes, actual = longest value.
DECLARE @body nvarchar(max);
SELECT @body = STRING_AGG(CAST(
    'SELECT ''bronze'' AS layer, ''string under declared length'' AS check_name, '''
    + v.name + '.' + c.name + ''' AS dataset, CAST(NULL AS varchar(10)) AS ingest_date, CAST('
    + CAST(c.max_length AS varchar(10)) + ' AS bigint) AS expected, CAST(ISNULL(MAX(DATALENGTH(['
    + c.name + '])), 0) AS bigint) AS actual FROM bronze.[' + v.name + ']' AS nvarchar(max)), N' UNION ALL ')
FROM sys.views AS v
JOIN sys.columns AS c ON c.object_id = v.object_id
WHERE SCHEMA_NAME(v.schema_id) = 'bronze'
  AND TYPE_NAME(c.system_type_id) = 'varchar'
  AND c.max_length > 0
  AND c.name NOT IN ('ingest_date', 'source_file', 'source_format');
DECLARE @ddl nvarchar(max) = N'CREATE OR ALTER VIEW qa.bronze_string_lengths AS ' + @body;
EXEC sp_executesql @ddl;
GO

-- ===== All checks =====
CREATE OR ALTER VIEW qa.checks AS
SELECT layer, check_name, dataset, ingest_date, expected, actual,
       CAST(CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END AS varchar(4)) AS status
FROM qa.bronze_checks
UNION ALL
SELECT layer, check_name, dataset, ingest_date, expected, actual,
       CAST(CASE WHEN actual < expected THEN 'PASS' ELSE 'FAIL' END AS varchar(4))
FROM qa.bronze_string_lengths;
GO

-- ===== Results =====
-- Passing string-length rows are hidden to keep the output short.
SELECT layer, check_name, dataset, ingest_date, expected, actual, status
FROM qa.checks
WHERE status = 'FAIL' OR check_name <> 'string under declared length'
ORDER BY CASE status WHEN 'FAIL' THEN 0 ELSE 1 END, layer, check_name, dataset;
GO

DECLARE @total int, @failed int;
SELECT @total = COUNT(*), @failed = SUM(CASE WHEN status = 'FAIL' THEN 1 ELSE 0 END) FROM qa.checks;
SELECT @total AS checks, @failed AS failed;
IF @failed > 0
    THROW 50000, 'Data checks FAILED; see rows with status FAIL above.', 1;
GO
