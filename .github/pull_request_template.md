## Summary

<!-- What does this PR add or fix? -->

## Changes

<!-- Meaningful changes. Note new or changed tables/views, grain, or keys. -->

## Validation

- [ ] `/verify` passed (ruff, bicep build, `90_checks.sql` if present)
- [ ] Changed SQL rerun from scratch; row counts unchanged (idempotent)
- [ ] Reconciliation holds: source = loaded + quarantined

Live validation: <!-- Not run / Run against rg-medallion-lab -->

## Data and docs

- [ ] No keys, SAS tokens, `.env`, or files under `data/`
- [ ] `docs/data_contracts.md` updated for new or changed tables
- [ ] `docs/decisions.md` updated for design decisions
- [ ] `CLAUDE.md` "Where we left off" updated

## Remaining risks or unverified behavior
