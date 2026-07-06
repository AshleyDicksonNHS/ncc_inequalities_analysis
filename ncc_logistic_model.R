# ============================================================================
# NCC Access Inequalities - Mixed Effects Logistic Regression
# ============================================================================
# Outcome: NCC_Admitted (binary)
# Fixed effects: Clinical severity, ethnicity, deprivation
# Random effects: Delivery site / Provider
#
# TWO MODELS:
#   - Primary (Model 2): Gestation only - maximises sample size
#   - Sensitivity (Model 3): Gestation + Birth Weight + Apgar - full clinical adjustment
#
# NOTE: Uses Birth_Weight_Grams (MSDS only) NOT Birth_Weight_Combined
#       to avoid differential missingness bias (CC data inflates NCC completeness)
# ============================================================================

library(tidyverse)
library(bit64)        # for handling integer64 from database
library(lme4)
library(broom.mixed)  # for tidy model output

# ============================================================================
# 1. LOAD AND PREPARE DATA
# ============================================================================

ncc_data <- readRDS("data/ncc_base_dataset.rds")
cat("Loaded", nrow(ncc_data), "records\n\n")

# ----------------------------------------------------------------------------
# Defensive dedup: one row per Person_ID_Baby
# ----------------------------------------------------------------------------
# The SQL aggregates CC spells per NHS number, but if anything slips through
# (e.g. a baby with two MSDS records for distinct pregnancies in the same FY,
# or a regression in the SQL), we keep one row per baby — the row with the
# earliest CC activity if admitted, otherwise an arbitrary stable choice.
# ----------------------------------------------------------------------------
n_pre <- nrow(ncc_data)
n_distinct_babies <- dplyr::n_distinct(ncc_data$Person_ID_Baby)
if (n_pre != n_distinct_babies) {
  cat("WARNING: ", n_pre - n_distinct_babies,
      " duplicate Person_ID_Baby rows detected — deduping.\n", sep = "")
  ncc_data <- ncc_data %>%
    arrange(Person_ID_Baby,
            !is.na(NCC_CC_First_Activity_Date),
            NCC_CC_First_Activity_Date) %>%
    distinct(Person_ID_Baby, .keep_all = TRUE)
  cat("Rows after dedup:", nrow(ncc_data), "\n\n")
} else {
  cat("Dedup check: one row per Person_ID_Baby — OK.\n\n")
}

# ----------------------------------------------------------------------------
# Data cleaning and variable preparation
# ----------------------------------------------------------------------------

