# ============================================================================
# [A5a] Length of stay among admitted babies — ethnicity / deprivation
# ============================================================================
# Anna: "extend to length of stay once admitted". Not blocked by the
# day-of-birth problem: NCC_CC_Total_Days is a count of CC daily records,
# no birth datetime needed.
#
# Sample: babies in the primary analysis sample admitted to NCC with at
# least one CC daily record. MSDS-only admissions (~7% of admitted) have no
# CC days and are excluded — noted as a caveat in the report.
#
# Outcome: NCC_CC_Total_Days. Heavily right-skewed count
# (median 4, mean ~9.5, max 290; variance/mean ~28), so negative binomial.
# Gestation enters as clinical bands because its effect on LOS is steeply
# nonlinear (median 61 days <28w vs 3 days at term) — a linear week term
# would badly misfit both tails.
#
# Interpretation: exp(coef) are rate ratios — multiplicative differences in
# expected days of NCC care, conditional on gestation band and trust.
# Conditioning on admission is a selection: if a group is admitted at a
# lower threshold, its admitted babies are milder and expected LOS shorter.
# Read jointly with the admission model, not in isolation.
#
# Outputs:
#   data/model_a5a_los_nb.rds  full glmer.nb fit
#   data/a5a_los_summary.rds   compact summary loaded by modelling_results.qmd
# ============================================================================

library(bit64)
library(tidyverse)
library(lme4)

analysis_data <- readRDS("data/analysis_data_primary.rds")

adm <- analysis_data %>%
  filter(NCC_Admitted == 1) %>%
  mutate(LOS = as.numeric(as.integer64(NCC_CC_Total_Days)))

n_admitted <- nrow(adm)
n_msds_only <- sum(is.na(adm$LOS) | adm$LOS == 0)

los_data <- adm %>%
  filter(!is.na(LOS), LOS > 0) %>%
  mutate(
    Gestation_Band = cut(
      Gestation_Weeks,
      breaks = c(22, 28, 32, 34, 37, 45),
      right = FALSE,
      labels = c("Extremely preterm (<28w)", "Very preterm (28-31w)",
                 "Moderate preterm (32-33w)", "Late preterm (34-36w)",
                 "Term (37w+)")
    ),
    Gestation_Band = relevel(Gestation_Band, ref = "Term (37w+)")
  )

cat("Admitted babies:", n_admitted, "\n")
cat("Excluded (MSDS-only, no CC days):", n_msds_only, "\n")
cat("LOS sample:", nrow(los_data), "\n\n")
stopifnot(!any(is.na(los_data$Gestation_Band)))

# ----------------------------------------------------------------------------
# Descriptives (crude, for the report table)
# ----------------------------------------------------------------------------

desc_stats <- function(d, grp) {
  d %>%
    group_by(across(all_of(grp))) %>%
    summarise(
      n = dplyr::n(),
      median = median(LOS),
      q1 = quantile(LOS, .25),
      q3 = quantile(LOS, .75),
      mean = mean(LOS),
      pct_28plus = mean(LOS >= 28),
      .groups = "drop"
    )
}

desc_eth  <- desc_stats(los_data, "Ethnicity_Baby_Grouped")
desc_imd  <- desc_stats(los_data, "IMD_Quintile")
desc_gest <- desc_stats(los_data, "Gestation_Band")

cat("Crude LOS by ethnicity:\n");      print(as.data.frame(desc_eth), digits = 3)
cat("\nCrude LOS by IMD quintile:\n"); print(as.data.frame(desc_imd), digits = 3)
cat("\nCrude LOS by gestation band:\n"); print(as.data.frame(desc_gest), digits = 3)

# ----------------------------------------------------------------------------
# Negative binomial mixed model
# ----------------------------------------------------------------------------

cat("\nFitting NB mixed model (glmer.nb)... (theta iterations, expect a while)\n")
t0 <- Sys.time()

model_a5a <- glmer.nb(
  LOS ~ Gestation_Band + Ethnicity_Baby_Grouped + IMD_Quintile +
    (1 | Delivery_Trust),
  data = los_data,
  control = glmerControl(optimizer = "bobyqa", optCtrl = list(maxfun = 200000))
)

cat("Fitted in", round(difftime(Sys.time(), t0, units = "mins"), 1), "minutes\n\n")

conv_messages <- unlist(model_a5a@optinfo$conv$lme4$messages)
if (length(conv_messages)) {
  cat("Convergence messages:\n"); print(conv_messages)
} else {
  cat("No convergence warnings.\n")
}

print(summary(model_a5a))
saveRDS(model_a5a, "data/model_a5a_los_nb.rds")
cat("Saved data/model_a5a_los_nb.rds\n")

# ----------------------------------------------------------------------------
# Rate ratios with BH adjustment within families (house convention)
# ----------------------------------------------------------------------------

fe <- fixef(model_a5a)
se <- sqrt(diag(vcov(model_a5a)))
z  <- fe / se
p  <- 2 * pnorm(-abs(z))

rr_table <- tibble(
  raw_term = names(fe),
  RR = exp(fe),
  Lower = exp(fe - 1.96 * se),
  Upper = exp(fe + 1.96 * se),
  p.value = p
) %>%
  mutate(
    family = case_when(
      str_detect(raw_term, "Ethnicity") ~ "ethnicity",
      str_detect(raw_term, "IMD")       ~ "imd",
      str_detect(raw_term, "Gestation") ~ "gestation",
      TRUE                              ~ "other"
    )
  ) %>%
  group_by(family) %>%
  mutate(p.adj_BH = ifelse(family %in% c("ethnicity", "imd"),
                           p.adjust(p.value, method = "BH"), NA_real_)) %>%
  ungroup()

cat("\nRate ratios (expected days, adjusted):\n")
print(as.data.frame(rr_table %>% filter(raw_term != "(Intercept)")), digits = 3)

# Trust-level variation in recorded LOS
vc_trust <- as.data.frame(VarCorr(model_a5a))$vcov[1]
cat("\nTrust random-intercept variance (log scale):", round(vc_trust, 3), "\n")
cat("Theta (NB dispersion):", round(getME(model_a5a, "glmer.nb.theta"), 3), "\n")

a5a_summary <- list(
  n_admitted = n_admitted,
  n_msds_only = n_msds_only,
  n_los = nrow(los_data),
  los_quantiles = quantile(los_data$LOS, c(.25, .5, .75, .9, .95, .99)),
  desc_eth = desc_eth,
  desc_imd = desc_imd,
  desc_gest = desc_gest,
  rr_table = rr_table,
  theta = getME(model_a5a, "glmer.nb.theta"),
  trust_var = vc_trust,
  convergence_messages = conv_messages,
  fitted = Sys.time()
)
saveRDS(a5a_summary, "data/a5a_los_summary.rds")
cat("\nSaved data/a5a_los_summary.rds\n")
