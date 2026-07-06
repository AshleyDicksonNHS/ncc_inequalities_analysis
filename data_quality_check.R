#!/usr/bin/env Rscript
# Data Quality Assessment Script

suppressPackageStartupMessages({
  library(dplyr)
  library(bit64)
})

# Load data
cat("Loading dataset...\n")
data <- readRDS('data/ncc_base_dataset.rds')

cat("\n=== DATASET STRUCTURE ===\n")
cat("Total rows:", nrow(data), "\n")
cat("Total columns:", ncol(data), "\n\n")

cat("=== COLUMN NAMES ===\n")
print(names(data))

cat("\n=== FIRST FEW ROWS ===\n")
print(head(data, 3))

cat("\n=== DATA COMPLETENESS ===\n")
missing_summary <- data.frame(
  Column = names(data),
  Missing_Count = sapply(data, function(x) sum(is.na(x))),
  Missing_Pct = sapply(data, function(x) round(100 * sum(is.na(x)) / length(x), 2))
)
missing_summary <- missing_summary[order(-missing_summary$Missing_Count), ]
print(missing_summary, row.names = FALSE)

cat("\n=== DUPLICATE CHECK ===\n")

# Check for duplicate Person_ID_Baby
if ("Person_ID_Baby" %in% names(data)) {
  total_babies <- nrow(data)
  unique_babies <- data %>% distinct(Person_ID_Baby) %>% nrow()
  cat("Total records:", total_babies, "\n")
  cat("Unique Person_ID_Baby:", unique_babies, "\n")
  cat("Duplicate babies:", total_babies - unique_babies, "\n\n")

  if (total_babies > unique_babies) {
    cat("Finding duplicates...\n")
    duplicates <- data %>%
      group_by(Person_ID_Baby) %>%
      filter(n() > 1) %>%
      arrange(Person_ID_Baby)

    cat("Number of babies with duplicates:", n_distinct(duplicates$Person_ID_Baby), "\n")
    cat("Total duplicate records:", nrow(duplicates), "\n\n")

    cat("Sample of duplicates (first 20 rows):\n")
    print(head(duplicates %>% select(Person_ID_Baby, Baby_Birth_Date, NCC_Admitted,
                                      NCC_MSDS_Admitted, NCC_CC_Admitted,
                                      NCC_In_Both_Sources), 20))
  }
}

cat("\n=== KEY OUTCOME VARIABLES ===\n")
if ("NCC_Admitted" %in% names(data)) {
  cat("NCC_Admitted:\n")
  print(table(data$NCC_Admitted, useNA = "ifany"))
  cat("\nNCC admission rate:", round(100 * mean(data$NCC_Admitted == 1, na.rm = TRUE), 2), "%\n")
}

if ("NCC_MSDS_Admitted" %in% names(data)) {
  cat("\nNCC_MSDS_Admitted:\n")
  print(table(data$NCC_MSDS_Admitted, useNA = "ifany"))
}

if ("NCC_CC_Admitted" %in% names(data)) {
  cat("\nNCC_CC_Admitted:\n")
  print(table(data$NCC_CC_Admitted, useNA = "ifany"))
}

if ("NCC_In_Both_Sources" %in% names(data)) {
  cat("\nNCC_In_Both_Sources:\n")
  print(table(data$NCC_In_Both_Sources, useNA = "ifany"))
}

cat("\n=== KEY PREDICTOR VARIABLES ===\n")

# Gestation
if ("Gestation_Length_At_Birth" %in% names(data)) {
  cat("\nGestation_Length_At_Birth:\n")
  gestation_weeks <- as.numeric(data$Gestation_Length_At_Birth) / 7
  cat("Summary (in weeks):\n")
  print(summary(gestation_weeks))
  cat("Missing:", sum(is.na(gestation_weeks)), "\n")
}

# Birth weight
if ("Birth_Weight" %in% names(data)) {
  cat("\nBirth_Weight:\n")
  print(summary(data$Birth_Weight))
  cat("Missing:", sum(is.na(data$Birth_Weight)), "\n")
}

# Ethnicity
if ("Ethnic_Category_Baby" %in% names(data)) {
  cat("\nEthnic_Category_Baby (top 10):\n")
  print(head(sort(table(data$Ethnic_Category_Baby, useNA = "ifany"), decreasing = TRUE), 10))
}

cat("\n=== FINANCIAL YEAR BREAKDOWN ===\n")
if ("Financial_Year" %in% names(data)) {
  fy_summary <- data %>%
    group_by(Financial_Year) %>%
    summarise(
      Total_Births = n(),
      NCC_Admissions = sum(NCC_Admitted == 1, na.rm = TRUE),
      NCC_Rate_Pct = round(100 * mean(NCC_Admitted == 1, na.rm = TRUE), 2)
    ) %>%
    arrange(Financial_Year)

  print(fy_summary)
}

cat("\n=== ASSESSMENT COMPLETE ===\n")
