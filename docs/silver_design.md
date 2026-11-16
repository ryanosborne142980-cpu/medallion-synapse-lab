# Silver design (working plan)

Built step by step; each section is approved before the next. Once silver is built, the final
column lists move into `docs/data_contracts.md` and this file is trimmed or deleted.

Inputs: profile of bronze on 2026-11-16 (1,022,329 claims, 70,599 declaration rows) and
FEMA's field definitions in [reference/](reference/) (`*_fields.json`, from the OpenFEMA
`OpenFemaDataSetFields` API).

## 1. Names and types: PROPOSED

### Conventions
- `snake_case`. Names say what the value is, not FEMA's form label.
- Booleans: `is_…` (bit). Dates: `…_date` (date). Codes: `…_code`, kept as received
  (decoding is section 2). Units in the name where FEMA gives one: `_ft`, `_in`, `_hours`.
- Money FEMA reports with cents (float in Parquet) → `decimal(14,2)` `…_amount`, so sums in
  Power BI are exact. Whole-dollar fields stay `int`/`bigint`.
- Elevations (float) → `decimal(9,1)`. Lat/long are FEMA-rounded to 1 decimal → `decimal(4,1)`
  / `decimal(5,1)`.
- Every string: trimmed, `''` → `NULL` (bronze has empty `state` and `reportedZipCode`).
- Lineage on every row: `ingest_date` (now `date`), `source_file`, `source_format`.
- Silver keeps every column with meaning; gold picks what the dashboard needs. Drop only
  columns that are empty, constant, or exactly derivable.
- Not in this section: sentinel values (`0001-01-01`, `-9999`, `99999`, future dates),
  negative payments, and outliers. Those are section 4 (quality rules).

### `silver.nfip_claims`: 84 source columns → 81 + 3 lineage

**Dropped (3)**

| Source | Why |
|---|---|
| `floodCharacteristicsIndicator` | 100% null |
| `reportedCity` | Always "Currently Unavailable" (FEMA withholds it) |
| `yearOfLoss` | Equals `YEAR(dateOfLoss)` on every row; `dim_date` provides it |

**Keys, lineage, dates**

| Source | Silver | Type | Note |
|---|---|---|---|
| `id` | `claim_id` | bigint | Business key |
| `asOfDate` | `source_as_of_date` | date | FEMA's data date; constant per snapshot |
| (bronze) | `ingest_date` | date | Snapshot folder; latest per `claim_id` wins (section 3) |
| (bronze) | `source_file`, `source_format` | varchar | Lineage |
| `dateOfLoss` | `loss_date` | date | Water first entered the building |
| `openDate` | `claim_open_date` | date | |
| `mostRecentPaymentDate` | `last_payment_date` | date | Has 1900 and 2061 values (section 4) |
| `mostRecentRecoveryDate` | `last_recovery_date` | date | 0.7% populated |
| `originalConstructionDate` | `construction_date` | date | Has `0001-01-01` (section 4) |
| `originalNBDate` | `policy_original_date` | date | Original policy date; has `0001-01-01` |

**Location**

| Source | Silver | Type | Note |
|---|---|---|---|
| `state` | `state_code` | varchar(2) | `''` → NULL |
| `reportedZipCode` | `zip_code` | varchar(10) | `''` → NULL |
| `countyCode` | `county_fips` | varchar(5) | Join key to declarations |
| `censusGeoid` | `census_block_group_geoid` | varchar(12) | |
| `latitude` / `longitude` | same | decimal(4,1) / (5,1) | Privacy-rounded by FEMA |
| `nfipRatedCommunityNumber` | `rated_community_number` | varchar(12) | |
| `nfipCommunityNumberCurrent` | `current_community_number` | varchar(12) | |
| `nfipCommunityName` | `community_name` | varchar(100) | |
| `ratedFloodZone` | `rated_flood_zone` | varchar(8) | Zone used for rating |
| `floodZoneCurrent` | `current_flood_zone` | varchar(8) | Zone today |

**Flood event and damage**

