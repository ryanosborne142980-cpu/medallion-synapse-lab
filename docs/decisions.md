# Decisions log

Record each design decision when it is made. Newest first. Keep entries short.

## Template

### DN: Short title (YYYY-MM-DD)
- **Context:** what forced the decision.
- **Options:** A) … B) …
- **Decision:** what was chosen.
- **Why:** the trade-off that settled it.
- **Consequences:** what this makes easier or harder; follow-ups.

## Open decisions

- **Rejected NFIP records.** 2 records (ids 8320694, 9053654) in the 2026-11-16 snapshot came
  back as truncated Parquet and were saved as JSONL in `_rejected/`. Options: A) ignore and
  document, B) read the JSONL in a separate bronze view and `UNION` it, C) convert to Parquet
  in the downloader. Must keep reconciliation honest: source = loaded + quarantined.

## Decisions

### D5: Python stays thin; prototype SQL directly in Synapse (2026-11-16)
- **Context:** Whether to use pandas, and where to prototype SQL before committing it.
- **Options:** A) DuckDB on local Parquet B) local SQL Server 2025 sandbox C) Synapse directly.
- **Decision:** C. Scripts use stdlib + `pyodbc` only. pandas only in ad-hoc notebooks.
- **Why:** Serverless bills ~$5/TB scanned (10 MB minimum per query); the full claims
  dataset is ~100 MB, so even 1,000 full-scan queries cost ~$0.50, with no idle cost. A local
  sandbox adds a load script, a second database, and dialect drift, and skips the
  Synapse-specific lessons (Parquet type inference, collation, `filepath()`, CETAS) that are
  the point of the lab.
- **Consequences:** Every query, including experiments, runs in Azure, so the workspace must
  be deployed to work. Prefer `TOP`/partition filters while exploring. The user's local
  SQL Server is not part of this project.

### D4: Database collation `Latin1_General_100_BIN2_UTF8` (2026-11-16)
- **Why:** Required for correct UTF-8 string reads from Parquet and predicate pushdown in
  serverless SQL. Consequence: string comparisons are case-sensitive.

### D3: Gold serves a Power BI Desktop dashboard (2026-11-16)
- **Options:** A) Power BI Desktop B) Fabric report via OneLake shortcut C) custom web page.
- **Decision:** A.
- **Why:** Free, local, native Entra connection to the serverless endpoint, same tool as
  Fabric. A custom page needs a backend to hold the token; Fabric needs capacity.
- **Consequences:** Gold must be a clean star schema. Online sharing would need Pro/Fabric.

### D2: Layer materialization: bronze views, silver/gold CETAS (2026-11-16)
- **Options:** A) all views B) bronze views + silver/gold CETAS C) Spark pool + Delta.
- **Decision:** B.
- **Why:** Bronze needs no copy; CETAS gives real Parquet files that map onto Fabric Lakehouse
  tables and keeps dashboard queries cheap. Serverless only, so no idle cost.
- **Consequences:** CETAS can't overwrite; rebuilds delete the folder and drop the table first.

### D1: Full snapshots at landing, latest-per-id in silver (2026-11-16)
- **Context:** OpenFEMA NfipClaims v3 has no per-record change timestamp.
- **Decision:** Each download is a full snapshot under `ingest_date=YYYY-MM-DD/`; silver keeps
  the row from the latest `ingest_date` per `id`.
- **Why:** The only reliable incremental signal is the snapshot itself.
