# Fabric-parity plan (APPROVED 2026-11-17, not built)

Goal: get this lab as close as practical to a Microsoft Fabric project using only the existing
Synapse workspace and storage account. Nothing here is built yet. Revised 2026-11-17: replaces
the earlier standalone-ADF + Azure SQL control DB + Delta proposal (rejected below).

## 1. Fabric concept -> this lab

| Fabric | This lab | Parity | Extra cost |
|---|---|---|---|
| OneLake | ADLS Gen2 `medlabgkledu5w` (HNS on, verified 2026-11-17) | High | none |
| Lakehouse Files / Tables | `landing/` = Files; `bronze`/`silver`/`gold` = Tables (convention) | High | none |
| SQL analytics endpoint | Serverless SQL views / CETAS (built) | High | per TB scanned |
| Fabric Data Factory | **Synapse pipelines** (same engine and Copy activity as ADF, inside the workspace) | High | cents per run |
| Workspace Git integration | Synapse Git integration with this GitHub repo | High | free |
| Deployment pipelines | GitHub Actions: check on PR, deploy on merge, OIDC login | Medium (one env) | free (public repo) |
| Notebooks + Delta tables | Spark pool + Delta | High | ~$1-2/hour running; **deferred** |
| Direct Lake, shortcuts, mirroring, single capacity | Nothing equivalent | None | n/a |

Why Synapse pipelines over standalone ADF: same Copy activity and connectors, but no extra
resource, identity, or deploy target, and they live in the workspace as in Fabric. The workspace
managed identity already has Storage Blob Data Contributor on the account, and the account has
no network ACLs, so pipelines can write to `lake` with no new RBAC.

## 2. CI/CD shape

Three deploy paths, each owned by one mechanism (no overlap):

| What | How it reaches Azure |
|---|---|
| Infra (Bicep) | **Manual** `deploy.ps1` from the user's machine, as today (decided; see section 6) |
| Synapse artifacts (pipelines, linked services) | Synapse Studio **Publish** from the collaboration branch (`main`) |
| `sql/` files | **CD** on merge to `main` |

Why infra stays manual: `main.bicep` takes `clientIp` (firewall rule), `userObjectId` (Entra SQL
admin `sid` + a role assignment) and `sqlAdminPassword`. A runner-driven deploy would overwrite
the user's firewall IP and SQL admin unless all three were pinned as GitHub variables/secrets,
and creating role assignments would need RBAC Administrator at subscription scope. Neither is
worth it for one environment. CI still validates Bicep on every PR.

Why no `synapse-workspace-deployment` step: with one environment, Publish already updates the
live workspace; deploying the `workspace_publish` ARM templates again would be redundant.

- **CI (on PR, no Azure access):** `ruff check` + `ruff format --check`, `az bicep build`, and a
  static SQL lint (TBD: `sqlfluff` with the `tsql` dialect, or a parse-only check). Free.
- **CD (on merge to `main`, only when `sql/**` changed):** `azure/login` via OIDC -> add a
  Synapse firewall rule for the runner IP -> `run_sql.py` for changed layer files -> `90_checks.sql`
  (fails the job on any FAIL) -> remove the firewall rule in an `if: always()` step. Silver/gold
  CETAS changes go through the `/rebuild` logic (`rebuild_layer.py --apply`), never a plain rerun.
