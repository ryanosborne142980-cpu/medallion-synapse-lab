-- Creates the lab database on the serverless SQL endpoint. Run against master:
--   python scripts/run_sql.py sql/00_database.sql --database master
--
-- Collation (D4): Latin1_General_100_BIN2_UTF8 makes Parquet UTF-8 strings read correctly and
-- lets string filters push down into the Parquet reader. Trade-off: comparisons are
-- case-sensitive ('TX' <> 'tx').
-- Fabric equivalent: a Lakehouse's SQL analytics endpoint (created for you, no DDL).

IF DB_ID(N'lab') IS NULL
    CREATE DATABASE lab COLLATE Latin1_General_100_BIN2_UTF8;
GO

SELECT name, collation_name FROM sys.databases WHERE name = N'lab';
GO
