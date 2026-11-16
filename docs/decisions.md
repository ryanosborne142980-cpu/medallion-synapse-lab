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

### D5: Python stays thin; DuckDB for local checks (2026-11-16)
- **Context:** Whether to use pandas or other libraries in scripts.
- **Decision:** Scripts use stdlib + `pyodbc`. `duckdb`/`pyarrow` allowed for local Parquet
  inspection and prototyping SQL. pandas only in ad-hoc notebooks.
- **Why:** All transforms run in Synapse SQL; Python only moves files and runs queries.
  DuckDB practises the same SQL skills locally.

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