model_data <- ncc_data %>%
  mutate(
    # Clean birth weight - USE MSDS ONLY (Birth_Weight_Grams) to avoid bias
    # Birth_Weight_Combined has 94% completeness for NCC vs 46% for non-NCC (selection bias!)
    # Birth_Weight_Grams has ~46% for both groups (no differential missingness)
    Birth_Weight_Clean = case_when(
      Birth_Weight_Grams < 200 ~ NA_real_,
      Birth_Weight_Grams > 6000 ~ NA_real_,
      TRUE ~ as.numeric(Birth_Weight_Grams)
    ),
    # Scale birth weight to kg for interpretable coefficients
    Birth_Weight_kg = Birth_Weight_Clean / 1000,

    # Clean gestation (convert to weeks, remove impossible values)
    # Note: Gestation_Length_At_Birth is integer64 from database, convert via as.integer()
    Gestation_Days = as.integer(Gestation_Length_At_Birth),
    Gestation_Weeks = Gestation_Days / 7,
    Gestation_Weeks = case_when(
      Gestation_Weeks < 22 ~ NA_real_,
      Gestation_Weeks > 44 ~ NA_real_,
      TRUE ~ Gestation_Weeks
    ),

    # Clean Apgar scores (must be 0-10)
    Apgar_1_Clean = case_when(
      Apgar_Score_1_Minute < 0 ~ NA_integer_,
      Apgar_Score_1_Minute > 10 ~ NA_integer_,
      TRUE ~ as.integer(Apgar_Score_1_Minute)
    ),
    Apgar_5_Clean = case_when(
      Apgar_Score_5_Minutes < 0 ~ NA_integer_,
      Apgar_Score_5_Minutes > 10 ~ NA_integer_,
      TRUE ~ as.integer(Apgar_Score_5_Minutes)
    ),

    # Categorise Apgar 5 for clinical interpretation
    Apgar_5_Cat = case_when(
      Apgar_5_Clean >= 7 ~ "Normal (7-10)",
      Apgar_5_Clean >= 4 ~ "Moderate (4-6)",
      Apgar_5_Clean >= 0 ~ "Low (0-3)",
      TRUE ~ NA_character_
    ),
    Apgar_5_Cat = factor(Apgar_5_Cat, levels = c("Normal (7-10)", "Moderate (4-6)", "Low (0-3)")),

    # Ethnicity - more granular grouping to capture sub-ethnic variation
    # Splits Asian (Indian/Pakistani/Bangladeshi have different health profiles)
    # and separates Chinese from Other
    Ethnicity_Baby_Grouped = case_when(
      Ethnic_Category_Baby == "A" ~ "White British",
      Ethnic_Category_Baby %in% c("B", "C") ~ "White Other",
      Ethnic_Category_Baby %in% c("D", "E", "F", "G") ~ "Mixed",
      Ethnic_Category_Baby == "H" ~ "Indian",
      Ethnic_Category_Baby == "J" ~ "Pakistani",
      Ethnic_Category_Baby == "K" ~ "Bangladeshi",
      Ethnic_Category_Baby == "L" ~ "Other Asian",
      Ethnic_Category_Baby %in% c("M", "N", "P") ~ "Black",
      Ethnic_Category_Baby == "R" ~ "Chinese",
      Ethnic_Category_Baby == "S" ~ "Other",
      Ethnic_Category_Baby %in% c("Z", "99", "") ~ NA_character_,
      TRUE ~ NA_character_
    ),
    Ethnicity_Baby_Grouped = factor(Ethnicity_Baby_Grouped,
                                     levels = c("White British", "White Other", "Mixed",
                                               "Indian", "Pakistani", "Bangladeshi",
                                               "Other Asian", "Black", "Chinese", "Other")),

    # IMD decile as ordered factor
    IMD_Decile = factor(IMD_Decile_2015, ordered = TRUE),

    # IMD quintile (for simpler models)
    # Reference category = Least deprived, so ORs show increased risk for more deprived groups
    IMD_Quintile = case_when(
      IMD_Decile_2015 %in% c("01 - Most deprived", "02") ~ "1 - Most deprived",
      IMD_Decile_2015 %in% c("03", "04") ~ "2",
      IMD_Decile_2015 %in% c("05", "06") ~ "3",
      IMD_Decile_2015 %in% c("07", "08") ~ "4",
      IMD_Decile_2015 %in% c("09", "10 - Least deprived") ~ "5 - Least deprived",
      TRUE ~ NA_character_
    ),
    IMD_Quintile = factor(IMD_Quintile, levels = c("5 - Least deprived", "4", "3", "2", "1 - Most deprived")),

    # Delivery trust (random-effect grouping).
    # MSDS site code (Org_Site_ID_Actual_Place_Delivery) is missing for ~17% of
    # babies, but the submitting trust code (Submitting_Org_Code, the 3-letter
    # provider) is populated for 100% of those records. To avoid silently
    # excluding that slice — and to avoid mixing hierarchy levels (a 5-letter
    # site code is administratively *inside* its 3-letter trust) — we cluster
    # at trust level for everyone: take the first 3 chars of the site code
    # where available, and the trust code where not.
    Delivery_Trust_Code = coalesce(substr(Delivery_Site_Code, 1, 3),
                                   Submitting_Org_Code),
    Delivery_Trust = factor(Delivery_Trust_Code),

    # Outcome
    NCC_Admitted = as.integer(NCC_Admitted)
  )

# ----------------------------------------------------------------------------
# Check variable distributions
# ----------------------------------------------------------------------------

cat("=== CLEANED VARIABLE SUMMARY ===\n\n")

