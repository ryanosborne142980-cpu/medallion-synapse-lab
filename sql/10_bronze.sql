-- Bronze: views over landing/, data as received. Run against lab:
--   python scripts/run_sql.py sql/10_bronze.sql
-- Re-runnable (CREATE OR ALTER). No data is copied; every query reads the Parquet files.
--
-- Conventions:
--   * Source column names and Parquet types are kept as received (camelCase). Silver renames
--     and conforms. String lengths were measured on 2026-11-16 and declared with ~2x headroom
--     instead of the inferred varchar(8000), which bloats memory grants and Power BI refresh.
--     sql/90_checks.sql flags any source value longer than its declared length.
--   * ingest_date comes from the folder name via filepath(1) and stays a raw 'YYYY-MM-DD'
--     string: filtering on it prunes folders, and ISO strings sort correctly for silver's
--     latest-per-id logic. Wrapping it in CAST could stop the pruning.
--   * Wildcards read only part-*.parquet, so _manifest.json, _split-*.json and _rejected/
--     are never read as data by accident.
-- Fabric equivalent: Lakehouse "Files" + a SQL analytics endpoint view, or a shortcut table.

-- NFIP claims. Two branches (D6):
--   parquet         the normal pages
--   jsonl_rejected  records whose server Parquet export was truncated; the downloader saved
--                   each as one JSON line in _rejected/. Reading them here keeps bronze at
--                   the full manifest count: source = loaded + quarantined (0 quarantined).
CREATE OR ALTER VIEW bronze.nfip_claims AS
SELECT
    r.*,
    r.filepath(1)                    AS ingest_date,
    r.filename()                     AS source_file,
    CAST('parquet' AS varchar(16))   AS source_format
FROM OPENROWSET(
    BULK 'landing/nfip_claims/ingest_date=*/part-*.parquet',
    DATA_SOURCE = 'lake',
    FORMAT = 'PARQUET'
) WITH (
        agricultureStructureIndicator                 bit,
        asOfDate                                      datetime2(7),
        basementEnclosureCrawlspaceType               smallint,
        policyCount                                   smallint,
        crsClassCode                                  smallint,
        dateOfLoss                                    date,
        elevatedBuildingIndicator                     bit,
        elevationCertificateIndicator                 varchar(4),
        elevationDifference                           int,
        baseFloodElevation                            float,
        ratedFloodZone                                varchar(8),
        houseWorship                                  bit,
        locationOfContents                            smallint,
        lowestAdjacentGrade                           float,
        lowestFloorElevation                          float,
        numberOfFloorsInTheInsuredBuilding            smallint,
        nonProfitIndicator                            bit,
        obstructionType                               smallint,
        occupancyType                                 smallint,
        originalConstructionDate                      date,
        originalNBDate                                date,
        amountPaidOnBuildingClaim                     float,
        amountPaidOnContentsClaim                     float,
        amountPaidOnIncreasedCostOfComplianceClaim    float,
        postFIRMConstructionIndicator                 bit,
        rateMethod                                    varchar(4),
        smallBusinessIndicatorBuilding                bit,
        totalBuildingInsuranceCoverage                int,
        totalContentsInsuranceCoverage                int,
        yearOfLoss                                    smallint,
        primaryResidenceIndicator                     bit,
        buildingDamageAmount                          int,
        buildingDeductibleCode                        varchar(4),
        netBuildingPaymentAmount                      float,
        buildingPropertyValue                         int,
        causeOfDamage                                 varchar(4),
        condominiumCoverageTypeCode                   varchar(4),
        contentsDamageAmount                          int,
        contentsDeductibleCode                        varchar(4),
        netContentsPaymentAmount                      float,
        contentsPropertyValue                         int,
        disasterAssistanceCoverageRequired            smallint,
        eventDesignationNumber                        varchar(16),
        ficoNumber                                    smallint,
        floodCharacteristicsIndicator                 smallint,
        floodWaterDuration                            smallint,
        floodproofedIndicator                         bit,
        floodEvent                                    varchar(100),
        iccCoverage                                   int,
        netIccPaymentAmount                           float,
        nfipRatedCommunityNumber                      varchar(12),
        nfipCommunityNumberCurrent                    varchar(12),
        nfipCommunityName                             varchar(100),
        nonPaymentReasonContents                      varchar(4),
        nonPaymentReasonBuilding                      varchar(4),
        numberOfUnits                                 int,  -- source Parquet is INT16 but 2 records exceed it (D6)
        buildingReplacementCost                       bigint,
        contentsReplacementCost                       int,
        replacementCostBasis                          varchar(4),
        stateOwnedIndicator                           bit,
        waterDepth                                    smallint,
        floodZoneCurrent                              varchar(8),
        buildingDescriptionCode                       smallint,
        rentalPropertyIndicator                       bit,
        state                                         varchar(4),
        reportedCity                                  varchar(100),
        reportedZipCode                               varchar(16),
        countyCode                                    varchar(8),
        censusGeoid                                   varchar(16),
        latitude                                      float,
        longitude                                     float,
        foundationType                                varchar(4),
        openDate                                      date,
        mostRecentRecoveryDate                        date,
        exteriorWaterDepth                            int,
        interiorWaterDepth                            int,
        mostRecentPaymentDate                         date,
        preFirmIndicator                              bit,
        totalSalvageRecovery                          float,
        totalBldgClaimPmtRecovery                     float,
        totalContentsClaimPmtRecovery                 float,
        totalIccClaimPmtRecovery                      float,
        totalSubrogationRecovery                      float,
        id                                            bigint
) AS r

