#!/usr/bin/env Rscript
# Check record counts and data quality indicators

suppressPackageStartupMessages({
  library(dplyr)
  library(bit64)
})

data <- readRDS('data/ncc_base_dataset.rds')

cat("=== FINANCIAL YEAR BREAKDOWN ===\n")
fy_summary <- data %>%
  group_by(Baby_Birth_Financial_Year) %>%
  summarise(
    Total_Births = n(),
    NCC_Admissions = sum(NCC_Admitted == 1, na.rm = TRUE),
    NCC_Rate_Pct = round(100 * mean(NCC_Admitted == 1, na.rm = TRUE), 2)
  ) %>%
  arrange(Baby_Birth_Financial_Year)

print(fy_summary)

cat("\n=== DATA SOURCE CONCORDANCE ===\n")
source_table <- table(
  MSDS = data$NCC_MSDS_Admitted,
  CC = data$NCC_CC_Admitted,
  useNA = "no"
)
print(source_table)

cat("\nInterpretation:\n")
cat("- Both sources agree baby NOT in NCC:", source_table["0", "0"], "\n")
cat("- Both sources agree baby WAS in NCC:", source_table["1", "1"], "\n")
cat("- Only in MSDS (not in CC):", source_table["1", "0"], "\n")
cat("- Only in CC (not in MSDS):", source_table["0", "1"], "\n")

cat("\n=== KEY COVARIATES COMPLETENESS ===\n")

key_vars <- c(
  "Gestation_Length_At_Birth",
  "Baby_Sex",
  "Ethnic_Category_Baby",
  "Ethnic_Category_Mother",
  "Delivery_Method_Code",
  "Previous_Live_Births",
  "Previous_Caesareans",
  "Mother_CCG_Residence",
  "Disability_Indicator_At_Antenatal_Booking",
  "Complex_Social_Factors_Indicator_At_Antenatal_Booking",
  "Employment_Status_Mother_At_Antenatal_Booking"
)

completeness <- data.frame(
  Variable = key_vars,
  Complete_N = sapply(key_vars, function(v) sum(!is.na(data[[v]]))),
  Complete_Pct = sapply(key_vars, function(v) round(100 * mean(!is.na(data[[v]])), 1))
)

print(completeness, row.names = FALSE)

cat("\n=== TIMING VARIABLES ===\n")
cat("Hours from birth to NCC (MSDS source):\n")
print(summary(data$Hours_Birth_To_NCC_MSDS))

cat("\nHours from birth to NCC (CC source):\n")
print(summary(data$Hours_Birth_To_NCC_CC))

cat("\nNCC total days (from CC):\n")
print(summary(data$NCC_CC_Total_Days))

cat("\n=== UNUSUAL VALUES CHECK ===\n")
cat("Gestation > 42 weeks (294 days):", sum(data$Gestation_Length_At_Birth > 294, na.rm = TRUE), "\n")
cat("Gestation < 20 weeks (140 days):", sum(data$Gestation_Length_At_Birth < 140, na.rm = TRUE), "\n")
cat("Birth year extracted from dates:\n")
birth_years <- as.integer(format(data$Baby_Birth_Date, "%Y"))
print(table(birth_years, useNA = "ifany"))
