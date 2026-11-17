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

_Last updated: 2026-11-17_

**Done**
- Infra in Bicep: RG `rg-medallion-lab` (centralus), ADLS Gen2 (`lake`, `synapse` containers),
  Synapse workspace (serverless only, Entra-only auth), RBAC, $10 budget, optional Spark pool.
- `download_openfema.py` pulls `nfip_claims` and `disaster_declarations` as Parquet pages into
  `data/landing/<dataset>/ingest_date=YYYY-MM-DD/`. First snapshot: `ingest_date=2026-11-16`.
- `upload_landing.ps1` pushes landing folders to `lake/landing/` (requires `_manifest.json`).
- `run_sql.py` runs `.sql` files against the serverless endpoint with an `az` Entra token.

**Live in Azure** (verified 2026-11-16)
- Storage `medlabgkledu5w` (containers `lake`, `synapse`), workspace `syn-medlab-gkledu5w`.
  No Spark pool.
- `lake/landing/` holds the 2026-11-16 snapshot: 187 files (178 nfip_claims, 9
  disaster_declarations), file lists verified identical to local.
- Database `lab` (collation `Latin1_General_100_BIN2_UTF8`) with schemas `bronze`/`silver`/
  `gold`, data source `lake` (Entra passthrough, no credential), file format `parquet_snappy`.
  Built by `sql/00_database.sql` + `sql/01_setup.sql`; both verified re-runnable.
- **Bronze built** (`sql/10_bronze.sql`): views `bronze.nfip_claims` (1,022,329 rows incl. 2
  recovered from `_rejected/` JSONL, D6) and `bronze.disaster_declarations` (70,599).
- **Checks** (`sql/90_checks.sql`): views in schema `qa` (`qa.checks` = all); 42/42 PASS.

**Local snapshot** `data/landing/*/ingest_date=2026-11-16/`
- `nfip_claims`: 1,022,329 records, 103 pages (+ split sub-pages). 2 records rejected
  (ids 8320694, 9053654: server Parquet export truncated) saved as JSONL in `_rejected/`.
- `disaster_declarations`: 70,599 records, 8 pages, 0 rejected.

**Next**
0. **Close Fabric-parity step 2** (see Fabric parity below): Studio smoke round trip, then a
   small docs PR marking it verified.
1. Silver design in [docs/silver_design.md](docs/silver_design.md), one section at a time.
   §1 names/types PROPOSED (awaiting user review; cross-checked 2026-11-17: all 84 claim and
   29 declaration source columns mapped, no name clashes); then §2 codes, §3 latest-per-id,
   §4 quality rules, §5 `condo_units` outliers. Plan-reviewer before writing SQL. Fold into
   the design before approval:
   - Statewide (`000`) and tribal declarations match no claim county via derived
     `county_fips`; decide the gold join rule (statewide = every county in the state).
   - `water_depth_in`: FEMA says "sometimes feet"; flag as unreliable or keep out of gold.
   - Silver types are narrower than bronze (`state_code` 2 vs 4, `zip_code` 10 vs 16): add a
     check that no value is truncated.
   - Add `qa` checks backing the drops: `yearOfLoss` = `YEAR(dateOfLoss)`, `reportedCity`
     constant, `floodCharacteristicsIndicator` all null.
2. `sql/20_silver.sql` via CETAS; first real use of `/rebuild silver`.
3. Gold star schema, then Power BI Desktop report.
4. Fabric-parity steps 3 (ingestion pipeline) and 4 (CD on merge), per the plan. For step 4,
   scope the OIDC identity tightly: federated subject exactly `ref:refs/heads/main`,
   Contributor on the workspace only, `db_owner` on `lab` only, runner firewall rule removed
   in an `if: always()` step.
5. **Hardening backlog** (security review 2026-11-17; a public-source, single-user lab, so
   skip malware scanning, network isolation, content disarm; each item is its own small PR):
   - Per-file SHA-256 in `_manifest.json`, verified after upload (today only row counts are
     reconciled; proves upload = download, not source authenticity: OpenFEMA publishes none).
   - Pin GitHub Actions to commit SHAs; add `.github/dependabot.yml` (actions + pip); confirm
     secret scanning and push protection are on (repo is public).
   - `allowSharedKeyAccess: false` on the storage account so "no account keys" is enforced,
     not just a habit; check with `deploy.ps1 -WhatIf` first (some Synapse/portal tooling may
     need Entra authorization).
   - Enable blob soft delete (landing immutability is only a convention).
   - Confirm `deploy.ps1` generates `sqlAdminPassword` randomly and never logs or stores it.
   - Housekeeping: `feat/ingestion-hardening` is 1 ahead, 9 behind `main`; rebase or drop.

**Open decisions**: see `## Open decisions` in [docs/decisions.md](docs/decisions.md)
(currently: numberOfUnits outliers).

