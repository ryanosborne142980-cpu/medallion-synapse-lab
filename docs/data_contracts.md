# Data contracts

One entry per table or view. Update when one is added or its grain, keys, or columns change.

## Template

### `schema.table`
- **Layer:** landing / bronze / silver / gold
- **Grain:** one row per …
- **Keys:** business key …; surrogate key …
- **Load pattern:** view / CETAS full rebuild; source snapshot(s) used
- **Not-null columns:** …
- **Quality rules:** checks in `sql/90_checks.sql`
- **Inferred columns:** column: method (or "none")
- **Upstream / downstream:** …

## Tables

### landing `nfip_claims`
- **Layer:** landing (files in `lake/landing/nfip_claims/ingest_date=YYYY-MM-DD/`)
- **Source:** `https://www.fema.gov/api/open/v3/NfipClaims`, paged 10,000 rows ordered by `id`
- **Grain:** one row per claim per snapshot. **Key:** `id` (unique within a snapshot)
- **Load pattern:** full snapshot per run; `_manifest.json` holds `record_count`, `rejected`
- **Known quirks:** FEMA's Parquet export types `numberOfUnits` as INT16; records with larger
  values break the export. The downloader splits such pages down and saves each bad record
  as JSONL in `_rejected/` (2 in 2026-11-16: `numberOfUnits` 99999 and 34970).
- **Downstream:** `bronze.nfip_claims`

### landing `disaster_declarations`
- **Layer:** landing (files in `lake/landing/disaster_declarations/ingest_date=YYYY-MM-DD/`)
- **Source:** `https://www.fema.gov/api/open/v2/DisasterDeclarationsSummaries`
- **Grain:** one row per declaration per designated area per snapshot. **Key:** `id`
- **Load pattern:** full snapshot per run, same manifest format
- **Downstream:** `bronze.disaster_declarations` → `gold.dim_disaster` (planned)

### `bronze.nfip_claims`
- **Layer:** bronze (view, `sql/10_bronze.sql`); no data copied
- **Grain:** one row per claim per snapshot. **Key:** (`id`, `ingest_date`)
- **Columns:** 84 source columns, camelCase and Parquet types as received, except
  `numberOfUnits` widened smallint → int (D6); string lengths measured 2026-11-16 with ~2x
  headroom. Plus `ingest_date` (raw 'YYYY-MM-DD' from folder), `source_file`,
  `source_format` (`parquet` | `jsonl_rejected`).
- **Load pattern:** view over all snapshots; filter `ingest_date` to prune folders
- **Quality rules:** `qa.bronze_checks` (rows = manifest, recovered = rejected_count, no
  duplicate ids per snapshot), `qa.bronze_string_lengths` (no truncation)
- **Verified 2026-11-16:** 1,022,329 rows (1,022,327 parquet + 2 jsonl_rejected)
- **Inferred columns:** none

### `bronze.disaster_declarations`
- **Layer:** bronze (view, `sql/10_bronze.sql`)
- **Grain:** one row per declaration per designated area per snapshot. **Key:** (`id`, `ingest_date`)
- **Columns:** 29 source columns as received (`id` is a GUID string) + `ingest_date`, `source_file`
- **Quality rules:** as above
- **Verified 2026-11-16:** 70,599 rows
- **Inferred columns:** none