UNION ALL

SELECT
    j.*,
    r.filepath(1)                    AS ingest_date,
    r.filename()                     AS source_file,
    CAST('jsonl_rejected' AS varchar(16)) AS source_format
FROM OPENROWSET(
    -- One JSON document per line: 0x0b (vertical tab) never occurs in the data, so each
    -- line arrives whole as a single column.
    BULK 'landing/nfip_claims/ingest_date=*/_rejected/*.jsonl',
    DATA_SOURCE = 'lake',
    FORMAT = 'CSV',
    FIELDTERMINATOR = '0x0b',
    FIELDQUOTE = '0x0b',
    ROWTERMINATOR = '0x0a'
) WITH (doc varchar(max)) AS r
CROSS APPLY OPENJSON(r.doc) WITH (
        agricultureStructureIndicator                 bit,
        asOfDate                                      datetime2(7),
        basementEnclosureCrawlspaceType               smallint,
        policyCount                                   smallint,
        crsClassCode                                  smallint,
        dateOfLoss                                    date,
        elevatedBuildingIndicator                     bit,
        elevationCertificateIndicator                 varchar(4),
        elevationDifference                           int,
        baseFloodElevation                            float,
        ratedFloodZone                                varchar(8),
        houseWorship                                  bit,
        locationOfContents                            smallint,
        lowestAdjacentGrade                           float,
        lowestFloorElevation                          float,
        numberOfFloorsInTheInsuredBuilding            smallint,
        nonProfitIndicator                            bit,
        obstructionType                               smallint,
        occupancyType                                 smallint,
        originalConstructionDate                      date,
        originalNBDate                                date,
        amountPaidOnBuildingClaim                     float,
        amountPaidOnContentsClaim                     float,
        amountPaidOnIncreasedCostOfComplianceClaim    float,
        postFIRMConstructionIndicator                 bit,
        rateMethod                                    varchar(4),
        smallBusinessIndicatorBuilding                bit,
        totalBuildingInsuranceCoverage                int,
        totalContentsInsuranceCoverage                int,
        yearOfLoss                                    smallint,
        primaryResidenceIndicator                     bit,
        buildingDamageAmount                          int,
        buildingDeductibleCode                        varchar(4),
        netBuildingPaymentAmount                      float,
        buildingPropertyValue                         int,
        causeOfDamage                                 varchar(4),
        condominiumCoverageTypeCode                   varchar(4),
        contentsDamageAmount                          int,
        contentsDeductibleCode                        varchar(4),
        netContentsPaymentAmount                      float,
        contentsPropertyValue                         int,
        disasterAssistanceCoverageRequired            smallint,
        eventDesignationNumber                        varchar(16),
        ficoNumber                                    smallint,
        floodCharacteristicsIndicator                 smallint,
        floodWaterDuration                            smallint,
        floodproofedIndicator                         bit,
        floodEvent                                    varchar(100),
        iccCoverage                                   int,
        netIccPaymentAmount                           float,
        nfipRatedCommunityNumber                      varchar(12),
        nfipCommunityNumberCurrent                    varchar(12),
        nfipCommunityName                             varchar(100),
        nonPaymentReasonContents                      varchar(4),
        nonPaymentReasonBuilding                      varchar(4),
        numberOfUnits                                 int,  -- source Parquet is INT16 but 2 records exceed it (D6)
        buildingReplacementCost                       bigint,
        contentsReplacementCost                       int,
        replacementCostBasis                          varchar(4),
        stateOwnedIndicator                           bit,
        waterDepth                                    smallint,
        floodZoneCurrent                              varchar(8),
        buildingDescriptionCode                       smallint,
        rentalPropertyIndicator                       bit,
        state                                         varchar(4),
        reportedCity                                  varchar(100),
        reportedZipCode                               varchar(16),
        countyCode                                    varchar(8),
        censusGeoid                                   varchar(16),
        latitude                                      float,
        longitude                                     float,
        foundationType                                varchar(4),
        openDate                                      date,
        mostRecentRecoveryDate                        date,
        exteriorWaterDepth                            int,
        interiorWaterDepth                            int,
        mostRecentPaymentDate                         date,
        preFirmIndicator                              bit,
        totalSalvageRecovery                          float,
        totalBldgClaimPmtRecovery                     float,
        totalContentsClaimPmtRecovery                 float,
        totalIccClaimPmtRecovery                      float,
        totalSubrogationRecovery                      float,
        id                                            bigint
) AS j;
GO

