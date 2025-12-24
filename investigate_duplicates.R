# ==============================================================================
# INVESTIGATE DUPLICATE RECORDS IN MSD401BabyDemographics_1
# ==============================================================================
# Purpose: Understand HOW the duplicate records per baby differ
# This will inform the deduplication strategy
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
cat(rep("=", 80), "\n", sep = "")

# ==============================================================================
# STEP 1: Identify babies with multiple records
# ==============================================================================
cat("STEP 1: Finding babies with multiple records...\n")
cat(rep("-", 80), "\n", sep = "")

query_duplicates <- "
WITH baby_counts AS (
  SELECT
    Person_ID_Baby,
    COUNT(*) as record_count
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
  WHERE CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END = '2023/24'
  GROUP BY Person_ID_Baby
  HAVING COUNT(*) > 1
)
SELECT
  COUNT(*) as babies_with_duplicates,
  MIN(record_count) as min_records_per_baby,
  MAX(record_count) as max_records_per_baby,
  AVG(CAST(record_count AS FLOAT)) as avg_records_per_baby
FROM baby_counts
"

dup_stats <- dbGetQuery(con, query_duplicates)
cat("\nDuplicate Statistics:\n")
print(dup_stats)
cat("\n")

# ==============================================================================
# STEP 2: Get distribution of record counts
# ==============================================================================
cat("STEP 2: Distribution of record counts per baby...\n")
cat(rep("-", 80), "\n", sep = "")

query_distribution <- "
SELECT
  record_count,
  COUNT(*) as num_babies,
  CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) as percentage
FROM (
  SELECT
    Person_ID_Baby,
    COUNT(*) as record_count
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
  WHERE CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END = '2023/24'
  GROUP BY Person_ID_Baby
) counts
GROUP BY record_count
ORDER BY record_count
"

distribution <- dbGetQuery(con, query_distribution)
cat("\nRecords per baby distribution:\n")
print(distribution, row.names = FALSE)
cat("\n")

# ==============================================================================
# STEP 3: Sample duplicate records to see what differs
# ==============================================================================
cat("STEP 3: Examining sample duplicate records...\n")
cat(rep("-", 80), "\n", sep = "")

# Get a baby with exactly 2 records for easier comparison
query_sample_baby <- "
SELECT TOP 1 Person_ID_Baby
FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
WHERE CASE
    WHEN MonthOfBirthBaby >= 4
      THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                  RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
    ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
  END = '2023/24'
GROUP BY Person_ID_Baby
HAVING COUNT(*) = 2
"

sample_baby_id <- dbGetQuery(con, query_sample_baby)$Person_ID_Baby[1]
cat("Sample Baby ID (with 2 records):", sample_baby_id, "\n\n")

