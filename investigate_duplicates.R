#!/usr/bin/env Rscript
# Investigate duplicate records in the dataset

suppressPackageStartupMessages({
  library(dplyr)
  library(bit64)
})

# Load data
data <- readRDS('data/ncc_base_dataset.rds')

cat("=== INVESTIGATING DUPLICATES ===\n\n")

# Get all duplicates
duplicates <- data %>%
  group_by(Person_ID_Baby) %>%
  filter(n() > 1) %>%
  arrange(Person_ID_Baby, Baby_Birth_Date, NCC_CC_First_Admission_Date)

cat("Total duplicate records:", nrow(duplicates), "\n")
cat("Unique babies with duplicates:", n_distinct(duplicates$Person_ID_Baby), "\n\n")

# Distribution of duplicates
dup_counts <- data %>%
  group_by(Person_ID_Baby) %>%
  summarise(n_records = n()) %>%
  filter(n_records > 1)

cat("Distribution of duplicate counts:\n")
print(table(dup_counts$n_records))
cat("\n")

# Examine a few examples in detail
cat("=== DETAILED EXAMPLES ===\n\n")

sample_babies <- head(unique(duplicates$Person_ID_Baby), 3)

for (baby_id in sample_babies) {
  cat("Baby ID:", baby_id, "\n")
  
  baby_records <- data %>%
    filter(Person_ID_Baby == baby_id) %>%
    select(Person_ID_Baby, Baby_Birth_Date, NCC_Admitted, 
           NCC_MSDS_Admitted, NCC_CC_Admitted,
           NCC_CC_First_Admission_Date, NCC_CC_Last_Discharge_Date,
           NCC_CC_Total_Days, NCC_CC_Number_Of_Periods,
           NCC_Hospital_Provider_Code, Delivery_Site_Code)
  
  print(baby_records)
  cat("\n")
}

# Are these duplicates due to multiple NCC admissions (multiple periods)?
cat("=== POSSIBLE CAUSE: MULTIPLE NCC PERIODS ===\n")

dup_ncc_periods <- duplicates %>%
  filter(NCC_CC_Admitted == 1) %>%
  group_by(Person_ID_Baby) %>%
  summarise(
    n_records = n(),
    n_distinct_periods = n_distinct(NCC_CC_Number_Of_Periods),
    periods_value = paste(unique(NCC_CC_Number_Of_Periods), collapse = ","),
    n_distinct_hospitals = n_distinct(NCC_Hospital_Provider_Code),
    hospitals = paste(unique(NCC_Hospital_Provider_Code), collapse = ",")
  )

cat("\nBabies with NCC admission and duplicates:\n")
print(head(dup_ncc_periods, 20))

cat("\n=== RECOMMENDATION ===\n")
cat("The dataset appears to have ", nrow(duplicates), " duplicate records for ", 
    n_distinct(duplicates$Person_ID_Baby), " babies.\n")
cat("This likely reflects multiple NCC admission periods or transfers between hospitals.\n")
cat("For survival analysis, you should:\n")
cat("1. Decide on the appropriate unit of analysis (first admission only? all admissions?)\n")
cat("2. Consider de-duplicating by keeping one record per baby\n")
cat("3. Or restructure as a multi-state model with multiple NCC episodes\n")
