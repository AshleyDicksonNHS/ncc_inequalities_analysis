# ==============================================================================
# TEST TABLE RECORD COUNTS
# ==============================================================================
# Purpose: Identify which table should be the base table by counting
#          unique records at various levels of granularity
# Expected: ~600k babies born in hospital per financial year (500k-700k range)
# ==============================================================================

library(DBI)
library(odbc)
library(tidyverse)

# Connect to database
cat("Connecting to database...\n")
con <- DBI::dbConnect(odbc(),
                      Driver = "ODBC Driver 17 for SQL Server",
                      Server = "udalsyndataprod.sql.azuresynapse.net",
                      Database = "UDAL_Warehouse",
                      UID = "ashley.dickson@udal.nhs.uk",
                      Authentication = "ActiveDirectoryInteractive",
                      Port = 1433)

cat("Connected successfully!\n\n")

# Financial year to test
fin_year <- "2023/24"
cat("Testing financial year:", fin_year, "\n")
cat("Expected births in hospital: ~500k-700k\n")
cat(rep("=", 80), "\n\n", sep = "")

# ==============================================================================
# TABLE 1: MSD401BabyDemographics_1 (Supposed base table)
# ==============================================================================
cat("TABLE 1: MSD401BabyDemographics_1 (Baby Demographics)\n")
cat(rep("-", 80), "\n", sep = "")

query_msd401 <- "
SELECT
  COUNT(*) AS total_records,
  COUNT(DISTINCT Person_ID_Baby) AS unique_person_id_baby,
  COUNT(DISTINCT pseudo_nhs_number_ncdr_baby) AS unique_nhs_number,
  COUNT(DISTINCT LabourDeliveryID) AS unique_labour_delivery_id,
  COUNT(DISTINCT UniqPregID) AS unique_pregnancy_id,
  COUNT(DISTINCT Person_ID_Mother) AS unique_mothers,
  COUNT(DISTINCT CONCAT(Person_ID_Baby, '_', LabourDeliveryID)) AS unique_baby_labour_combos
FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
WHERE CASE
    WHEN MonthOfBirthBaby >= 4
      THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                  RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
    ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
  END = '2023/24'
"

result_msd401 <- dbGetQuery(con, query_msd401)
print(result_msd401)
cat("\n")

# ==============================================================================
# TABLE 2: MSD301LabourDelivery_1 (Labour and Delivery)
# ==============================================================================
cat("TABLE 2: MSD301LabourDelivery_1 (Labour and Delivery)\n")
cat(rep("-", 80), "\n", sep = "")

query_msd301 <- "
SELECT
  COUNT(*) AS total_records,
  COUNT(DISTINCT LabourDeliveryID) AS unique_labour_delivery_id,
  COUNT(DISTINCT UniqPregID) AS unique_pregnancy_id,
  COUNT(DISTINCT Person_ID_Mother) AS unique_mothers
FROM UDAL_Warehouse.MESH_MSDS.MSD301LabourDelivery_1
WHERE StartDateMotherDeliveryHospProvSpell >= '2023-04-01'
  AND StartDateMotherDeliveryHospProvSpell < '2024-04-01'
"

result_msd301 <- dbGetQuery(con, query_msd301)
print(result_msd301)
cat("\n")

# ==============================================================================
# TABLE 3: MSD101PregnancyBooking_1 (Pregnancy and Booking)
# ==============================================================================
cat("TABLE 3: MSD101PregnancyBooking_1 (Pregnancy and Booking)\n")
cat(rep("-", 80), "\n", sep = "")

query_msd101 <- "
SELECT
  COUNT(*) AS total_records,
  COUNT(DISTINCT UniqPregID) AS unique_pregnancy_id,
  COUNT(DISTINCT Person_ID_Mother) AS unique_mothers
FROM UDAL_Warehouse.MESH_MSDS.MSD101PregnancyBooking_1
WHERE EDDAgreed >= '2023-04-01'
  AND EDDAgreed < '2024-04-01'