# Get all records for this baby - check what columns are available first
query_sample_records <- paste0("
SELECT TOP 10 *
FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
WHERE Person_ID_Baby = '", sample_baby_id, "'
")

sample_records <- dbGetQuery(con, query_sample_records)
cat("Number of records returned:", nrow(sample_records), "\n")
cat("Number of columns:", ncol(sample_records), "\n\n")

# Show which fields differ between the records
if (nrow(sample_records) >= 2) {
  cat("Comparing first two records to identify differing fields...\n\n")

  differing_fields <- data.frame(
    Field = character(),
    Record_1 = character(),
    Record_2 = character(),
    stringsAsFactors = FALSE
  )

  for (col_name in names(sample_records)) {
    val1 <- as.character(sample_records[1, col_name])
    val2 <- as.character(sample_records[2, col_name])

    # Replace NA with "NULL" for display
    val1 <- ifelse(is.na(val1), "NULL", val1)
    val2 <- ifelse(is.na(val2), "NULL", val2)

    if (val1 != val2) {
      differing_fields <- rbind(differing_fields,
                               data.frame(Field = col_name,
                                        Record_1 = val1,
                                        Record_2 = val2,
                                        stringsAsFactors = FALSE))
    }
  }

  cat("Fields that DIFFER between the two records:\n")
  cat(rep("-", 80), "\n", sep = "")
  if (nrow(differing_fields) > 0) {
    print(differing_fields, row.names = FALSE)
  } else {
    cat("No differing fields found - records appear identical!\n")
  }
  cat("\n")

  cat("Fields that are IDENTICAL:\n")
  cat(rep("-", 80), "\n", sep = "")
  identical_count <- ncol(sample_records) - nrow(differing_fields)
  cat("Total identical fields:", identical_count, "out of", ncol(sample_records), "\n\n")
}

# ==============================================================================
# STEP 4: Check key metadata fields across ALL duplicates
# ==============================================================================
cat("STEP 4: Analyzing metadata patterns across ALL duplicate records...\n")
cat(rep("-", 80), "\n", sep = "")

# Look for common metadata fields that might explain duplicates
# Typical suspects: RecordConnectionIdentifier, UniqSubmissionID, Der_Provider_Code, etc.

query_metadata_check <- "
WITH duplicates AS (
  SELECT Person_ID_Baby
  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1
  WHERE CASE
      WHEN MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(YearOfBirthBaby AS VARCHAR(4)), 2))
    END = '2023/24'
  GROUP BY Person_ID_Baby
  HAVING COUNT(*) > 1
)
SELECT
  d.Person_ID_Baby,
  COUNT(*) as num_records,
  COUNT(DISTINCT b.UniqPregID) as distinct_preg_ids,
  COUNT(DISTINCT b.LabourDeliveryID) as distinct_labour_ids,
  COUNT(DISTINCT b.OrgCodeProvider) as distinct_providers,
  COUNT(DISTINCT b.UniqSubmissionID) as distinct_submission_ids,
  -- Check if key clinical fields differ
  COUNT(DISTINCT b.YearOfBirthBaby) as distinct_birth_years,
  COUNT(DISTINCT b.MonthOfBirthBaby) as distinct_birth_months,
  COUNT(DISTINCT b.MerOfBirthBaby) as distinct_birth_days,
  COUNT(DISTINCT b.PersonBirthTimeBaby) as distinct_birth_times,
  COUNT(DISTINCT b.GestationLengthBirth) as distinct_gestation,
  COUNT(DISTINCT b.DeliveryMethodCode) as distinct_delivery_methods,
  COUNT(DISTINCT b.EthnicCategoryBaby) as distinct_ethnicity,
  COUNT(DISTINCT b.PersonPhenSex) as distinct_sex
FROM duplicates d
INNER JOIN UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1 b
  ON d.Person_ID_Baby = b.Person_ID_Baby
