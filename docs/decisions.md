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

- **`numberOfUnits` outliers** (silver): values 99999 and 34970 on the two recovered claims.
  99999 looks like a FEMA "unknown" sentinel; 34970 may be real or a data-entry error.
  Decide in silver: keep, null out sentinel with a flag, or cap. Check how often each occurs.

## Decisions

### D9: Synapse Git integration via Bicep; protected main (2026-11-17)
- **Context:** Fabric-parity step 2 (D7): pipeline work must live in Git, like a Fabric
  workspace's Git integration.
- **Options:** A) connect once in Studio (click-ops); B) `workspaceRepositoryConfiguration` in
  Bicep (GitHub, collaboration branch `main`, root `/synapse`).
- **Decision:** B. `main` is protected by the GitHub ruleset `protect-main`: PR required (0
  approvals, since a sole author can't self-approve), both CI checks required on an up-to-date
  branch, no force-push or deletion, no bypass (applies to the user, and so to Studio). Studio
  work happens in Studio feature branches, then a PR squash-merged with a Conventional Commit
  title, then **Publish from `main`** (the only deploy path for Synapse artifacts).
  `workspace_publish` holds machine-generated ARM commits outside the commit convention; never
  protect, edit or merge it. Pipeline JSON saved via Git counts as "everything as code".
  Linked services use the workspace managed identity only (Key Vault if a source ever needs a
  secret); CI fails on inline secrets in `synapse/` because the repo is public.
- **Why:** the connection survives teardown/redeploy as code; protecting `main` keeps "merged
  by PR" true even though Studio commits as the user.
- **Consequences:** a redeployed workspace's live mode is empty: open Studio, re-authorize
  GitHub if asked, Publish from `main`. Empty `gitAccountName` means "never configure" (fresh
  deploys only); whether it disconnects a connected workspace is unverified, so disconnect in
  Studio (Manage > Git configuration). Studio commits use the GitHub account's email, which may
  differ from the local git identity. The workspace PUT now also sets
  `azureADOnlyAuthentication: true` so a redeploy never briefly re-enables SQL auth.

### D8: CI SQL lint is a repo-rules linter, not sqlfluff (2026-11-17)
- **Context:** D7's CI step needed a static SQL check; the plan left `sqlfluff` vs parse-only
  open.
- **Options:** A) `sqlfluff --dialect tsql`; B) a parse-only check; C) `scripts/lint_sql.py`,
  a stdlib linter for this repo's rules.
- **Decision:** C. Rules: `NN_name.sql` file names, only `$(storage_account)`/`$(workspace)`
  variables, no hard-coded storage/SQL host names, no `USE`, `CREATE OR ALTER VIEW`, an IF guard
  in the batch for `CREATE DATABASE/SCHEMA/EXTERNAL DATA SOURCE/FILE FORMAT`, an earlier
  `DROP EXTERNAL TABLE` before CETAS, and no `SELECT *` in files numbered 20+.
- **Why:** tested on 2026-11-17: sqlfluff 4.5 can't parse valid Synapse DDL
  (`CREATE EXTERNAL FILE FORMAT ... DATA_COMPRESSION` in `01_setup.sql`) and its layout rules
  flag dozens of style nits. No parser for the serverless dialect runs offline, so B has the
  same gap. C catches the mistakes that actually break reruns or deploys.
- **Consequences:** it's regex-based (comments and string contents are blanked first), so it
  misses some constructs and doesn't check syntax. Syntax errors still surface only when
  run live (`run_sql.py`, later the CD job).

### D7: Fabric parity via Synapse pipelines + GitHub Actions (2026-11-17)
- **Context:** map the lab onto Fabric (Data Factory, Git integration, deployment pipelines)
  without new always-on resources.
- **Options:** A) standalone ADF + Azure SQL control DB + Spark/Delta (first draft);
  B) Synapse pipelines in the existing workspace, JSON config in the lake, Actions CI/CD.
- **Decision:** B. CI on PR (ruff, bicep build, SQL lint). CD on merge deploys only `sql/` +
  checks via OIDC; Bicep stays a manual `deploy.ps1`; Synapse artifacts reach Azure via Studio
  Publish. Pipeline tests run in `samples/pipeline_test/`, never `landing/`. Python scripts stay
  as a fallback after the pipeline matches. Delta/Spark deferred.
- **Why:** same Copy engine as ADF/Fabric with no extra resource or identity; keeping infra out
  of CD avoids storing the client IP / admin object ID / SQL password in GitHub and granting
  the app RBAC Administrator.
- **Consequences:** one environment only; CD needs a per-job Synapse firewall rule for the
  runner IP. Details: [fabric_parity_plan.md](fabric_parity_plan.md).

### D6: Recover rejected NFIP records from JSONL in bronze (2026-11-16)
- **Context:** 2 records (ids 8320694, 9053654) broke FEMA's server-side Parquet export and
  were saved by the downloader as JSONL in `_rejected/`.
- **Root cause (found while building bronze):** FEMA types `numberOfUnits` as INT16 in its
  Parquet export; these records hold 99999 and 34970, which overflow it.
- **Options:** A) ignore and document B) read the JSONL in bronze and `UNION ALL` it
  C) convert to Parquet in the downloader.
- **Decision:** B. `bronze.nfip_claims` has a second branch reading `_rejected/*.jsonl` via
  `OPENROWSET` (CSV with 0x0b terminators) + `OPENJSON`, tagged `source_format =
  'jsonl_rejected'`. `numberOfUnits` is declared `int` in both branches.
- **Why:** Bronze matches the manifest exactly (1,022,329), nothing silently dropped, and no
  change to the downloader.
- **Consequences:** Bronze declares the same 84-column list twice; keep them identical.
  Future snapshots with new rejects are picked up automatically by the wildcard.

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