"

result_msd101 <- dbGetQuery(con, query_msd101)
print(result_msd101)
cat("\n")

# ==============================================================================
# TABLE 4: MSD001MotherDemog_1 (Mother Demographics)
# ==============================================================================
cat("TABLE 4: MSD001MotherDemog_1 (Mother Demographics)\n")
cat(rep("-", 80), "\n", sep = "")

query_msd001 <- "
SELECT
  COUNT(*) AS total_records,
  COUNT(DISTINCT Person_ID_Mother) AS unique_mothers
FROM UDAL_Warehouse.MESH_MSDS.MSD001MotherDemog_1
"

result_msd001 <- dbGetQuery(con, query_msd001)
cat("Note: This table has no date field, showing ALL records\n")
print(result_msd001)
cat("\n")

# ==============================================================================
# TABLE 5: MSD402NeonatalAdmission_1 (Neonatal Admissions)
# ==============================================================================
cat("TABLE 5: MSD402NeonatalAdmission_1 (Neonatal Admissions)\n")
cat(rep("-", 80), "\n", sep = "")

query_msd402 <- "
SELECT
  COUNT(*) AS total_records,
  COUNT(DISTINCT Person_ID_Baby) AS unique_babies,
  COUNT(DISTINCT UniqPregID) AS unique_pregnancy_id
FROM UDAL_Warehouse.MESH_MSDS.MSD402NeonatalAdmission_1
WHERE NeonatalTransferStartDate >= '2023-04-01'
  AND NeonatalTransferStartDate < '2024-04-01'
"

result_msd402 <- dbGetQuery(con, query_msd402)
cat("Note: This table only contains babies with neonatal admissions\n")
print(result_msd402)
cat("\n")

# ==============================================================================
# TABLE 6: Pbr_CC_Monthly (Critical Care - NCC records)
# ==============================================================================
cat("TABLE 6: MESH_APC.Pbr_CC_Monthly (Critical Care - NCC only)\n")
cat(rep("-", 80), "\n", sep = "")

query_pbr_cc <- "
SELECT
  COUNT(*) AS total_records,
  COUNT(DISTINCT APCS_Ident) AS unique_apcs_ident,
  COUNT(DISTINCT CC_Period_Number) AS unique_cc_periods,
  COUNT(DISTINCT CONCAT(APCS_Ident, '_', CC_Period_Number)) AS unique_apcs_period_combos,
  COUNT(DISTINCT Der_Provider_Code) AS unique_providers
FROM UDAL_Warehouse.MESH_APC.Pbr_CC_Monthly
WHERE CC_Type = 'NCC'
  AND Der_Financial_Year = '2023/24'
"

result_pbr_cc <- dbGetQuery(con, query_pbr_cc)
cat("Note: This table is at DAILY level (one record per day of CC stay)\n")
print(result_pbr_cc)
cat("\n")

# ==============================================================================
# TABLE 7: APCS_Core_Daily (APCS Spell Data)
# ==============================================================================
cat("TABLE 7: MESH_APC.APCS_Core_Daily (APCS Spell Data)\n")
cat(rep("-", 80), "\n", sep = "")

query_apcs <- "
SELECT
  COUNT(*) AS total_records,
  COUNT(DISTINCT APCS_Ident) AS unique_apcs_ident,
  COUNT(DISTINCT Hospital_Spell_No) AS unique_spell_numbers,
  COUNT(DISTINCT Der_Pseudo_NHS_Number) AS unique_nhs_numbers,
  COUNT(DISTINCT CONCAT(APCS_Ident, '_', Hospital_Spell_No)) AS unique_apcs_spell_combos
FROM UDAL_Warehouse.MESH_APC.APCS_Core_Daily
WHERE Der_Financial_Year = '2023/24'
"

result_apcs <- dbGetQuery(con, query_apcs)
cat("Note: This table is at DAILY level (one record per day of hospital spell)\n")
print(result_apcs)
cat("\n")