WHERE CASE
    WHEN b.MonthOfBirthBaby >= 4
      THEN CONCAT(CAST(b.YearOfBirthBaby AS VARCHAR(4)), '/',
                  RIGHT(CAST((CAST(b.YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
    ELSE CONCAT(CAST((CAST(b.YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                RIGHT(CAST(b.YearOfBirthBaby AS VARCHAR(4)), 2))
  END = '2023/24'
GROUP BY d.Person_ID_Baby
ORDER BY num_records DESC
"

cat("Getting metadata patterns (this may take a moment)...\n")
metadata_patterns <- dbGetQuery(con, query_metadata_check)

cat("\nSample of babies with duplicates (top 10 by record count):\n")
print(head(metadata_patterns, 10), row.names = FALSE)

# Summarize patterns
cat("\n")
cat(rep("-", 80), "\n", sep = "")
cat("PATTERN ANALYSIS:\n\n")

total_dup_babies <- nrow(metadata_patterns)

# Submission-level differences
diff_submissions <- sum(metadata_patterns$distinct_submission_ids > 1)
cat("Babies with DIFFERENT submission IDs:", diff_submissions,
    "(", round(100 * diff_submissions / total_dup_babies, 1), "%)\n")

# What proportion have different providers?
diff_providers <- sum(metadata_patterns$distinct_providers > 1)
cat("Babies with records from DIFFERENT providers:", diff_providers,
    "(", round(100 * diff_providers / total_dup_babies, 1), "%)\n")

# What proportion have different pregnancy IDs?
diff_preg <- sum(metadata_patterns$distinct_preg_ids > 1)
cat("Babies with DIFFERENT pregnancy IDs:", diff_preg,
    "(", round(100 * diff_preg / total_dup_babies, 1), "%)\n")

# What proportion have different labour IDs?
diff_labour <- sum(metadata_patterns$distinct_labour_ids > 1)
cat("Babies with DIFFERENT labour/delivery IDs:", diff_labour,
    "(", round(100 * diff_labour / total_dup_babies, 1), "%)\n")

cat("\n")
cat("CLINICAL DATA VARIATIONS:\n")
# What proportion have different clinical data?
diff_gestation <- sum(metadata_patterns$distinct_gestation > 1, na.rm = TRUE)
cat("Babies with DIFFERENT gestation values:", diff_gestation,
    "(", round(100 * diff_gestation / total_dup_babies, 1), "%)\n")

diff_delivery <- sum(metadata_patterns$distinct_delivery_methods > 1, na.rm = TRUE)
cat("Babies with DIFFERENT delivery methods:", diff_delivery,
    "(", round(100 * diff_delivery / total_dup_babies, 1), "%)\n")

diff_ethnicity <- sum(metadata_patterns$distinct_ethnicity > 1, na.rm = TRUE)
cat("Babies with DIFFERENT ethnicity values:", diff_ethnicity,
    "(", round(100 * diff_ethnicity / total_dup_babies, 1), "%)\n")

diff_sex <- sum(metadata_patterns$distinct_sex > 1, na.rm = TRUE)
cat("Babies with DIFFERENT sex values:", diff_sex,
    "(", round(100 * diff_sex / total_dup_babies, 1), "%)\n")

# ==============================================================================
# STEP 5: Recommendation for deduplication strategy
# ==============================================================================
cat("\n")
cat(rep("=", 80), "\n", sep = "")
cat("RECOMMENDED DEDUPLICATION STRATEGY:\n")
cat(rep("=", 80), "\n", sep = "")

cat("\nBased on the analysis above:\n\n")

if (diff_submissions / total_dup_babies > 0.9 &&
    (diff_gestation / total_dup_babies < 0.1) &&
    (diff_delivery / total_dup_babies < 0.1)) {
  cat("→ LIKELY CAUSE: Multiple submissions of IDENTICAL clinical data\n")
  cat("  The duplicates are from different UniqSubmissionID but clinical data is the same\n\n")
  cat("RECOMMENDATION:\n")
  cat("  Since clinical data is consistent, use simple ROW_NUMBER to pick ONE record:\n")
  cat("  - ORDER BY UniqSubmissionID DESC (most recent submission)\n")
  cat("  - OR ORDER BY LabourDeliveryID (consistent arbitrary choice)\n")
  cat("  This is safe because the clinical values don't differ!\n")
} else if (diff_providers / total_dup_babies > 0.5) {
  cat("→ LIKELY CAUSE: Multiple provider submissions with some data variations\n")
  cat("  (e.g., baby transferred between trusts, corrections in later submissions)\n\n")
  cat("RECOMMENDATION:\n")
  cat("  Use ROW_NUMBER with ORDER BY that prioritizes:\n")
  cat("  1. Most recent submission (UniqSubmissionID DESC)\n")
  cat("  2. Delivering organization (OrgSiteIDActualDelivery)\n")
  cat("  3. Most complete record (non-NULL key fields)\n")
} else if (diff_labour / total_dup_babies > 0.3) {
  cat("→ LIKELY CAUSE: Multiple labour/delivery episodes linked to same baby\n")
  cat("  (e.g., complex births, data quality issue)\n\n")
  cat("RECOMMENDATION:\n")
  cat("  Use ROW_NUMBER with ORDER BY LabourDeliveryID to pick first/primary birth\n")
} else {
  cat("→ MIXED CAUSES - submission duplicates with some clinical variations\n\n")
  cat("RECOMMENDATION:\n")
  cat("  Check the 'differing fields' output above\n")
  cat("  Use ROW_NUMBER ORDER BY UniqSubmissionID DESC (most recent)\n")
}

cat("\nExample ROW_NUMBER approach:\n")
cat("----------------------------\n")
cat("ROW_NUMBER() OVER (\n")
cat("  PARTITION BY Person_ID_Baby\n")
cat("  ORDER BY \n")
cat("    UniqSubmissionID DESC,    -- Most recent submission\n")
cat("    LabourDeliveryID          -- Consistent tiebreaker\n")
cat(") as rn\n")

cat("\n")
cat(rep("=", 80), "\n", sep = "")

# Disconnect
dbDisconnect(con)
cat("\nDatabase connection closed.\n")
