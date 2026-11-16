# CLAUDE.md

Read this first every session. The **Where we left off** section is the source of truth for
current progress; keep it updated (see Workflow Guidelines).

## Project Context & Goals

A personal learning lab: medallion architecture (bronze → silver → gold) on **Azure Synapse
serverless SQL over ADLS Gen2**, using public OpenFEMA data (NFIP flood-insurance claims,
disaster declarations). The point is to learn layering and map each piece onto **Microsoft
Fabric** (ADLS → OneLake shortcuts, Synapse → Lakehouse/Warehouse, ADF → Fabric Data Factory).

- Single user, learning, not production.
- **Claude writes the code**; the user reads and runs it. Explanations stay short: a few
  sentences on *why* (the design choice, the trade-off, the Synapse quirk), not a tutorial.
  Add a one-line Fabric equivalent when it's relevant. The user will ask if they want more.
- "Done" for any session = the next session can pick up exactly where this one stopped.

## Where we left off

_Last updated: 2026-11-16_

**Done**
- Infra in Bicep: RG `rg-medallion-lab` (centralus), ADLS Gen2 (`lake`, `synapse` containers),
  Synapse workspace (serverless only, Entra-only auth), RBAC, $10 budget, optional Spark pool.
- `download_openfema.py` pulls `nfip_claims` and `disaster_declarations` as Parquet pages into
  `data/landing/<dataset>/ingest_date=YYYY-MM-DD/`. First snapshot: `ingest_date=2026-11-16`.
- `upload_landing.ps1` pushes landing folders to `lake/landing/` (requires `_manifest.json`).
- `run_sql.py` runs `.sql` files against the serverless endpoint with an `az` Entra token.

**Live in Azure** (verified 2026-11-16)
- Storage `medlabgkledu5w` (containers `lake`, `synapse`), workspace `syn-medlab-gkledu5w`.
  No Spark pool. Serverless SQL has only `master` (no lab database yet).
- `lake` container is **empty**; nothing uploaded yet.

**Local snapshot** `data/landing/*/ingest_date=2026-11-16/`
- `nfip_claims`: 1,022,329 records, 103 pages (+ split sub-pages). 2 records rejected
  (ids 8320694, 9053654: server Parquet export truncated) saved as JSONL in `_rejected/`.
- `disaster_declarations`: 70,599 records, 8 pages, 0 rejected.

**Next**
1. `./scripts/upload_landing.ps1`, then confirm the file count in `lake/landing/`.
2. Create `sql/00_setup.sql` (lab database, data source, file formats, schemas).
3. Bronze layer over `landing/`, then silver (latest `ingest_date` per `id`), then gold.
4. Power BI Desktop report on the gold schema.

**Open decisions**: see `## Open decisions` in [docs/decisions.md](docs/decisions.md)
(currently: how to handle the 2 rejected NFIP records).

## Core Principles

- **Cost first.** Serverless SQL only by default; Spark pool is opt-in and auto-pauses. Tear
  down (`./scripts/teardown.ps1`) when not actively working. Never add always-on resources
  without asking.
- **Entra auth only.** No account keys, SAS tokens, or SQL logins.
- **Everything as code.** Infra in Bicep, transforms in versioned `.sql` files, re-runnable.
- **Snapshots, not deltas, at landing.** Each download is a full snapshot partitioned by
  `ingest_date`; silver keeps the latest `ingest_date` per `id` (OpenFEMA has no per-record
  change timestamp).
- **One layer at a time**, then stop for review. Ask, don't guess, on grain, keys, dedup
  rules, and business definitions.

### Data rules
- Every SQL file is idempotent: rerunning from scratch gives the same result, no duplicates.
  `ingest_date` is the batch ID; carry it through to silver.
- Bronze keeps data as received. Type and conform in silver. Business logic only in gold.
- Never silently drop rows. Failing rows go to a quarantine view/folder with the rule name.
  Reconcile: source (`_manifest.json` `record_count`) = loaded + quarantined.