# ==============================================================================
# CROSS-TABLE COMPARISONS
# ==============================================================================
cat(rep("=", 80), "\n", sep = "")
cat("CROSS-TABLE COMPARISON\n")
cat(rep("=", 80), "\n", sep = "")

# Check how many babies in MSD401 link to MSD301 (Labour/Delivery)
cat("Linkage Test 1: Babies in MSD401 with Labour/Delivery records\n")
cat(rep("-", 80), "\n", sep = "")

query_cross1 <- "
WITH babies AS (
  SELECT Person_ID_Baby, LabourDeliveryID, UniqPregID
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
  WHERE CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END = '2023/24'
),
labour AS (
  SELECT LabourDeliveryID
  FROM UDAL_Warehouse.MESH_MSDS.MSD301LabourDelivery_1
  WHERE StartDateMotherDeliveryHospProvSpell >= '2023-04-01'
    AND StartDateMotherDeliveryHospProvSpell < '2024-04-01'
)
SELECT
  COUNT(DISTINCT b.Person_ID_Baby) AS total_babies_in_msd401,
  COUNT(DISTINCT CASE WHEN l.LabourDeliveryID IS NOT NULL THEN b.Person_ID_Baby END) AS babies_with_labour_record,
  COUNT(DISTINCT CASE WHEN l.LabourDeliveryID IS NULL THEN b.Person_ID_Baby END) AS babies_without_labour_record
FROM babies b
LEFT JOIN labour l ON b.LabourDeliveryID = l.LabourDeliveryID
"

result_cross1 <- dbGetQuery(con, query_cross1)
print(result_cross1)

babies_total <- result_cross1$total_babies_in_msd401
babies_with_labour <- result_cross1$babies_with_labour_record
babies_without_labour <- result_cross1$babies_without_labour_record

cat("Percentage of babies WITH labour record:",
    round(100 * babies_with_labour / babies_total, 1), "%\n")
cat("Percentage of babies WITHOUT labour record:",
    round(100 * babies_without_labour / babies_total, 1), "%\n\n")

# Check aggregation from PbR_CC_Monthly to unique APCS_Ident level
cat("Linkage Test 2: PbR_CC_Monthly aggregation to unique babies\n")
cat(rep("-", 80), "\n", sep = "")

query_cross2 <- "
SELECT
  COUNT(DISTINCT APCS_Ident) AS unique_apcs_idents_in_ncc,
  AVG(CAST(days_per_apcs AS FLOAT)) AS avg_days_per_apcs_ident,
  MAX(days_per_apcs) AS max_days_per_apcs_ident
FROM (
  SELECT
    APCS_Ident,
    COUNT(*) AS days_per_apcs
  FROM UDAL_Warehouse.MESH_APC.Pbr_CC_Monthly
  WHERE CC_Type = 'NCC'
    AND Der_Financial_Year = '2023/24'
  GROUP BY APCS_Ident
) sub
"

result_cross2 <- dbGetQuery(con, query_cross2)
print(result_cross2)
cat("\n")

# ==============================================================================
# SUMMARY AND RECOMMENDATION
# ==============================================================================
cat(rep("=", 80), "\n", sep = "")
cat("SUMMARY AND RECOMMENDATION\n")
cat(rep("=", 80), "\n", sep = "")

cat("\nExpected births in hospital: ~500k-700k\n\n")

