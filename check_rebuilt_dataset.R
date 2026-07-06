# ============================================================================
# Sanity check on the rebuilt ncc_base_dataset.rds
# ============================================================================
# Run with:  Rscript check_rebuilt_dataset.R
# Checks:
#   1. One row per baby (no spell multiplication)
#   2. NCC rate is in the expected range (~11-12%)
#   3. FY-window widening picked up additional CC records
#   4. Baby_Birth_Date is now NULL (per SQL fix)
#   5. NCC_CC_Number_Of_Spells distribution looks plausible
#   6. Headline counts haven't moved unexpectedly
# ============================================================================

library(tidyverse)

ncc <- readRDS("data/ncc_base_dataset.rds")

cat("================================================================\n")
cat("REBUILT DATASET SANITY CHECK\n")
cat("================================================================\n\n")

# --- Row count and dedup ---------------------------------------------------
n_rows  <- nrow(ncc)
n_babies <- dplyr::n_distinct(ncc$Person_ID_Baby)

cat("Total rows:             ", format(n_rows,  big.mark = ","), "\n")
cat("Distinct Person_ID_Baby:", format(n_babies, big.mark = ","), "\n")
cat("Dedup OK?               ", ifelse(n_rows == n_babies, "YES", "NO — duplicates remain"), "\n\n")

if (n_rows != n_babies) {
  dup_dist <- ncc %>% count(Person_ID_Baby, name = "n_rows") %>% count(n_rows, name = "n_babies")
  cat("Rows-per-baby (should all be 1):\n")
  print(dup_dist)
  cat("\n")
}

# --- NCC admission rate ----------------------------------------------------
ncc_rate <- mean(ncc$NCC_Admitted, na.rm = TRUE)
n_admitted <- sum(ncc$NCC_Admitted, na.rm = TRUE)

cat("NCC admissions (any source):", format(n_admitted, big.mark = ","),
    " (", sprintf("%.2f%%", 100 * ncc_rate), ")\n", sep = "")
cat("Expected: ~11-12% post-dedup. ",
    ifelse(ncc_rate > 0.10 & ncc_rate < 0.13, "Looks OK.", "OUT OF RANGE — investigate."), "\n\n")

# --- Source breakdown ------------------------------------------------------
cat("NCC by source (data quality check):\n")
src <- ncc %>%
  filter(NCC_Admitted == 1) %>%
  summarise(
    msds_only  = sum(NCC_MSDS_Admitted == 1 & (is.na(NCC_CC_Admitted) | NCC_CC_Admitted == 0), na.rm = TRUE),
    cc_only    = sum((is.na(NCC_MSDS_Admitted) | NCC_MSDS_Admitted == 0) & NCC_CC_Admitted == 1, na.rm = TRUE),
    both       = sum(NCC_MSDS_Admitted == 1 & NCC_CC_Admitted == 1, na.rm = TRUE)
  )
print(src)
cat("\n")

# --- Multi-spell distribution (new column) ---------------------------------
if ("NCC_CC_Number_Of_Spells" %in% names(ncc)) {
  cat("NCC_CC_Number_Of_Spells (admitted babies, CC source):\n")
  print(table(ncc$NCC_CC_Number_Of_Spells, useNA = "ifany"))
  cat("\n")
} else {
  cat("Column NCC_CC_Number_Of_Spells not present — SQL change may not have applied.\n\n")
}

# --- Baby_Birth_Date should now be NULL ------------------------------------
non_null_dob <- sum(!is.na(ncc$Baby_Birth_Date))
cat("Non-NULL Baby_Birth_Date rows:", non_null_dob,
    ifelse(non_null_dob == 0, "  — OK, broken date is gone.",
           "  — NOT EXPECTED, check SQL."), "\n\n")

# --- Financial year ---------------------------------------------------------
cat("Births by financial year (cohort filter):\n")
print(table(ncc$Baby_Birth_Financial_Year, useNA = "ifany"))
cat("\n")

# --- Delivery sites ---------------------------------------------------------
n_sites <- dplyr::n_distinct(ncc$Delivery_Site_Code, na.rm = TRUE)
cat("Distinct Delivery_Site_Code values:", n_sites, "\n")
cat("Births per site (5-number summary):\n")
print(summary(ncc %>% count(Delivery_Site_Code) %>% pull(n)))
cat("\n")

# --- Ethnicity coverage -----------------------------------------------------
cat("Ethnic_Category_Baby distribution (top values):\n")
print(sort(table(ncc$Ethnic_Category_Baby, useNA = "ifany"), decreasing = TRUE)[1:12])
cat("\n")

# --- IMD coverage -----------------------------------------------------------
cat("IMD_Decile_2015 distribution:\n")
print(table(ncc$IMD_Decile_2015, useNA = "ifany"))
cat("\n")

# --- Birth weight / gestation availability ---------------------------------
cat("Clinical covariate completeness:\n")
cat(sprintf("  Gestation_Length_At_Birth non-NA: %.1f%%\n",
            100 * mean(!is.na(ncc$Gestation_Length_At_Birth))))
cat(sprintf("  Birth_Weight_Grams non-NA:        %.1f%%\n",
            100 * mean(!is.na(ncc$Birth_Weight_Grams))))
cat(sprintf("  Apgar_Score_5_Minutes non-NA:     %.1f%%\n",
            100 * mean(!is.na(ncc$Apgar_Score_5_Minutes))))

cat("\n================================================================\n")
cat("Done. Pipe this output back if anything looks off.\n")
cat("================================================================\n")