- Don't present derived values as source facts; name or flag them.
- Timestamps are UTC unless a contract says otherwise.

## Architecture Overview

```
infra/          Bicep (subscription scope): main.bicep, main.bicepparam, modules/lakehouse.bicep
scripts/        deploy.ps1, teardown.ps1, upload_landing.ps1, download_openfema.py, run_sql.py
sql/            (planned) numbered SQL scripts per layer, GO-batched, $(var) sqlcmd variables
data/landing/   local raw downloads, gitignored; mirrors lake/landing/ layout
docs/           decisions.md (design log), data_contracts.md (grain/keys per table)
.claude/        settings.json, hooks/hooks.py (safety guard, ruff format), commands/, agents/
```

### Layers (container `lake`, lab database on serverless SQL)

| Layer   | Materialization | Path | Notes |
|---------|-----------------|------|-------|
| Landing | Parquet files from `download_openfema.py` | `landing/<dataset>/ingest_date=YYYY-MM-DD/` | Full snapshots, immutable |
| Bronze  | Views via `OPENROWSET` | reads `landing/` | Raw columns + `ingest_date` from `filepath()`; no copy |
| Silver  | CETAS → Parquet | `silver/<entity>/` | Typed, cleaned, latest `ingest_date` per `id` |
| Gold    | CETAS → Parquet star schema | `gold/<table>/` | e.g. `fact_claims`, `dim_date`, `dim_geography`, `dim_disaster` |

- **CETAS can't overwrite.** A rebuild = delete the target folder + drop the external table,
  then re-run CETAS. Script that; never assume it's idempotent.
- **Gold feeds a Power BI Desktop dashboard** (free, local) connected to the serverless SQL
  endpoint (`syn-medlab-gkledu5w-ondemand.sql.azuresynapse.net`) with Entra auth. Expose gold
  as views/external tables in a `gold` schema; design a clean star schema (single-direction
  1:many, integer surrogate keys, a proper `dim_date`), friendly column names, no nulls in
  dimension keys. Sharing online would need Pro/Fabric; not a current goal.
- Fabric equivalent: gold Parquet → OneLake shortcut → Lakehouse tables → Direct Lake report.

## Coding Standards

**Python** (plumbing only; transforms live in SQL)
- `from __future__ import annotations`, type hints, module docstring with usage examples.
- Scripts: stdlib + `pyodbc` only. No pandas in scripts (fine for ad-hoc notebooks). Pin
  deps in `requirements.txt`; use `.venv/`.
- Fail with `SystemExit("clear message")`, not stack traces, for expected errors.
- Format/lint with `ruff`.

**PowerShell**
- `[CmdletBinding()]`, comment-based help with `.EXAMPLE`, `$ErrorActionPreference = 'Stop'`.
- Check `$LASTEXITCODE` after every `az` call. Default `-ResourceGroupName 'rg-medallion-lab'`.

**SQL** (T-SQL, Synapse serverless dialect)
- Numbered files in `sql/`: `00_setup`, `10_bronze`, `20_silver`, `30_gold`, `90_checks`.
- Re-runnable: `CREATE OR ALTER` for views; `IF EXISTS … DROP` for external objects.
- `GO` between batches; `$(storage_account)`-style variables, never hard-coded names.
- Uppercase keywords, `snake_case` identifiers, one schema per layer (`bronze`/`silver`/`gold`).
- Explicit column lists and types (`WITH (...)` on `OPENROWSET`); no `SELECT *` past bronze.

**Bicep**
- Modules in `infra/modules/`, values in `main.bicepparam`. Run `deploy.ps1 -WhatIf` first.

**Testing**
- No unit-test framework. `sql/90_checks.sql` asserts: row counts per layer vs
  `_manifest.json`, `id` uniqueness in silver, no orphan keys in gold facts.
- Prototype directly in Synapse with `run_sql.py -q` (cheap at this data size, D5); use
  `TOP` and `ingest_date` filters while exploring. Don't use the user's local SQL Server
  for this project.