# Create summary table
summary_table <- data.frame(
  Table = c(
    "MSD401 (Baby Demographics)",
    "MSD301 (Labour/Delivery)",
    "MSD101 (Pregnancy/Booking)",
    "MSD001 (Mother Demographics)",
    "MSD402 (Neonatal Admissions)",
    "Pbr_CC_Monthly (NCC only)",
    "APCS_Core_Daily (All spells)"
  ),
  Total_Records = c(
    result_msd401$total_records,
    result_msd301$total_records,
    result_msd101$total_records,
    result_msd001$total_records,
    result_msd402$total_records,
    result_pbr_cc$total_records,
    result_apcs$total_records
  ),
  Key_Unique_Count = c(
    result_msd401$unique_person_id_baby,
    result_msd301$unique_labour_delivery_id,
    result_msd101$unique_pregnancy_id,
    result_msd001$unique_mothers,
    result_msd402$unique_babies,
    result_pbr_cc$unique_apcs_ident,
    result_apcs$unique_apcs_ident
  ),
  Granularity = c(
    "Person_ID_Baby",
    "LabourDeliveryID",
    "UniqPregID",
    "Person_ID_Mother",
    "Person_ID_Baby",
    "APCS_Ident",
    "APCS_Ident"
  )
)

print(summary_table, row.names = FALSE)

cat("\n")
cat(rep("-", 80), "\n", sep = "")
cat("ANALYSIS:\n\n")

# Check MSD401
cat("MSD401 (Baby Demographics):\n")
cat("  - Total records:", format(result_msd401$total_records, big.mark = ","), "\n")
cat("  - Unique babies (Person_ID_Baby):", format(result_msd401$unique_person_id_baby, big.mark = ","), "\n")

if (result_msd401$total_records == result_msd401$unique_person_id_baby) {
  cat("  ✓ ONE RECORD PER BABY (total = unique Person_ID_Baby)\n")
} else {
  cat("  ✗ MULTIPLE RECORDS PER BABY (total ≠ unique Person_ID_Baby)\n")
  cat("  → Average records per baby:", round(result_msd401$total_records / result_msd401$unique_person_id_baby, 2), "\n")
}

if (result_msd401$unique_person_id_baby >= 500000 && result_msd401$unique_person_id_baby <= 700000) {
  cat("  ✓ UNIQUE BABY COUNT IN EXPECTED RANGE (500k-700k)\n")
} else {
  cat("  ✗ UNIQUE BABY COUNT OUTSIDE EXPECTED RANGE\n")
}

cat("\nMSD301 (Labour/Delivery):\n")
cat("  - Total records:", format(result_msd301$total_records, big.mark = ","), "\n")
cat("  - Unique LabourDeliveryID:", format(result_msd301$unique_labour_delivery_id, big.mark = ","), "\n")

if (result_msd301$total_records == result_msd301$unique_labour_delivery_id) {
  cat("  ✓ ONE RECORD PER LABOUR/DELIVERY\n")
} else {
  cat("  ✗ MULTIPLE RECORDS PER LABOUR/DELIVERY\n")
}

cat("\n")
cat(rep("=", 80), "\n", sep = "")
cat("RECOMMENDATION:\n")

# Determine which table should be base
if (result_msd401$unique_person_id_baby >= 500000 &&
    result_msd401$unique_person_id_baby <= 700000 &&
    result_msd401$total_records == result_msd401$unique_person_id_baby) {
  cat("✓ MSD401BabyDemographics_1 IS the correct base table\n")
  cat("  It has one record per baby with counts in expected range\n")
} else if (result_msd401$unique_person_id_baby >= 500000 &&
           result_msd401$unique_person_id_baby <= 700000) {
  cat("⚠ MSD401BabyDemographics_1 has correct UNIQUE count but multiple records per baby\n")
  cat("  Consider using DISTINCT or GROUP BY on Person_ID_Baby\n")
} else {
  cat("✗ MSD401BabyDemographics_1 may NOT be the correct base table\n")
  cat("  Unique baby count is outside expected range\n")
  cat("\nInvestigate:\n")
  cat("  1. Are we filtering correctly for hospital births?\n")
  cat("  2. Should we be using a different table?\n")
  cat("  3. Are there multiple births/twins counted separately?\n")
  cat("  4. Does the Labour/Delivery table have the right granularity?\n")
}

cat(rep("=", 80), "\n", sep = "")

# Disconnect
dbDisconnect(con)
cat("\nDatabase connection closed.\n")
