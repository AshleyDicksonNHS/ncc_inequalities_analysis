/*
================================================================================
DIAGNOSTIC QUERIES: Data Quality Checks for NCC Base Dataset
================================================================================
Purpose: Assess the magnitude of potential deduplication issues identified
         from reviewing Databricks MSDS/HES linkage notebooks

Run these queries to understand:
1. Babies with multiple mothers (data quality issue)
2. Babies with records from multiple organisations
3. Unknown Person IDs
4. Current duplication rates before/after deduplication

Note: These use the same financial year filter as the main query (2023/24)
================================================================================
*/

-- ============================================================================
-- DIAGNOSTIC 1: Babies with Multiple Mothers
-- ============================================================================
-- This is a data quality issue - a single baby should have one mother
-- The Databricks approach excludes these records entirely

WITH babies_with_fy AS (
  SELECT
    Person_ID_Baby,
    Person_ID_Mother,
    UniqPregID,
    CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END AS Birth_FY
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
),

babies_2324 AS (
  SELECT DISTINCT Person_ID_Baby, Person_ID_Mother
  FROM babies_with_fy
  WHERE Birth_FY = '2023/24'
),

mother_counts AS (
  SELECT
    Person_ID_Baby,
    COUNT(DISTINCT Person_ID_Mother) AS distinct_mothers
  FROM babies_2324
  GROUP BY Person_ID_Baby
)

SELECT
  'Babies with multiple mothers' AS diagnostic,
  COUNT(*) AS total_babies,
  SUM(CASE WHEN distinct_mothers = 1 THEN 1 ELSE 0 END) AS single_mother,
  SUM(CASE WHEN distinct_mothers > 1 THEN 1 ELSE 0 END) AS multiple_mothers,
  CAST(100.0 * SUM(CASE WHEN distinct_mothers > 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_multiple
FROM mother_counts;


-- ============================================================================
-- DIAGNOSTIC 2: Babies with Records from Multiple Organisations
-- ============================================================================
-- When a baby has submissions from multiple providers, need to decide which to keep
-- Databricks keeps the one where submitting org matches delivery site

WITH babies_with_fy AS (
  SELECT
    Person_ID_Baby,
    OrgCodeProvider,
    OrgSiteIDActualDelivery,
    CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END AS Birth_FY
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
),

babies_2324 AS (
  SELECT DISTINCT Person_ID_Baby, OrgCodeProvider
  FROM babies_with_fy
  WHERE Birth_FY = '2023/24'
),

org_counts AS (
  SELECT
    Person_ID_Baby,
    COUNT(DISTINCT OrgCodeProvider) AS distinct_orgs
  FROM babies_2324
  GROUP BY Person_ID_Baby
)

SELECT
  'Babies with multiple organisations' AS diagnostic,
  COUNT(*) AS total_babies,
  SUM(CASE WHEN distinct_orgs = 1 THEN 1 ELSE 0 END) AS single_org,
  SUM(CASE WHEN distinct_orgs > 1 THEN 1 ELSE 0 END) AS multiple_orgs,
  CAST(100.0 * SUM(CASE WHEN distinct_orgs > 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_multiple
FROM org_counts;


-- ============================================================================
-- DIAGNOSTIC 3: Unknown Person IDs
-- ============================================================================
-- Person IDs starting with 'U' indicate unknown/unmatched patients
-- Databricks filters these out

WITH babies_with_fy AS (
  SELECT
    Person_ID_Baby,
    Person_ID_Mother,
    CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END AS Birth_FY
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
),

babies_2324 AS (
  SELECT DISTINCT Person_ID_Baby, Person_ID_Mother
  FROM babies_with_fy
  WHERE Birth_FY = '2023/24'
)

SELECT
  'Unknown Person IDs' AS diagnostic,
  COUNT(DISTINCT Person_ID_Baby) AS total_babies,
  COUNT(DISTINCT CASE WHEN Person_ID_Baby LIKE 'U%' THEN Person_ID_Baby END) AS unknown_baby_ids,
  COUNT(DISTINCT CASE WHEN Person_ID_Mother LIKE 'U%' THEN Person_ID_Baby END) AS babies_with_unknown_mother,
  CAST(100.0 * COUNT(DISTINCT CASE WHEN Person_ID_Baby LIKE 'U%' THEN Person_ID_Baby END) /
       COUNT(DISTINCT Person_ID_Baby) AS DECIMAL(5,2)) AS pct_unknown_baby,
  CAST(100.0 * COUNT(DISTINCT CASE WHEN Person_ID_Mother LIKE 'U%' THEN Person_ID_Baby END) /
       COUNT(DISTINCT Person_ID_Baby) AS DECIMAL(5,2)) AS pct_unknown_mother
FROM babies_2324;


-- ============================================================================
-- DIAGNOSTIC 4: Current Duplication Rates by Table
-- ============================================================================
-- Shows raw record count vs unique key count to see duplication factor

-- MSD401: Baby Demographics
SELECT
  'MSD401 - Baby Demographics' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT Person_ID_Baby) AS unique_babies,
  CAST(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT Person_ID_Baby), 0) AS DECIMAL(5,2)) AS duplication_factor
FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
WHERE CASE
    WHEN MonthOfBirthBaby >= 4
      THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                  RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
    ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
  END = '2023/24'

UNION ALL

-- MSD301: Labour & Delivery
SELECT
  'MSD301 - Labour & Delivery' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT LabourDeliveryID) AS unique_deliveries,
  CAST(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT LabourDeliveryID), 0) AS DECIMAL(5,2)) AS duplication_factor
