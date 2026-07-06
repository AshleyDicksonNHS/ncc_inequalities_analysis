# ============================================================================
# [K4] Broad (MBRRACE-comparable) ethnicity grouping — sensitivity refit
# ============================================================================
# Katharine: "I wonder whether the ethnicity grouping might be too detailed.
# I have looked at a recent MBRRACE report, and the ethnicity analysis isn't
# as detailed as you have here." (MBRRACE-UK Maternal Report 2025, table 5.3)
#
# Response: refit the primary model (Model 2) replacing the 10-level
# disaggregated ethnicity with the 5 broad ONS/MBRRACE-style groups, on the
# SAME analysis sample. The broad grouping is a deterministic aggregation of
# the disaggregated levels, so the sample is unchanged (n = 476,475).
# Presented alongside — not instead of — the disaggregated model, to show
# what the broad "Asian" category conceals.
#
# Broad groups (NHS ethnic category codes → ONS 2001 broad groups, as used
# in MBRRACE reporting):
#   White                 A, B, C
#   Mixed                 D, E, F, G
#   Asian or Asian British H, J, K, L
#   Black or Black British M, N, P
#   Other (incl. Chinese) R, S
#
# Output: data/model2_broad_ethnicity.rds  (loaded by modelling_results.qmd)
# ============================================================================

library(tidyverse)
library(lme4)

analysis_data <- readRDS("data/analysis_data_primary.rds")

analysis_data <- analysis_data %>%
  mutate(
    Ethnicity_Broad = case_when(
      Ethnic_Category_Baby %in% c("A", "B", "C") ~ "White",
      Ethnic_Category_Baby %in% c("D", "E", "F", "G") ~ "Mixed",
      Ethnic_Category_Baby %in% c("H", "J", "K", "L") ~ "Asian or Asian British",
      Ethnic_Category_Baby %in% c("M", "N", "P") ~ "Black or Black British",
      Ethnic_Category_Baby %in% c("R", "S") ~ "Other (incl. Chinese)",
      TRUE ~ NA_character_
    ),
    Ethnicity_Broad = factor(Ethnicity_Broad,
                             levels = c("White", "Mixed",
                                        "Asian or Asian British",
                                        "Black or Black British",
                                        "Other (incl. Chinese)"))
  )

# Sanity checks: aggregation must be lossless w.r.t. the primary sample
stopifnot(!any(is.na(analysis_data$Ethnicity_Broad)))
cat("Records:", nrow(analysis_data), "\n")
cat("\nBroad ethnicity distribution:\n")
print(table(analysis_data$Ethnicity_Broad))

# Cross-tab: confirm the mapping nests the disaggregated grouping cleanly
cat("\nDisaggregated -> broad mapping check:\n")
print(table(analysis_data$Ethnicity_Baby_Grouped, analysis_data$Ethnicity_Broad))

# ----------------------------------------------------------------------------
# Refit Model 2 with the broad grouping (same spec otherwise)
# ----------------------------------------------------------------------------

cat("\nFitting broad-ethnicity mixed model... (a few minutes)\n")
t0 <- Sys.time()

model2_broad <- glmer(
  NCC_Admitted ~ Gestation_Weeks + Ethnicity_Broad + IMD_Quintile +
    (1 | Delivery_Trust),
  data = analysis_data,
  family = binomial,
  control = glmerControl(optimizer = "bobyqa", optCtrl = list(maxfun = 100000))
)

cat("Fitted in", round(difftime(Sys.time(), t0, units = "mins"), 1), "minutes\n\n")
print(summary(model2_broad))

saveRDS(model2_broad, "data/model2_broad_ethnicity.rds")
cat("\nSaved data/model2_broad_ethnicity.rds\n")

# ----------------------------------------------------------------------------
# Odds ratios: broad groups
# ----------------------------------------------------------------------------

fe <- fixef(model2_broad)
se <- sqrt(diag(vcov(model2_broad)))
or_broad <- tibble(
  term = names(fe),
  OR = exp(fe),
  Lower = exp(fe - 1.96 * se),
  Upper = exp(fe + 1.96 * se)
) %>%
  filter(str_detect(term, "Ethnicity_Broad")) %>%
  mutate(term = str_remove(term, "Ethnicity_Broad"))

cat("\nBroad-group odds ratios (vs White):\n")
print(as.data.frame(or_broad), digits = 3)