cat("Birth Weight (kg):\n")
print(summary(model_data$Birth_Weight_kg))

cat("\nGestation (weeks):\n")
print(summary(model_data$Gestation_Weeks))

cat("\nApgar 5 min (categorical):\n")
print(table(model_data$Apgar_5_Cat, useNA = "ifany"))

cat("\nEthnicity (grouped):\n")
print(table(model_data$Ethnicity_Baby_Grouped, useNA = "ifany"))

cat("\nIMD Quintile:\n")
print(table(model_data$IMD_Quintile, useNA = "ifany"))

cat("\nDelivery Trusts:", length(unique(model_data$Delivery_Trust[!is.na(model_data$Delivery_Trust)])), "\n")
cat("Babies with Delivery_Trust resolved from site code: ",
    sum(!is.na(model_data$Delivery_Site_Code)), "\n", sep = "")
cat("Babies with Delivery_Trust resolved from Submitting_Org_Code fallback: ",
    sum(is.na(model_data$Delivery_Site_Code) & !is.na(model_data$Submitting_Org_Code)),
    "\n", sep = "")

# ----------------------------------------------------------------------------
# Create analysis datasets
# ----------------------------------------------------------------------------

# PRIMARY DATASET: Gestation only (maximises sample size)
analysis_data <- model_data %>%
  filter(
    !is.na(NCC_Admitted),
    !is.na(Gestation_Weeks),
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(IMD_Quintile),
    !is.na(Delivery_Trust)
  ) %>%
  droplevels()

cat("\n=== PRIMARY ANALYSIS DATASET (Gestation only) ===\n")
cat("Records:", nrow(analysis_data), "(", round(100 * nrow(analysis_data) / nrow(ncc_data), 1), "% of total)\n")
cat("NCC admissions:", sum(analysis_data$NCC_Admitted), "(", round(100 * mean(analysis_data$NCC_Admitted), 1), "%)\n")

# SENSITIVITY DATASET: Full clinical adjustment (Gestation + Birth Weight + Apgar)
analysis_data_full <- model_data %>%
  filter(
    !is.na(NCC_Admitted),
    !is.na(Gestation_Weeks),
    !is.na(Birth_Weight_kg),
    !is.na(Apgar_5_Clean),
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(IMD_Quintile),
    !is.na(Delivery_Trust)
  ) %>%
  droplevels()

cat("\n=== SENSITIVITY ANALYSIS DATASET (Full clinical) ===\n")
cat("Records:", nrow(analysis_data_full), "(", round(100 * nrow(analysis_data_full) / nrow(ncc_data), 1), "% of total)\n")
cat("NCC admissions:", sum(analysis_data_full$NCC_Admitted), "(", round(100 * mean(analysis_data_full$NCC_Admitted), 1), "%)\n")
cat("NCC rate comparison: Primary =", round(100 * mean(analysis_data$NCC_Admitted), 1),
    "%, Sensitivity =", round(100 * mean(analysis_data_full$NCC_Admitted), 1), "%\n")
cat("(Similar rates suggest minimal selection bias)\n")

# ============================================================================
# 2. MODEL BUILDING - START SIMPLE
# ============================================================================

cat("\n\n========================================\n")
cat("MODEL 1: Fixed effects only (no random effects)\n")
cat("========================================\n\n")

# Simple logistic regression - clinical factors only
model1_clinical <- glm(
  NCC_Admitted ~ Gestation_Weeks,
  data = analysis_data,
  family = binomial
)

cat("Model 1a: Gestation only\n")
print(summary(model1_clinical))

# Add ethnicity and deprivation
model1_full <- glm(
  NCC_Admitted ~ Gestation_Weeks + Ethnicity_Baby_Grouped + IMD_Quintile,
  data = analysis_data,
  family = binomial
)

cat("\n\nModel 1b: Gestation + Ethnicity + IMD\n")
print(summary(model1_full))

# Odds ratios with 95% CI
cat("\n\nOdds Ratios (Model 1b):\n")
or_table <- exp(cbind(OR = coef(model1_full), confint(model1_full)))
print(round(or_table, 3))

