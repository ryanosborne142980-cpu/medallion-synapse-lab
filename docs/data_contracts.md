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
- **Known quirks:** some pages truncate in the server's Parquet export; the downloader splits
  them down and saves single bad records as JSONL in `_rejected/` (2 in 2026-11-16).
- **Downstream:** bronze view (planned)

### landing `disaster_declarations`
- **Layer:** landing (files in `lake/landing/disaster_declarations/ingest_date=YYYY-MM-DD/`)
- **Source:** `https://www.fema.gov/api/open/v2/DisasterDeclarationsSummaries`
- **Grain:** one row per declaration per designated area per snapshot. **Key:** `id`
- **Load pattern:** full snapshot per run, same manifest format
- **Downstream:** bronze view → `gold.dim_disaster` (planned)