## Do's and Don'ts

**Don't**
- Run `deploy.ps1` (without `-WhatIf`) or `teardown.ps1` without asking first.
- Create billable resources (Spark pool, dedicated SQL pool, anything always-on) without asking.
- Use storage keys, SAS tokens, or SQL logins.
- Commit anything under `data/` or compiled Bicep JSON.
- Re-download OpenFEMA data when a snapshot exists unless asked (~15 min per run).
- Assume Azure state; check it with `az` / `run_sql.py` first.

**Do**
- Keep every `sql/` file re-runnable from a clean database.
- Derive partition values with `filepath()` instead of hand-adding columns.
- Set the database collation to `Latin1_General_100_BIN2_UTF8` (correct Parquet string
  handling and predicate pushdown).
- Call out serverless quirks when hit (no CETAS overwrite, type inference, collation).

## Common Commands

```powershell
az login
./scripts/deploy.ps1 -WhatIf              # preview infra changes
./scripts/deploy.ps1                      # deploy (re-run if your public IP changes)
./scripts/deploy.ps1 -DeploySparkPool     # include the optional Spark pool
./scripts/teardown.ps1                    # delete the resource group

python scripts/download_openfema.py       # snapshot OpenFEMA datasets to data/landing
./scripts/upload_landing.ps1              # upload all landing snapshots
./scripts/upload_landing.ps1 -Dataset nfip_claims

python scripts/run_sql.py sql/00_setup.sql --database master
python scripts/run_sql.py sql/10_bronze.sql sql/20_silver.sql
python scripts/run_sql.py -q "SELECT COUNT(*) FROM bronze.nfip_claims"

python scripts/rebuild_layer.py silver                       # dry run: tables + folders to delete
python scripts/rebuild_layer.py silver --apply --rerun-check # rebuild, prove idempotent, run checks
```

## Workflow Guidelines

- Update **Where we left off** automatically, without being asked, after any meaningful
  milestone and before ending a session: date, done, live state, next, open questions.
  Verify live state (`az`, `run_sql.py`) rather than assuming it.
- Multi-step, schema, or infra work: plan first, have the `plan-reviewer` agent review it,
  fix blocking issues, then ask the user to approve.
- Record design decisions in `docs/decisions.md`; grain/keys/load pattern per table in
  `docs/data_contracts.md`. Update both in the same change as the SQL.
- **Ask first** before: commit, push, PR, merge; destructive DDL or lake deletes; deploy or
  teardown. Never force-push `main`. Check `git status` first; never discard user changes.
- Git: `main` is trunk; short-lived `type/short-description` branches merged by PR.
  Conventional Commits `type(scope): description` (scopes: `infra`, `ingest`, `bronze`,
  `silver`, `gold`, `checks`, `report`, `docs`, `claude`).
- Slash commands: `/verify` checks, `/grill` adversarial branch review, `/commit-pr` commit +
  PR (never merges), `/learn` record a lesson, `/prune` shrink this file, `/rebuild <layer>`
  safe silver/gold rebuild (never hand-roll CETAS cleanup).
- When the user corrects you, offer `/learn` so it isn't repeated.
- Hooks (`.claude/hooks/hooks.py`) prompt on deploy/teardown/DROP/git publish from the
  command line, but **not** DROPs inside `.sql` files run by `run_sql.py`; review those.

## Example Snippets

TODO

## Lessons

<!-- One line per lesson: imperative rule + short reason. Max 15. Add with /learn. -->

## References

- [README.md](README.md): infra overview and setup
- [docs/decisions.md](docs/decisions.md): design decisions and open questions
- [docs/data_contracts.md](docs/data_contracts.md): grain, keys, quirks per dataset/table
- [scripts/run_sql.py](scripts/run_sql.py): GO batching and `$(var)` substitution rules
- [scripts/download_openfema.py](scripts/download_openfema.py): why API paging instead of the bulk file
