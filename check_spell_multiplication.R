# ============================================================================
# DQ check: how badly does spell-multiplication affect the existing dataset?
# ============================================================================
# The SQL prior to today's fix joined babies to NCC CC via APCS_Ident, which
# meant babies with multiple NCC spells in the FY appeared multiple times.
# This script quantifies the impact on the saved ncc_base_dataset.rds so we
# can decide whether the previously-reported Phase 1 numbers need a caveat,
# or whether the multi-spell rate is small enough to be a non-issue.
#
# Run from the project root:  Rscript check_spell_multiplication.R
# ============================================================================

library(tidyverse)

if (!file.exists("data/ncc_base_dataset.rds")) {
  stop("data/ncc_base_dataset.rds not found — run build_ncc_base_dataset.R first.")
}

ncc <- readRDS("data/ncc_base_dataset.rds")

cat("Total rows in ncc_base_dataset.rds: ", format(nrow(ncc), big.mark = ","), "\n")
cat("Distinct Person_ID_Baby:            ", format(n_distinct(ncc$Person_ID_Baby),
                                                   big.mark = ","), "\n\n")

dup_summary <- ncc %>%
  count(Person_ID_Baby, name = "n_rows") %>%
  count(n_rows, name = "n_babies")

cat("Rows-per-baby distribution:\n")
print(dup_summary)

dup_babies <- ncc %>%
  count(Person_ID_Baby) %>%
  filter(n > 1)

cat("\nBabies appearing more than once:", format(nrow(dup_babies), big.mark = ","),
    " (", round(100 * nrow(dup_babies) / n_distinct(ncc$Person_ID_Baby), 2), "%)\n",
    sep = "")

if (nrow(dup_babies) > 0) {
  # How does dedup affect the headline NCC rate?
  rate_raw  <- mean(ncc$NCC_Admitted, na.rm = TRUE)
  ncc_dedup <- ncc %>% distinct(Person_ID_Baby, .keep_all = TRUE)
  rate_dedup <- mean(ncc_dedup$NCC_Admitted, na.rm = TRUE)

  cat("\nNCC admission rate, raw rows:    ", sprintf("%.3f%%", 100 * rate_raw), "\n")
  cat("NCC admission rate, deduped:     ", sprintf("%.3f%%", 100 * rate_dedup), "\n")
  cat("Absolute difference (pp):        ", sprintf("%+.3f", 100 * (rate_raw - rate_dedup)), "\n")

  cat("\nDuplicated babies are almost certainly NCC-admitted (multiple spells).\n")
  cat("If the absolute difference is small (<0.1pp) the impact on Phase 1 is\n")
  cat("negligible. Larger differences mean the previously-reported numbers\n")
  cat("over-state the NCC rate slightly.\n")
} else {
  cat("\nNo duplicates — Phase 1 results are unaffected by spell-multiplication.\n")
}