# ============================================================================
# 3. MIXED EFFECTS MODEL - ADD RANDOM INTERCEPTS
# ============================================================================

cat("\n\n========================================\n")
cat("MODEL 2: Mixed effects (random intercept for delivery trust)\n")
cat("========================================\n\n")

# This may take a minute to fit
cat("Fitting mixed effects model... (this may take a moment)\n")

model2_mixed <- glmer(
  NCC_Admitted ~ Gestation_Weeks + Ethnicity_Baby_Grouped + IMD_Quintile +
    (1 | Delivery_Trust),
  data = analysis_data,
  family = binomial,
  control = glmerControl(optimizer = "bobyqa", optCtrl = list(maxfun = 100000))
)

cat("\nModel 2: Mixed effects logistic regression\n")
print(summary(model2_mixed))

# Fixed effects as odds ratios
cat("\n\nFixed Effects - Odds Ratios:\n")
fe <- fixef(model2_mixed)
se <- sqrt(diag(vcov(model2_mixed)))
or_mixed <- data.frame(
  OR = exp(fe),
  CI_lower = exp(fe - 1.96 * se),
  CI_upper = exp(fe + 1.96 * se)
)
print(round(or_mixed, 3))

# Random effects variance
cat("\n\nRandom Effects Variance:\n")
print(VarCorr(model2_mixed))

# ICC - how much variation is between delivery trusts?
icc <- as.numeric(VarCorr(model2_mixed)$Delivery_Trust) /
       (as.numeric(VarCorr(model2_mixed)$Delivery_Trust) + (pi^2 / 3))
cat("\nIntraclass Correlation (ICC):", round(icc, 3), "\n")
cat("Interpretation:", round(icc * 100, 1), "% of residual variance is between delivery trusts\n")

# ============================================================================
# 4. SENSITIVITY MODEL - FULL CLINICAL ADJUSTMENT
# ============================================================================

cat("\n\n========================================\n")
cat("MODEL 3: Sensitivity analysis - Full clinical adjustment\n")
cat("(Gestation + Birth Weight + Apgar 5-minute)\n")
cat("========================================\n\n")

cat("Using", nrow(analysis_data_full), "records with complete clinical data\n")
cat("Birth weight source: MSDS only (to avoid differential missingness bias)\n\n")

cat("Fitting sensitivity model... (this may take a moment)\n")

model3_sensitivity <- glmer(
  NCC_Admitted ~ Gestation_Weeks + Birth_Weight_kg + Apgar_5_Clean +
    Ethnicity_Baby_Grouped + IMD_Quintile +
    (1 | Delivery_Trust),
  data = analysis_data_full,
  family = binomial,
  control = glmerControl(optimizer = "bobyqa", optCtrl = list(maxfun = 100000))
)

cat("\nModel 3: Sensitivity analysis with full clinical adjustment\n")
print(summary(model3_sensitivity))

# Fixed effects as odds ratios
cat("\n\nFixed Effects - Odds Ratios (Sensitivity Model):\n")
fe3 <- fixef(model3_sensitivity)
se3 <- sqrt(diag(vcov(model3_sensitivity)))
or_sensitivity <- data.frame(
  OR = exp(fe3),
  CI_lower = exp(fe3 - 1.96 * se3),
  CI_upper = exp(fe3 + 1.96 * se3)
)
print(round(or_sensitivity, 3))

# ICC for sensitivity model
icc3 <- as.numeric(VarCorr(model3_sensitivity)$Delivery_Trust) /
        (as.numeric(VarCorr(model3_sensitivity)$Delivery_Trust) + (pi^2 / 3))
cat("\nSensitivity model ICC:", round(icc3, 3), "\n")

# ============================================================================
# 5. COMPARE PRIMARY VS SENSITIVITY MODELS
# ============================================================================

cat("\n\n========================================\n")
cat("MODEL COMPARISON: Primary vs Sensitivity\n")
cat("========================================\n\n")

# Extract ethnicity coefficients from both models
eth_terms <- grep("Ethnicity", names(fixef(model2_mixed)), value = TRUE)

