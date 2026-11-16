-- Schemas, lake data source, and file format for the lab database. Run against lab:
--   python scripts/run_sql.py sql/01_setup.sql
-- Re-runnable: every object is created only if missing.
--
-- No credential on the data source: serverless SQL then passes through the caller's Entra
-- identity, so access is governed by Storage Blob Data Contributor on the account
-- (granted by infra/main.bicep). No keys, no SAS (Core Principles).
-- To change the data source or file format later, drop the external tables that use it first.

-- One schema per medallion layer.
IF SCHEMA_ID(N'bronze') IS NULL EXEC (N'CREATE SCHEMA bronze');
GO
IF SCHEMA_ID(N'silver') IS NULL EXEC (N'CREATE SCHEMA silver');
GO
IF SCHEMA_ID(N'gold') IS NULL EXEC (N'CREATE SCHEMA gold');
GO

-- Root of the lake container; queries use paths relative to it, e.g. 'landing/nfip_claims/...'.
-- Fabric equivalent: a OneLake shortcut to this container.
IF NOT EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = N'lake')
    CREATE EXTERNAL DATA SOURCE lake
    WITH (LOCATION = N'https://$(storage_account).dfs.core.windows.net/lake');
GO

-- Output format for silver/gold CETAS. Snappy: fast, splittable, the Parquet default.
IF NOT EXISTS (SELECT 1 FROM sys.external_file_formats WHERE name = N'parquet_snappy')
    CREATE EXTERNAL FILE FORMAT parquet_snappy
    WITH (FORMAT_TYPE = PARQUET, DATA_COMPRESSION = N'org.apache.hadoop.io.compress.SnappyCodec');
GO

SELECT 'schema' AS object_type, name FROM sys.schemas WHERE name IN (N'bronze', N'silver', N'gold')
UNION ALL SELECT 'data_source', name FROM sys.external_data_sources
UNION ALL SELECT 'file_format', name FROM sys.external_file_formats;
GO