| Source | Silver | Type | Note |
|---|---|---|---|
| `floodEvent` | `flood_event_name` | varchar(100) | |
| `eventDesignationNumber` | `event_designation_number` | varchar(16) | Post-June 2020 event ID |
| `ficoNumber` | `fico_number` | smallint | Pre-June 2020 event ID |
| `causeOfDamage` | `cause_of_damage_code` | varchar(4) | |
| `floodWaterDuration` | `flood_duration_hours` | smallint | |
| `waterDepth` | `water_depth_in` | smallint | FEMA: inches, "sometimes feet" |
| `exteriorWaterDepth` | `exterior_water_depth_in` | int | |
| `interiorWaterDepth` | `interior_water_depth_in` | int | |
| `buildingDamageAmount` | `building_damage_amount` | int | Whole dollars |
| `contentsDamageAmount` | `contents_damage_amount` | int | Whole dollars |

**Building**

| Source | Silver | Type |
|---|---|---|
| `occupancyType` | `occupancy_type_code` | smallint |
| `buildingDescriptionCode` | `building_description_code` | smallint |
| `numberOfFloorsInTheInsuredBuilding` | `floors_code` | smallint (a code: 4 = split-level, 5 = mobile home) |
| `basementEnclosureCrawlspaceType` | `basement_type_code` | smallint |
| `foundationType` | `foundation_type_code` | varchar(4) |
| `obstructionType` | `obstruction_type_code` | smallint |
| `locationOfContents` | `contents_location_code` | smallint |
| `condominiumCoverageTypeCode` | `condo_coverage_type_code` | varchar(4) |
| `numberOfUnits` | `condo_units` | int (outliers: open decision) |
| `policyCount` | `policy_count` | smallint |
| `elevatedBuildingIndicator` | `is_elevated` | bit |
| `postFIRMConstructionIndicator` | `is_post_firm` | bit |
| `preFirmIndicator` | `is_pre_firm` | bit |
| `floodproofedIndicator` | `is_floodproofed` | bit |
| `primaryResidenceIndicator` | `is_primary_residence` | bit |
| `rentalPropertyIndicator` | `is_rental` | bit |
| `agricultureStructureIndicator` | `is_agricultural` | bit |
| `houseWorship` | `is_house_of_worship` | bit |
| `nonProfitIndicator` | `is_non_profit` | bit |
| `smallBusinessIndicatorBuilding` | `is_small_business` | bit |
| `stateOwnedIndicator` | `is_state_owned` | bit |

**Elevation and rating**

| Source | Silver | Type |
|---|---|---|
| `baseFloodElevation` | `base_flood_elevation_ft` | decimal(9,1) |
| `lowestFloorElevation` | `lowest_floor_elevation_ft` | decimal(9,1) |
| `lowestAdjacentGrade` | `lowest_adjacent_grade_ft` | decimal(9,1) |
| `elevationDifference` | `elevation_difference_ft` | int |
| `elevationCertificateIndicator` | `elevation_certificate_code` | varchar(4) |
| `rateMethod` | `rate_method_code` | varchar(4) |
| `crsClassCode` | `crs_class_code` | smallint |
| `disasterAssistanceCoverageRequired` | `disaster_assistance_required_code` | smallint |

**Coverage, values, payments**