cat("Ethnicity coefficients (log-odds):\n")
cat(sprintf("%-25s %12s %12s %12s\n", "Term", "Primary", "Sensitivity", "Difference"))
cat(paste(rep("-", 65), collapse = ""), "\n")

for (term in eth_terms) {
  primary_coef <- fixef(model2_mixed)[term]
  sens_coef <- fixef(model3_sensitivity)[term]
  diff <- sens_coef - primary_coef
  cat(sprintf("%-25s %12.3f %12.3f %+12.3f\n",
              gsub("Ethnicity_Baby_Grouped", "", term),
              primary_coef, sens_coef, diff))
}

# IMD coefficients
imd_terms <- grep("IMD", names(fixef(model2_mixed)), value = TRUE)

cat("\nIMD coefficients (log-odds):\n")
cat(sprintf("%-25s %12s %12s %12s\n", "Term", "Primary", "Sensitivity", "Difference"))
cat(paste(rep("-", 65), collapse = ""), "\n")

for (term in imd_terms) {
  primary_coef <- fixef(model2_mixed)[term]
  sens_coef <- fixef(model3_sensitivity)[term]
  diff <- sens_coef - primary_coef
  cat(sprintf("%-25s %12.3f %12.3f %+12.3f\n",
              gsub("IMD_Quintile", "Q", term),
              primary_coef, sens_coef, diff))
}

cat("\nICC comparison:\n")
cat("  Primary model:", round(icc, 3), "\n")
cat("  Sensitivity model:", round(icc3, 3), "\n")

# ============================================================================
# 6. SAVE RESULTS
# ============================================================================

cat("\n\n========================================\n")
cat("SAVING RESULTS\n")
cat("========================================\n")

# Save model objects
saveRDS(model1_full, "data/model1_fixed_effects.rds")
saveRDS(model2_mixed, "data/model2_mixed_effects.rds")
saveRDS(model3_sensitivity, "data/model3_sensitivity.rds")

# ----------------------------------------------------------------------------
# Save BH-adjusted p-value tables for the qmd
# ----------------------------------------------------------------------------
# Adjustment is applied within coherent test families: ethnicity (9 contrasts)
# and IMD quintiles (4 contrasts), separately for each of model 2 and model 3.
# We don't adjust the intercept or clinical covariates.
# ----------------------------------------------------------------------------

build_padj_table <- function(model) {
  fe <- fixef(model)
  se <- sqrt(diag(vcov(model)))
  z <- fe / se
  p <- 2 * pnorm(-abs(z))
  out <- tibble(
    term     = names(fe),
    estimate = fe,
    se       = se,
    p.value  = p,
    family   = case_when(
      str_detect(names(fe), "Ethnicity") ~ "ethnicity",
      str_detect(names(fe), "IMD")       ~ "imd",
      TRUE                                ~ "other"
    )
  )
  out %>%
    group_by(family) %>%
    mutate(
      p.adj_BH = ifelse(family %in% c("ethnicity", "imd"),
                        p.adjust(p.value, method = "BH"),
                        NA_real_)
    ) %>%
    ungroup()
}

m2_padj <- build_padj_table(model2_mixed)
m3_padj <- build_padj_table(model3_sensitivity)

saveRDS(m2_padj, "data/model2_padj.rds")
saveRDS(m3_padj, "data/model3_padj.rds")
cat("BH-adjusted coefficient tables saved (data/model2_padj.rds, data/model3_padj.rds)\n")

# Save analysis datasets for reference
saveRDS(analysis_data, "data/analysis_data_primary.rds")
saveRDS(analysis_data_full, "data/analysis_data_sensitivity.rds")

cat("Models saved to data/ folder:\n")
cat("  - model1_fixed_effects.rds (fixed effects only)\n")
cat("  - model2_mixed_effects.rds (PRIMARY: gestation + random effects)\n")
cat("  - model3_sensitivity.rds (SENSITIVITY: full clinical adjustment)\n")
cat("  - analysis_data_primary.rds\n")
cat("  - analysis_data_sensitivity.rds\n")

cat("\n=== MODELLING COMPLETE ===\n")