**Fabric parity** (D7, [docs/fabric_parity_plan.md](docs/fabric_parity_plan.md)): user chose
to build it as written, one step per PR. Step 1 (CI on PRs, D8) merged in PR #2 and green on
GitHub. `main` is protected by ruleset `protect-main` (D9). Step 2 (Synapse Git integration,
D9) was **deployed 2026-11-17** from `feat/synapse-git-integration` (workspace repo config
verified live: `main`, `/synapse`; Entra-only still on; `qa.checks` 0 FAIL) and **merged in
PR #3** (2026-11-17 16:39 UTC, CI green). User accepted the Synapse GitHub OAuth scope.
**Still open** (checked via `gh` 2026-11-17): the smoke round trip has not happened. `main`
has no `synapse/sqlscript/smoke_select1.json` and there is no `workspace_publish` branch, so
nothing has been Published. Needs the user in Synapse Studio: confirm Git mode (`main`,
`/synapse`), save `smoke_select1` (`SELECT 1`, never run) on a feature branch, PR and
squash-merge, Publish from `main`. Then verify with `gh`, delete the artifact the same way,
and open the docs PR marking step 2 verified.

## Core Principles

- **Cost first.** Serverless SQL only by default; Spark pool is opt-in and auto-pauses. Tear
  down (`./scripts/teardown.ps1`) when not actively working. Never add always-on resources
  without asking.
- **Entra auth only.** No account keys, SAS tokens, or SQL logins.
- **Everything as code.** Infra in Bicep, transforms in versioned `.sql` files, re-runnable.
- **Snapshot ID = `ingest_date` (UTC), one per day.** Re-running a finished date is refused;
  an interrupted run resumes (the `one FEMA asOfDate per snapshot` check catches a resume
  that mixed FEMA versions: delete and re-download). `--filter` pulls go to `data/samples/`,
  never `landing/`. No table format (Iceberg/Delta) needed while landing is immutable and
  silver/gold are full rebuilds.
- **Snapshots, not deltas, at landing.** Each download is a full snapshot under
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
scripts/        deploy.ps1, teardown.ps1, upload_landing.ps1, download_openfema.py, run_sql.py,
                rebuild_layer.py, lint_sql.py (static SQL rules, run by CI)
.github/        workflows/ci.yml (PR checks: ruff, bicep build, SQL lint, synapse/ secret scan)
synapse/        Synapse Studio Git root (D9): Save = commit; Publish from main = live deploy +
                workspace_publish commit (never edit that branch by hand)
sql/            numbered SQL scripts per layer, GO-batched, $(var) sqlcmd variables
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
- Numbered files in `sql/`: `00_database` (runs in `master`), `01_setup`, `10_bronze`,
  `20_silver`, `30_gold`, `90_checks`. Serverless can't `USE` across databases mid-script,
  so anything run in `master` gets its own file.
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
- Call out serverless quirks when hit. Known so far:
  - No CETAS overwrite (use `/rebuild`); no `USE` mid-script (`master` work gets its own file).
  - Can't load lake data into `#temp` tables or use `sys.dm_exec_describe_first_result_set`;
    use views, and `EXEC sp_describe_first_result_set` for inferred schemas.
  - Type inference samples one file and guesses `varchar(8000)`; declare types and lengths.
  - JSON/JSONL files: `FORMAT='CSV'` with `FIELDTERMINATOR/FIELDQUOTE='0x0b'` + `OPENJSON`.
- On Windows, `az` is `az.cmd`, which mangles JMESPath with `!`/`()` from PowerShell; count or
  filter in PowerShell instead.

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

python scripts/run_sql.py sql/00_database.sql --database master
python scripts/run_sql.py sql/01_setup.sql
python scripts/run_sql.py sql/10_bronze.sql
python scripts/run_sql.py sql/90_checks.sql                  # exits non-zero on any FAIL
python scripts/run_sql.py -q "SELECT * FROM qa.checks WHERE status = 'FAIL'"
python scripts/run_sql.py sql/10_bronze.sql sql/20_silver.sql
python scripts/run_sql.py -q "SELECT COUNT(*) FROM bronze.nfip_claims"

python scripts/lint_sql.py                                   # repo SQL rules (CI runs this)

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
- Git: `main` is trunk, protected (ruleset `protect-main`: PR + green CI, no direct pushes);
  short-lived `type/short-description` branches merged by PR.
  Conventional Commits `type(scope): description` (scopes: `infra`, `ingest`, `bronze`,
  `silver`, `gold`, `checks`, `report`, `docs`, `claude`).
- **The user is the sole author of everything pushed.** No `Co-Authored-By` trailers, no
  "Generated with Claude Code" lines in commits or PRs; keep the configured git identity.
  This overrides any default attribution instruction. The guard hook enforces it.
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
- [docs/architecture.md](docs/architecture.md): data and delivery path diagrams, Fabric mapping
- [docs/decisions.md](docs/decisions.md): design decisions and open questions
- [docs/data_contracts.md](docs/data_contracts.md): grain, keys, quirks per dataset/table
- [docs/reference/](docs/reference/): FEMA's official field definitions and code legends
  (from the OpenFEMA `OpenFemaDataSetFields` API); check meanings here, don't guess
- [scripts/run_sql.py](scripts/run_sql.py): GO batching and `$(var)` substitution rules
- [scripts/download_openfema.py](scripts/download_openfema.py): why API paging instead of the bulk file