FROM UDAL_Warehouse.MESH_MSDS.MSD301LabourDelivery_1
WHERE StartDateMotherDeliveryHospProvSpell >= '2023-04-01'
  AND StartDateMotherDeliveryHospProvSpell < '2024-04-01'

UNION ALL

-- MSD101: Pregnancy Booking
SELECT
  'MSD101 - Pregnancy Booking' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT UniqPregID) AS unique_pregnancies,
  CAST(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT UniqPregID), 0) AS DECIMAL(5,2)) AS duplication_factor
FROM UDAL_Warehouse.MESH_MSDS.MSD101PregnancyBooking_1
WHERE AntenatalAppDate >= '2022-04-01'  -- Booking happens before birth
  AND AntenatalAppDate < '2024-04-01'

UNION ALL

-- MSD001: Mother Demographics
SELECT
  'MSD001 - Mother Demographics' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT Person_ID_Mother) AS unique_mothers,
  CAST(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT Person_ID_Mother), 0) AS DECIMAL(5,2)) AS duplication_factor
FROM UDAL_Warehouse.MESH_MSDS.MSD001MotherDemog_1

UNION ALL

-- MSD402: Neonatal Admission
SELECT
  'MSD402 - Neonatal Admission' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT Person_ID_Baby) AS unique_babies,
  CAST(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT Person_ID_Baby), 0) AS DECIMAL(5,2)) AS duplication_factor
FROM UDAL_Warehouse.MESH_MSDS.MSD402NeonatalAdmission_1;


-- ============================================================================
-- DIAGNOSTIC 5: Overlap Analysis - How many issues co-occur?
-- ============================================================================
-- Check if the same babies have multiple issues (helps prioritise fixes)

WITH babies_with_fy AS (
  SELECT
    Person_ID_Baby,
    Person_ID_Mother,
    OrgCodeProvider,
    CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END AS Birth_FY
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
),

babies_2324 AS (
  SELECT DISTINCT Person_ID_Baby, Person_ID_Mother, OrgCodeProvider
  FROM babies_with_fy
  WHERE Birth_FY = '2023/24'
),

baby_issues AS (
  SELECT
    Person_ID_Baby,
    MAX(CASE WHEN Person_ID_Baby LIKE 'U%' THEN 1 ELSE 0 END) AS has_unknown_id,
    CASE WHEN COUNT(DISTINCT Person_ID_Mother) > 1 THEN 1 ELSE 0 END AS has_multiple_mothers,
    CASE WHEN COUNT(DISTINCT OrgCodeProvider) > 1 THEN 1 ELSE 0 END AS has_multiple_orgs
  FROM babies_2324
  GROUP BY Person_ID_Baby
)

SELECT
  'Issue overlap summary' AS diagnostic,
  COUNT(*) AS total_babies,
  SUM(has_unknown_id) AS unknown_id_only,
  SUM(has_multiple_mothers) AS multiple_mothers_only,
  SUM(has_multiple_orgs) AS multiple_orgs_only,
  SUM(CASE WHEN has_multiple_mothers = 1 AND has_multiple_orgs = 1 THEN 1 ELSE 0 END) AS both_mother_and_org,
  SUM(CASE WHEN has_unknown_id = 0 AND has_multiple_mothers = 0 AND has_multiple_orgs = 0 THEN 1 ELSE 0 END) AS clean_records
FROM baby_issues;


-- ============================================================================
-- DIAGNOSTIC 6: Sample of babies with multiple mothers (for investigation)
-- ============================================================================
-- Look at actual examples to understand the data quality issue

WITH babies_with_fy AS (
  SELECT
    Person_ID_Baby,
    Person_ID_Mother,
    UniqPregID,
    OrgCodeProvider,
    UniqSubmissionID,
    DATEFROMPARTS(YearOfBirthBaby, MonthOfBirthBaby, ISNULL(MerOfBirthBaby, 1)) AS Birth_Date,
    CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END AS Birth_FY
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
),

multi_mother_babies AS (
  SELECT Person_ID_Baby
  FROM babies_with_fy
  WHERE Birth_FY = '2023/24'
  GROUP BY Person_ID_Baby
  HAVING COUNT(DISTINCT Person_ID_Mother) > 1
)

SELECT TOP 20
  b.Person_ID_Baby,
  b.Person_ID_Mother,
  b.UniqPregID,
  b.OrgCodeProvider,
  b.Birth_Date,
  b.UniqSubmissionID
FROM babies_with_fy b
INNER JOIN multi_mother_babies mm ON b.Person_ID_Baby = mm.Person_ID_Baby
WHERE b.Birth_FY = '2023/24'
ORDER BY b.Person_ID_Baby, b.UniqSubmissionID DESC;
