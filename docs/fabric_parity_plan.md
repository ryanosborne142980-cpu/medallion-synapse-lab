# Fabric-parity plan (PROPOSED, not approved)

Goal: get this lab as close to a Microsoft Fabric project as possible using only Azure Synapse
and Azure Data Factory. Nothing here is built yet. Each section needs review before code, and
several items conflict with current Core Principles (see "Conflicts" below).

## 1. Target architecture (Fabric concept -> what this lab uses)

| Fabric | This lab |
|---|---|
| OneLake, Lakehouse Files / Tables | ADLS Gen2 `lake`: `landing/` = Files; `bronze/`, `silver/`, `gold/` = Tables |
| Fabric Data Factory | Azure Data Factory (pipelines and Copy activity are near 1:1) |
| Fabric notebooks | Synapse Spark notebooks (PySpark) |
| SQL analytics endpoint | Synapse serverless SQL views over the lake |
| Warehouse (T-SQL) | Serverless views / CETAS |
| Direct Lake semantic model | No equivalent; Power BI Desktop Import or DirectQuery on serverless |
| Shortcuts, Mirroring, Eventstream | No equivalent; out of scope |

Hard constraint: serverless SQL reads Delta but cannot write it (CETAS writes Parquet/CSV only).
Delta bronze/silver/gold therefore needs a Spark pool.

## 2. Ingestion by source type

Land raw and unchanged in `landing/<source>/<dataset>/ingest_date=YYYY-MM-DD/`; bronze adds audit
columns. Only the extraction method differs.

| Source | Fabric | This lab | Load pattern |
|---|---|---|---|
| REST API | Copy activity / notebook | ADF Copy (REST source, `$skip` paging) or notebook | Full snapshot if no change key; else watermark |
| Relational DB | Mirroring / Copy | ADF Copy (self-hosted IR if on-prem) | Watermark column or CDC; full reload if small |
| Flat files | Copy / Dataflows Gen2 | ADF Copy; Get Metadata + ForEach for many files | Drop into landing; archive processed files |
| Cloud storage | Shortcut | ADF Copy, or read in place via external data source | Copy for isolation/history; in place for static reference data |
| Streaming | Eventstream | Event Hubs Capture to ADLS, then batch | Micro-batch from captured files |
| SaaS | Dataflows Gen2 / connectors | ADF connectors | Watermark on modified date |

Rules for all sources:
- Land first, transform later; replay from landing when formats change.
- Bronze audit columns: `_ingest_ts`, `_source_file`, batch id (`ingest_date` today).
- Idempotent loads: rerunning a day overwrites that partition.
- Bronze permissive on schema drift; silver strict and fails loudly.
- Quarantine bad records (as `_rejected/` does); never drop silently.
- Secrets in Key Vault with managed identity; no keys in pipeline JSON.
- Deletes are only detected by CDC or a full compare; a plain watermark misses hard deletes.

## 3. ADF control-table design

Host: Azure SQL Database (serverless or free tier). Synapse serverless SQL cannot hold this
state because it cannot write tables.

```sql
CREATE TABLE ctl.source_config (
  source_id         int PRIMARY KEY,
  source_type       varchar(20),    -- rest | sql | file | snowflake
  dataset           varchar(100),
  linked_service    varchar(100),
  endpoint_or_query nvarchar(max),
  watermark_col     varchar(100) NULL,
  load_type         varchar(12),    -- full | incremental
  landing_path      varchar(300),
  enabled           bit
);
CREATE TABLE ctl.watermark (source_id int PRIMARY KEY, last_value varchar(50), updated_ts datetime2);
CREATE TABLE ctl.run_log (
  run_id bigint IDENTITY, source_id int, adf_run_id varchar(50),
  start_ts datetime2, end_ts datetime2, status varchar(10),
  rows_copied bigint, error nvarchar(max)
);
```

Flow:
1. `PL_master`: Lookup `source_config WHERE enabled = 1`; ForEach (batch count about 4) calls
   `PL_ingest_child` per row.
2. `PL_ingest_child`: if incremental, Lookup old watermark and source `MAX(watermark_col)`;
   Switch on `source_type` to pick the Copy activity; write to
   `landing_path/ingest_date=<utc date>/`; on success a stored procedure updates the watermark
   and logs rows; on failure it logs the error.
3. After the loop: bronze -> silver -> gold notebooks, then `sql/90_checks.sql`.

Watermark rules: update only after a successful copy, using the "new max" captured before the
copy; filter `> old AND <= new`; reruns overwrite that day's partition.

First step for this lab: two rows (`nfip_claims`, `disaster_declarations`), both `rest` and
`full`.

## 4. Conflicts with current Core Principles (decide before building)

- **"No table format (Iceberg/Delta) needed"**: Delta bronze/silver/gold reverses this. Fabric
  parity argues for Delta; the current immutable-landing + full-rebuild design argues against.
- **"Serverless SQL only; Spark pool opt-in"**: Delta writes need the Spark pool (Small, 3 nodes,
  auto-pause 5 min). Cost against the $10 budget must be estimated first.
- **"Never add always-on resources without asking"**: Azure SQL Database for the control table
  and the ADF instance are new billable resources and need explicit approval.
- **Scripts are stdlib + pyodbc only**: PySpark notebooks sit outside this rule; decide whether
  notebooks live in the repo and how they are linted.
- **Downloader behavior to preserve**: the bulk Parquet export returns 403 and truncates two
  records (D6). A Copy activity reading JSON and writing Parquet may avoid the truncation, but
  that is unverified; test against ids 8320694 and 9053654.

## 5. Suggested order

1. Approve or reject the conflicts above and record the outcome in `docs/decisions.md`.
2. Bicep: ADF, Azure SQL control DB (and Spark pool, opt-in).
3. Control table + `PL_master` / `PL_ingest_child` for the two FEMA datasets; compare row
   counts to the existing `_manifest.json`.
4. Bronze Delta notebook, then silver and gold per the existing layer-by-layer review process.
5. Keep storage paths in one config cell so a Fabric port swaps `abfss://` paths for `Tables/`
   and `Files/`; wrap `mssparkutils` calls (Fabric uses `notebookutils`).