-- Disaster declarations: one row per declaration per designated area. No rejected records.
CREATE OR ALTER VIEW bronze.disaster_declarations AS
SELECT
    r.*,
    r.filepath(1)                    AS ingest_date,
    r.filename()                     AS source_file
FROM OPENROWSET(
    BULK 'landing/disaster_declarations/ingest_date=*/part-*.parquet',
    DATA_SOURCE = 'lake',
    FORMAT = 'PARQUET'
) WITH (
        id                                            varchar(40),
        disasterNumber                                smallint,
        state                                         varchar(4),
        femaDeclarationString                         varchar(16),
        declarationType                               varchar(4),
        declarationDate                               date,
        fyDeclared                                    smallint,
        incidentType                                  varchar(50),
        declarationTitle                              varchar(200),
        ihProgramDeclared                             bit,
        iaProgramDeclared                             bit,
        paProgramDeclared                             bit,
        hmProgramDeclared                             bit,
        incidentBeginDate                             date,
        incidentEndDate                               date,
        disasterCloseoutDate                          date,
        tribalRequest                                 bit,
        fipsStateCode                                 varchar(4),
        fipsCountyCode                                varchar(8),
        placeCode                                     varchar(8),
        designatedArea                                varchar(120),
        declarationRequestNumber                      varchar(16),
        lastIAFilingDate                              date,
        incidentId                                    varchar(16),
        region                                        smallint,
        designatedIncidentTypes                       varchar(50),
        declarationRequestDate                        date,
        lastRefresh                                   datetime2(7),
        hash                                          varchar(64)
) AS r;
GO
