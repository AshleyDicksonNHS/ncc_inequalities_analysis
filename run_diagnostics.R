# ==============================================================================
# Run Diagnostic Queries for NCC Base Dataset
# ==============================================================================
# Purpose: Execute diagnostic queries to assess data quality issues
#          identified from reviewing Databricks MSDS/HES linkage notebooks
# ==============================================================================

library(DBI)
library(odbc)

# Connect to database
cat("Connecting to UDAL Warehouse...\n")
con <- DBI::dbConnect(odbc(),
                      Driver = "ODBC Driver 17 for SQL Server",
                      Server = "udalsyndataprod.sql.azuresynapse.net",
                      Database = "UDAL_Warehouse",
                      UID = "ashley.dickson@udal.nhs.uk",
                      Authentication = "ActiveDirectoryInteractive",
                      Port = 1433)

cat("Connected successfully!\n\n")

# Read diagnostic queries
queries_file <- "diagnostic_queries.sql"
sql_content <- readLines(queries_file, warn = FALSE)
sql_content <- paste(sql_content, collapse = "\n")

# Split into individual queries (separated by semicolons at end of SELECT blocks)
# We'll run each diagnostic separately for cleaner output

# ==============================================================================
# DIAGNOSTIC 1: Babies with Multiple Mothers
# ==============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("DIAGNOSTIC 1: Babies with Multiple Mothers\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")

query1 <- "
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
FROM mother_counts
"

tryCatch({
  result1 <- dbGetQuery(con, query1)
  print(result1)
}, error = function(e) {
  cat("Error:", e$message, "\n")
})

cat("\n")

# ==============================================================================
# DIAGNOSTIC 2: Babies with Multiple Organisations
# ==============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("DIAGNOSTIC 2: Babies with Multiple Organisations\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")

query2 <- "
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
FROM org_counts
"

tryCatch({
  result2 <- dbGetQuery(con, query2)
  print(result2)
}, error = function(e) {
  cat("Error:", e$message, "\n")
})

cat("\n")

# ==============================================================================
# DIAGNOSTIC 3: Unknown Person IDs
# ==============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("DIAGNOSTIC 3: Unknown Person IDs\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")

query3 <- "
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
FROM babies_2324
"

tryCatch({
  result3 <- dbGetQuery(con, query3)
  print(result3)
}, error = function(e) {
  cat("Error:", e$message, "\n")
})

cat("\n")

# ==============================================================================
# DIAGNOSTIC 4: Duplication Rates by Table
# ==============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("DIAGNOSTIC 4: Duplication Rates by Table\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")

query4 <- "
SELECT
  'MSD401 - Baby Demographics' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT Person_ID_Baby) AS unique_keys,
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

SELECT
  'MSD301 - Labour & Delivery' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT LabourDeliveryID) AS unique_keys,
  CAST(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT LabourDeliveryID), 0) AS DECIMAL(5,2)) AS duplication_factor
FROM UDAL_Warehouse.MESH_MSDS.MSD301LabourDelivery_1
WHERE StartDateMotherDeliveryHospProvSpell >= '2023-04-01'
  AND StartDateMotherDeliveryHospProvSpell < '2024-04-01'

UNION ALL

SELECT
  'MSD001 - Mother Demographics' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT Person_ID_Mother) AS unique_keys,
  CAST(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT Person_ID_Mother), 0) AS DECIMAL(5,2)) AS duplication_factor
FROM UDAL_Warehouse.MESH_MSDS.MSD001MotherDemog_1

UNION ALL

SELECT
  'MSD402 - Neonatal Admission' AS table_name,
  COUNT(*) AS raw_records,
  COUNT(DISTINCT Person_ID_Baby) AS unique_keys,
  CAST(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT Person_ID_Baby), 0) AS DECIMAL(5,2)) AS duplication_factor
FROM UDAL_Warehouse.MESH_MSDS.MSD402NeonatalAdmission_1
"

tryCatch({
  result4 <- dbGetQuery(con, query4)
  print(result4)
}, error = function(e) {
  cat("Error:", e$message, "\n")
})

cat("\n")

# ==============================================================================
# DIAGNOSTIC 5: Issue Overlap Summary
# ==============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("DIAGNOSTIC 5: Issue Overlap Summary\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")

query5 <- "
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
  COUNT(*) AS total_babies,
  SUM(has_unknown_id) AS with_unknown_id,
  SUM(has_multiple_mothers) AS with_multiple_mothers,
  SUM(has_multiple_orgs) AS with_multiple_orgs,
  SUM(CASE WHEN has_multiple_mothers = 1 AND has_multiple_orgs = 1 THEN 1 ELSE 0 END) AS both_mother_and_org_issues,
  SUM(CASE WHEN has_unknown_id = 0 AND has_multiple_mothers = 0 AND has_multiple_orgs = 0 THEN 1 ELSE 0 END) AS clean_records,
  CAST(100.0 * SUM(CASE WHEN has_unknown_id = 0 AND has_multiple_mothers = 0 AND has_multiple_orgs = 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_clean
FROM baby_issues
"

tryCatch({
  result5 <- dbGetQuery(con, query5)
  print(result5)
}, error = function(e) {
  cat("Error:", e$message, "\n")
})

cat("\n")

# ==============================================================================
# DIAGNOSTIC 6: Sample of babies with multiple mothers
# ==============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("DIAGNOSTIC 6: Sample of Babies with Multiple Mothers\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")

query6 <- "
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
ORDER BY b.Person_ID_Baby, b.UniqSubmissionID DESC
"

tryCatch({
  result6 <- dbGetQuery(con, query6)
  print(result6, n = 20)
}, error = function(e) {
  cat("Error:", e$message, "\n")
})

# Disconnect
dbDisconnect(con)
cat("\n\nDiagnostics complete. Connection closed.\n")
