# ==============================================================================
# ANALYZE NCC ADMISSION SOURCE DISCREPANCIES
# ==============================================================================
# Purpose: Understand differences between MSDS and CC sources for NCC admissions
# ==============================================================================

library(tidyverse)

# Load the dataset
cat("Loading dataset...\n")
data <- readRDS("data/ncc_base_dataset.rds")

cat("\n")
cat(rep("=", 80), "\n", sep = "")
cat("NCC ADMISSION SOURCE COMPARISON\n")
cat(rep("=", 80), "\n", sep = "")

# Overall summary
cat("\nTotal babies in dataset:", format(nrow(data), big.mark = ","), "\n\n")

# Create source breakdown
cat("NCC ADMISSION BY SOURCE:\n")
cat(rep("-", 80), "\n", sep = "")

ncc_breakdown <- data %>%
  mutate(
    NCC_Source = case_when(
      NCC_MSDS_Admitted == 1 & NCC_CC_Admitted == 1 ~ "Both MSDS & CC",
      NCC_MSDS_Admitted == 1 & (is.na(NCC_CC_Admitted) | NCC_CC_Admitted == 0) ~ "MSDS only",
      (is.na(NCC_MSDS_Admitted) | NCC_MSDS_Admitted == 0) & NCC_CC_Admitted == 1 ~ "CC only",
      TRUE ~ "Not admitted to NCC"
    )
  ) %>%
  count(NCC_Source) %>%
  mutate(
    Percentage = round(100 * n / sum(n), 2)
  )

print(ncc_breakdown)

cat("\n")
cat(rep("-", 80), "\n", sep = "")
cat("SUMMARY:\n\n")

# Calculate totals
total_babies <- nrow(data)
in_both <- ncc_breakdown %>% filter(NCC_Source == "Both MSDS & CC") %>% pull(n)
msds_only <- ncc_breakdown %>% filter(NCC_Source == "MSDS only") %>% pull(n)
cc_only <- ncc_breakdown %>% filter(NCC_Source == "CC only") %>% pull(n)
not_admitted <- ncc_breakdown %>% filter(NCC_Source == "Not admitted to NCC") %>% pull(n)

# Handle cases where categories might be missing
if(length(in_both) == 0) in_both <- 0
if(length(msds_only) == 0) msds_only <- 0
if(length(cc_only) == 0) cc_only <- 0
if(length(not_admitted) == 0) not_admitted <- 0

total_ncc <- in_both + msds_only + cc_only

cat("Total NCC admissions (any source):", format(total_ncc, big.mark = ","), "\n")
cat("  - In BOTH sources:", format(in_both, big.mark = ","),
    "(", round(100 * in_both / total_ncc, 1), "% of NCC admissions)\n")
cat("  - MSDS ONLY:", format(msds_only, big.mark = ","),
    "(", round(100 * msds_only / total_ncc, 1), "% of NCC admissions)\n")
cat("  - CC ONLY:", format(cc_only, big.mark = ","),
    "(", round(100 * cc_only / total_ncc, 1), "% of NCC admissions)\n")

cat("\nNot admitted to NCC:", format(not_admitted, big.mark = ","), "\n")

# Calculate totals from each source
total_in_msds <- in_both + msds_only
total_in_cc <- in_both + cc_only

cat("\n")
cat(rep("=", 80), "\n", sep = "")
cat("SOURCE TOTALS:\n")
cat(rep("=", 80), "\n", sep = "")
cat("\nMSDS (MSD402NeonatalAdmission_1):\n")
cat("  Total NCC admissions:", format(total_in_msds, big.mark = ","), "\n")
cat("  Percentage of all babies:", round(100 * total_in_msds / total_babies, 2), "%\n")

cat("\nCC (Pbr_CC_Monthly, CC_Type='NCC'):\n")
cat("  Total NCC admissions:", format(total_in_cc, big.mark = ","), "\n")
cat("  Percentage of all babies:", round(100 * total_in_cc / total_babies, 2), "%\n")

cat("\nDifference:\n")
cat("  CC has", format(total_in_cc - total_in_msds, big.mark = ","),
    "MORE NCC admissions than MSDS\n")
cat("  Ratio: CC/MSDS =", round(total_in_cc / total_in_msds, 2), "\n")

# Data quality assessment
cat("\n")
cat(rep("=", 80), "\n", sep = "")
cat("DATA QUALITY IMPLICATIONS:\n")
cat(rep("=", 80), "\n", sep = "")

coverage <- round(100 * in_both / total_ncc, 1)
cat("\nCoverage (in both sources):", coverage, "%\n")

if (coverage < 50) {
  cat("\n⚠️  WARNING: Low overlap between sources (<50%)\n")
  cat("This suggests significant data quality issues or different definitions\n")
} else if (coverage < 80) {
  cat("\n⚠️  CAUTION: Moderate overlap (50-80%)\n")
  cat("Some discrepancies between MSDS and CC reporting\n")
} else {
  cat("\n✓ GOOD: High overlap (>80%)\n")
  cat("Generally consistent reporting between sources\n")
}

cat("\nPossible reasons for discrepancies:\n")
cat("1. MSDS-only admissions: Transfers not flagged as critical care in CC data\n")
cat("2. CC-only admissions: NHS number linking failures between MSDS and APCS\n")
cat("3. Timing: Different financial year filters or date proximity filters\n")
cat("4. Definition differences: What counts as 'neonatal critical care'\n")

cat("\n")
cat(rep("=", 80), "\n", sep = "")
