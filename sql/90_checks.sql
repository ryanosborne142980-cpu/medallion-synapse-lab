-- Data checks. Run against lab after any layer change:
--   python scripts/run_sql.py sql/90_checks.sql
-- Checks live as views in the qa schema (query them any time, e.g. SELECT * FROM qa.checks).
-- This file (re)creates them, prints the results, and THROWs if any check is FAIL so scripts
-- and /verify get a non-zero exit. Expected counts come from each _manifest.json in the lake.
-- Serverless can't load lake data into temp tables, hence views instead of #tables.
--
-- Layers of checks, kept separate so they never mix:
--   ingestion  source -> lake -> bronze: counts vs manifest, keys, snapshot consistency.
--              Bronze is views over landing files, so these test what landed, untransformed.
--   silver     (later) transformation checks: quarantine reconciliation, conformed values.
-- Add a layer as its own qa.<layer>_checks view and include it in qa.checks.

IF SCHEMA_ID(N'qa') IS NULL EXEC (N'CREATE SCHEMA qa');
GO

-- Snapshot manifests: 0x0b as row terminator reads each whole JSON file as one row.
-- record_count = FEMA's count when the download started; record_count_end = when it finished
-- (manifests written before 2026-11-16 evening lack it, so it is NULL there).
CREATE OR ALTER VIEW qa.manifest AS
SELECT
    CAST(m.filepath(1) AS varchar(40))                      AS dataset,
    CAST(m.filepath(2) AS varchar(10))                      AS ingest_date,
    CAST(JSON_VALUE(m.doc, '$.record_count') AS bigint)     AS record_count,
    CAST(JSON_VALUE(m.doc, '$.record_count_end') AS bigint) AS record_count_end,
    CAST(JSON_VALUE(m.doc, '$.rejected_count') AS bigint)   AS rejected_count
FROM OPENROWSET(
    BULK 'landing/*/ingest_date=*/_manifest.json',
    DATA_SOURCE = 'lake',
    FORMAT = 'CSV',
    FIELDTERMINATOR = '0x0b',
    FIELDQUOTE = '0x0b',
    ROWTERMINATOR = '0x0b'
) WITH (doc varchar(max)) AS m;
GO

-- ===== Ingestion: reconciliation, keys, snapshot consistency =====
CREATE OR ALTER VIEW qa.ingestion_checks AS
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
),
-- One FEMA data date (asOfDate) per snapshot. Two values mean FEMA refreshed its data while
-- the download ran (e.g. an interrupted run resumed later), so the snapshot mixes versions
-- and offset paging may have skipped or repeated records. Fix: delete it and re-download.
as_of AS (
    SELECT 'nfip_claims' AS dataset, ingest_date, COUNT_BIG(DISTINCT asOfDate) AS versions
    FROM bronze.nfip_claims GROUP BY ingest_date
),
-- Natural key: id is a random GUID, so also prove one row per disaster x state x place.
-- (disaster x county is NOT unique: several areas can share a county, e.g. tribal areas.)
natural_keys AS (
    SELECT 'disaster_declarations' AS dataset, ingest_date,
           COUNT_BIG(*) - COUNT_BIG(DISTINCT CONCAT(disasterNumber, '|', fipsStateCode, '|', placeCode)) AS dupes
    FROM bronze.disaster_declarations GROUP BY ingest_date
)
-- Source -> target: rows landed per snapshot = FEMA's count (nothing quarantined at ingestion).
SELECT 'ingestion' AS layer, 'row_count = manifest' AS check_name, m.dataset, m.ingest_date,
       m.record_count AS expected, ISNULL(c.n, 0) AS actual
FROM qa.manifest AS m LEFT JOIN counts AS c ON c.dataset = m.dataset AND c.ingest_date = m.ingest_date
UNION ALL
-- FEMA's count didn't change while the download paged through it. Only manifests that
-- recorded record_count_end are checked; older ones are covered by the asOfDate check.
SELECT 'ingestion', 'FEMA count unchanged during download', m.dataset, m.ingest_date,
       m.record_count, m.record_count_end
FROM qa.manifest AS m
WHERE m.record_count_end IS NOT NULL
UNION ALL
-- Records recovered from _rejected/ JSONL = manifest rejected_count.
SELECT 'ingestion', 'recovered jsonl rows = manifest', m.dataset, m.ingest_date,
       m.rejected_count, ISNULL(c.recovered, 0)
FROM qa.manifest AS m LEFT JOIN counts AS c ON c.dataset = m.dataset AND c.ingest_date = m.ingest_date
UNION ALL
-- id unique within each snapshot.
SELECT 'ingestion', 'duplicate ids per snapshot', c.dataset, c.ingest_date, 0, c.dupes
FROM counts AS c
UNION ALL
SELECT 'ingestion', 'duplicate natural keys per snapshot', k.dataset, k.ingest_date, 0, k.dupes
FROM natural_keys AS k
UNION ALL
SELECT 'ingestion', 'one FEMA asOfDate per snapshot', a.dataset, a.ingest_date, 1, a.versions
FROM as_of AS a;
GO

-- ===== Ingestion: possible string truncation in bronze =====
-- A column whose longest value fills its declared length may be truncated (declared lengths
-- have ~2x headroom). Fix by widening it in sql/10_bronze.sql. Generated from the catalog so
-- new columns are covered automatically; expected = declared bytes, actual = longest value.
DECLARE @body nvarchar(max);
SELECT @body = STRING_AGG(CAST(
    'SELECT ''ingestion'' AS layer, ''string under declared length'' AS check_name, '''
    + v.name + '.' + c.name + ''' AS dataset, CAST(NULL AS varchar(10)) AS ingest_date, CAST('
    + CAST(c.max_length AS varchar(10)) + ' AS bigint) AS expected, CAST(ISNULL(MAX(DATALENGTH(['
    + c.name + '])), 0) AS bigint) AS actual FROM bronze.[' + v.name + ']' AS nvarchar(max)), N' UNION ALL ')
FROM sys.views AS v
JOIN sys.columns AS c ON c.object_id = v.object_id
WHERE SCHEMA_NAME(v.schema_id) = 'bronze'
  AND TYPE_NAME(c.system_type_id) = 'varchar'
  AND c.max_length > 0
  AND c.name NOT IN ('ingest_date', 'source_file', 'source_format');
DECLARE @ddl nvarchar(max) = N'CREATE OR ALTER VIEW qa.ingestion_string_lengths AS ' + @body;
EXEC sp_executesql @ddl;
GO

-- ===== All checks =====
CREATE OR ALTER VIEW qa.checks AS
SELECT layer, check_name, dataset, ingest_date, expected, actual,
       CAST(CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END AS varchar(4)) AS status
FROM qa.ingestion_checks
UNION ALL
SELECT layer, check_name, dataset, ingest_date, expected, actual,
       CAST(CASE WHEN actual < expected THEN 'PASS' ELSE 'FAIL' END AS varchar(4))
FROM qa.ingestion_string_lengths;
GO

-- One-time cleanup of the pre-2026-11-16 names (renamed from bronze_* to ingestion_*).
IF OBJECT_ID(N'qa.bronze_checks') IS NOT NULL DROP VIEW qa.bronze_checks;
IF OBJECT_ID(N'qa.bronze_string_lengths') IS NOT NULL DROP VIEW qa.bronze_string_lengths;
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
