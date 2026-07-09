# ============================================================================
# [A5c] Ethnicity x deprivation interaction — exploratory refit
# ============================================================================
# Anna: does the deprivation gradient in NCC admission differ by ethnic group
# (or equivalently, do ethnicity gaps differ across the deprivation spectrum)?
#
# Framing agreed: a single GLOBAL likelihood-ratio test of the interaction,
# not cell-by-cell interpretation. A full 10-level ethnicity x 5-level IMD
# interaction adds 36 parameters; picking through 36 cell contrasts invites
# false positives, so the primary readout is "is there evidence the gradient
# differs at all?" (one test, no multiplicity burden). Cell-level ORs are
# saved for an exploratory figure only.
#
# Null model: the saved primary model (Model 2) — same data, same spec, so
# the LRT is valid without refitting it.
#
# Outputs:
#   data/model2_interaction.rds  full glmer fit (interaction model)
#   data/a5c_interaction_lrt.rds compact summary loaded by modelling_results.qmd
# ============================================================================

library(tidyverse)
library(lme4)

analysis_data <- readRDS("data/analysis_data_primary.rds")
model2 <- readRDS("data/model2_mixed_effects.rds")

# The LRT requires both models fitted to the identical sample
stopifnot(nobs(model2) == nrow(analysis_data))
cat("Records:", nrow(analysis_data), "\n")

# Cell support: smallest ethnicity x IMD cells and their admitted counts.
# Sparse cells make individual interaction terms unstable (another reason
# the global test is the primary readout), but should not break the fit.
cell_counts <- analysis_data %>%
  count(Ethnicity_Baby_Grouped, IMD_Quintile, name = "births") %>%
  left_join(
    analysis_data %>%
      filter(NCC_Admitted == 1) %>%
      count(Ethnicity_Baby_Grouped, IMD_Quintile, name = "admitted"),
    by = c("Ethnicity_Baby_Grouped", "IMD_Quintile")
  ) %>%
  mutate(admitted = replace_na(admitted, 0L))

cat("\nSmallest ethnicity x IMD cells:\n")
print(as.data.frame(arrange(cell_counts, births) %>% head(10)))

# ----------------------------------------------------------------------------
# Fit the interaction model (Model 2 + Ethnicity x IMD)
# ----------------------------------------------------------------------------

cat("\nFitting interaction model... (expect substantially longer than Model 2)\n")
t0 <- Sys.time()

model2_interaction <- glmer(
  NCC_Admitted ~ Gestation_Weeks + Ethnicity_Baby_Grouped * IMD_Quintile +
    (1 | Delivery_Trust),
  data = analysis_data,
  family = binomial,
  control = glmerControl(optimizer = "bobyqa", optCtrl = list(maxfun = 200000))
)

cat("Fitted in", round(difftime(Sys.time(), t0, units = "mins"), 1), "minutes\n\n")

conv_messages <- unlist(model2_interaction@optinfo$conv$lme4$messages)
if (length(conv_messages)) {
  cat("Convergence messages:\n"); print(conv_messages)
} else {
  cat("No convergence warnings.\n")
}

saveRDS(model2_interaction, "data/model2_interaction.rds")
cat("Saved data/model2_interaction.rds\n")

# ----------------------------------------------------------------------------
# Global likelihood-ratio test: interaction vs primary model
# ----------------------------------------------------------------------------

lrt <- anova(model2, model2_interaction)
cat("\nGlobal LRT (interaction vs main effects):\n")
print(lrt)

# ----------------------------------------------------------------------------
# Exploratory cell-level ORs (for figure only, not inference)
# ----------------------------------------------------------------------------
# OR for "most vs least deprived" within each ethnic group:
# exp(IMD main effect + interaction term for that group).

fe <- fixef(model2_interaction)
vc <- vcov(model2_interaction)
eth_levels <- levels(analysis_data$Ethnicity_Baby_Grouped)
imd_term <- "IMD_Quintile1 - Most deprived"

gradient_by_eth <- map_dfr(eth_levels, function(eth) {
  if (eth == eth_levels[1]) {
    est <- fe[imd_term]
    se <- sqrt(vc[imd_term, imd_term])
  } else {
    int_term <- paste0("Ethnicity_Baby_Grouped", eth, ":", imd_term)
    est <- fe[imd_term] + fe[int_term]
    se <- sqrt(vc[imd_term, imd_term] + vc[int_term, int_term] +
                 2 * vc[imd_term, int_term])
  }
  tibble(Ethnicity = eth, OR = exp(est),
         Lower = exp(est - 1.96 * se), Upper = exp(est + 1.96 * se))
})

cat("\nWithin-group deprivation gradient (most vs least deprived OR):\n")
print(as.data.frame(gradient_by_eth), digits = 3)

# Compact summary for the report (keeps the qmd from loading two 45MB fits)
a5c_summary <- list(
  lrt = as.data.frame(lrt),
  n = nobs(model2_interaction),
  n_interaction_terms = sum(grepl(":", names(fe))),
  gradient_by_eth = gradient_by_eth,
  cell_counts = cell_counts,
  aic = AIC(model2, model2_interaction),
  bic = BIC(model2, model2_interaction),
  convergence_messages = conv_messages,
  fitted = Sys.time()
)
saveRDS(a5c_summary, "data/a5c_interaction_lrt.rds")
cat("\nSaved data/a5c_interaction_lrt.rds\n")