| Source | Silver | Type |
|---|---|---|
| `totalBuildingInsuranceCoverage` | `building_coverage_amount` | int |
| `totalContentsInsuranceCoverage` | `contents_coverage_amount` | int |
| `iccCoverage` | `icc_coverage_amount` | int |
| `buildingDeductibleCode` | `building_deductible_code` | varchar(4) |
| `contentsDeductibleCode` | `contents_deductible_code` | varchar(4) |
| `buildingPropertyValue` | `building_property_value` | int |
| `contentsPropertyValue` | `contents_property_value` | int |
| `buildingReplacementCost` | `building_replacement_cost` | bigint |
| `contentsReplacementCost` | `contents_replacement_cost` | int |
| `replacementCostBasis` | `replacement_cost_basis_code` | varchar(4) |
| `amountPaidOnBuildingClaim` | `building_paid_amount` | decimal(14,2) |
| `amountPaidOnContentsClaim` | `contents_paid_amount` | decimal(14,2) |
| `amountPaidOnIncreasedCostOfComplianceClaim` | `icc_paid_amount` | decimal(14,2) |
| `netBuildingPaymentAmount` | `building_net_paid_amount` | decimal(14,2) |
| `netContentsPaymentAmount` | `contents_net_paid_amount` | decimal(14,2) |
| `netIccPaymentAmount` | `icc_net_paid_amount` | decimal(14,2) |
| `totalSalvageRecovery` | `salvage_recovery_amount` | decimal(14,2) |
| `totalBldgClaimPmtRecovery` | `building_recovery_amount` | decimal(14,2) |
| `totalContentsClaimPmtRecovery` | `contents_recovery_amount` | decimal(14,2) |
| `totalIccClaimPmtRecovery` | `icc_recovery_amount` | decimal(14,2) |
| `totalSubrogationRecovery` | `subrogation_recovery_amount` | decimal(14,2) |
| `nonPaymentReasonBuilding` | `building_nonpayment_reason_code` | varchar(4) |
| `nonPaymentReasonContents` | `contents_nonpayment_reason_code` | varchar(4) |

Paid vs net are **not** duplicates: FEMA defines net = paid − recoveries, and they differ on
4,008 (building), 2,833 (contents), 138 (ICC) rows. Paid is null on 160,092 rows where net is
0 (one row has null paid but non-zero net; section 4).

### `silver.disaster_declarations`: 29 source columns → 29 + 1 derived + 2 lineage

| Source | Silver | Type | Note |
|---|---|---|---|
| `id` | `declaration_area_id` | varchar(36) | GUID; one row per declaration × area |
| `femaDeclarationString` | `declaration_code` | varchar(16) | e.g. `DR-4393-NC` |
| `disasterNumber` | `disaster_number` | smallint | |
| `declarationType` | `declaration_type_code` | varchar(2) | DR / EM / FM |
| `declarationTitle` | `declaration_title` | varchar(200) | |
| `declarationDate` | `declaration_date` | date | |
| `declarationRequestDate` | `request_date` | date | |
| `declarationRequestNumber` | `request_number` | varchar(16) | |
| `fyDeclared` | `fiscal_year_declared` | smallint | |
| `incidentType` | `incident_type` | varchar(50) | Already a label |
| `designatedIncidentTypes` | `designated_incident_type_codes` | varchar(50) | Comma list of codes |
| `incidentId` | `incident_id` | varchar(16) | |
| `incidentBeginDate` | `incident_begin_date` | date | |
| `incidentEndDate` | `incident_end_date` | date | 0.9% null (ongoing) |
| `disasterCloseoutDate` | `closeout_date` | date | |
| `lastIAFilingDate` | `last_ia_filing_date` | date | |
| `ihProgramDeclared` … `hmProgramDeclared` | `is_ih_program`, `is_ia_program`, `is_pa_program`, `is_hm_program` | bit | |
| `tribalRequest` | `is_tribal_request` | bit | |
| `state` | `state_code` | varchar(2) | |
| `fipsStateCode` | `state_fips` | varchar(2) | |
| `fipsCountyCode` | `county_fips_suffix` | varchar(3) | As received (3 digits) |
| (derived) | `county_fips` | varchar(5) | `state_fips + county_fips_suffix`: the join key to claims. Derived, documented as such |
| `placeCode` | `place_code` | varchar(8) | |
| `designatedArea` | `designated_area` | varchar(120) | |
| `region` | `fema_region` | smallint | 1–10 |
| `lastRefresh` | `source_last_refresh` | datetime2(0) | |
| `hash` | `source_hash` | varchar(64) | Change detection across snapshots |

Claims carry no disaster number, so gold links claims to declarations by `county_fips` +
`loss_date` within the incident dates. That's a gold design question, noted here because
it's why `county_fips` is derived in silver.

## 2. Code decoding: TODO
## 3. Latest snapshot per id: TODO
## 4. Quality and quarantine rules: TODO
## 5. `condo_units` outliers: TODO