- **Identity:** an Entra app registration with a federated credential whose subject matches the
  workflow exactly (`repo:<owner>/<repo>:ref:refs/heads/main`; it changes if the job uses
  `environment:`). No secret stored in GitHub. Permissions:
  - Azure RBAC: Contributor scoped to the workspace resource only (to write `firewallRules`).
  - Storage Blob Data Contributor on the account (bronze views and CETAS run as the caller).
  - SQL: `CREATE USER [<app>] FROM EXTERNAL PROVIDER` in `lab` with DDL rights (`db_owner` is
    acceptable for a lab), plus a login in `master` if `00_database.sql` ever runs from CD
    (proposed: it doesn't; database creation stays manual).
- **One environment (dev).** A test/prod pair would double resource cost; out of scope for a lab.
- **Studio work goes through PRs:** author pipelines in a feature branch in Synapse Studio, merge
  by PR, then Publish from `main`. Linked services take the storage account name as a
  parameter, not a hard-coded value.

## 3. Ingestion pipeline (replaces `download_openfema.py` + `upload_landing.ps1`)

Metadata-driven, but the config is a JSON file in the lake, not a database:
`lake/config/sources.json`, versioned in the repo and uploaded manually in step 3 (a CD upload
can come later). Lookup reads it; ForEach runs a child pipeline per dataset. Both FEMA datasets
are full snapshots, so no watermark state is needed.

`PL_ingest_parent`: computes the UTC date **once** and passes it to each child, so a run that
crosses midnight can't split across two snapshots. Pipeline concurrency = 1. The target root is a
parameter (`landing/` or `samples/pipeline_test/`).

`PL_ingest_child` per dataset:
1. **Snapshot guard:** Get Metadata with `fieldList: ["exists"]` on
   `<root>/<dataset>/ingest_date=<date>/_manifest.json` -> If Condition -> Fail activity when it
   exists (a finished date is never rewritten). When the manifest is missing but the folder
   exists (an interrupted run), Delete the folder first so no orphan pages remain.
2. **Source count:** Web activity, `$inlinecount=allpages&$top=1&$select=id` -> `record_count`.
3. **Copy:** REST source, `$orderby=id` (stable paging, as the downloader does), pagination rule
   `QueryParameters.$skip = RANGE:0:<record_count>:<top>`, collection reference = the entity
   array (not `metadata`). **Explicit column mapping** with types that match the bronze
   `WITH (...)` clause, so pipeline Parquet and script Parquet read identically. Fault tolerance
   **off** (no silently skipped rows); any row that fails fails the run.
4. **End count:** a second Web count call after Copy -> `record_count_end`.
5. **Reconcile:** If Condition fails the run unless `rowsCopied = record_count` and
   `record_count_end = record_count`, before any manifest exists.
6. **Manifest:** Web activity with MSI auth (resource `https://storage.azure.com/`) doing a blob
   `PUT` (`x-ms-blob-type: BlockBlob`, `x-ms-version`) of `_manifest.json` with the fields the
   checks read: `record_count`, `record_count_end`, `rejected_count` (0 with fault tolerance
   off), plus `dataset`, `source`, and `filter` as the downloader writes. `qa.ingestion_checks` must
   pass unchanged.
7. Run history lives in Synapse Monitor (45 days); no run-log table.

Test plan: run with root = `samples/pipeline_test/`, **never `landing/`**. Bronze reads
`landing/<dataset>/ingest_date=*` and silver keeps the latest snapshot per id, so a test run in
`landing/` would become the silver source. Compare against the 2026-11-16 snapshot: row counts,
column types (`sp_describe_first_result_set` over both), and the two truncated ids (8320694,
9053654). Only after all three match does a pipeline run target `landing/`. If Copy recovers both
records from JSON, D6's `_rejected/` path isn't needed for pipeline runs. Keep the Python scripts
until then.

Ingestion patterns for other source types (REST/DB/files/streaming/SaaS) and their load
patterns from the earlier draft still apply; only "ADF" now reads "Synapse pipeline".

## 4. Rejected from the earlier draft

- **Standalone ADF:** duplicates Synapse pipelines; extra resource and identity.
- **Azure SQL control DB:** a new billable resource; a JSON config file covers two full-snapshot
  sources. Revisit only if watermark-based sources are added.
- **Delta via Spark now:** reverses "no table format" and adds Spark cost. Deferred to an
  optional step 5 with its own budget estimate.
- **Key Vault:** OpenFEMA needs no secret; add only when a source does.

## 5. Order (cheapest and most useful first)

1. **CI check workflow** on PRs (no Azure, no cost).
2. **Synapse Git integration** with this repo (Bicep `workspaceRepositoryConfiguration`, root
   folder `synapse/`, collaboration branch `main`); build pipelines in Synapse Studio, saved as
   JSON here. Publish writes ARM templates to the `workspace_publish` branch.
3. **Ingestion pipeline** (section 3): upload `config/sources.json` manually, test into
   `samples/pipeline_test/`, promote to `landing/` once it matches the script snapshot.
4. **CD on merge** (section 2): app registration + federated credential, SQL user, firewall
   step, `sql/` deploy + checks.
5. Optional, later: Spark pool + Delta tables, after a cost estimate against the $10 budget.

Each step is its own branch and PR, reviewed before the next starts. Silver design (CLAUDE.md
Next #1) is independent and can proceed in parallel.

## 6. Principle changes this needs (decide before building)

- **"Everything as code":** pipeline JSON authored in Synapse Studio and saved via Git counts as
  code; record that in `docs/decisions.md`.
- **Scripts are stdlib + pyodbc only:** unchanged; CI tools (`ruff`, SQL linter) run only in
  Actions/dev, not in scripts.
- **No new always-on resources:** satisfied. The app registration costs nothing; pipelines bill
  per run only.

Decided by the user (2026-11-17):
- **Infra stays out of CD:** Bicep is a manual `deploy.ps1`; CI only builds it.
- **Scripts stay as a fallback:** once pipeline snapshots match, the pipeline is the normal
  path; `download_openfema.py` + `upload_landing.ps1` remain for local runs, and D6 stays.
