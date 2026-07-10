# ============================================================================
# [A5b] Mortality among live births — descriptive, dual-source
# ============================================================================
# Anna: "outcomes / mortality". Deliberately NOT a headline model: death
# ascertainment in this extract is partial and the follow-up window is
# uneven, so this is a cautious descriptive look with the caveats up front.
#
# Death flag from TWO sources, mirroring the dual-source NCC_Admitted design:
#   * MSDS:  Baby_Death_Date (MSD401 PersonDeathDateBaby) — deaths known to
#            the maternity service
#   * APCS:  APCS_Died_In_Hospital (spell Discharge_Method = '4') — deaths
#            in any hospital spell in the extract window (Apr 2023-Apr 2024),
#            including after maternity discharge
#   * Died  = either source (primary); Died_Both = data-quality flag
#
# What this measures: died in hospital (or known to the maternity service)
# WITHIN THE EXTRACT WINDOW. It is not 28-day neonatal mortality: with no
# day of birth in this environment, age at death cannot be computed, and
# babies born late in the FY have less in-window follow-up than those born
# early (checked below via labour-admission month as a birth-month proxy).
#
# Analysis: crude rates per 1,000 (Wilson CIs), then indirect standardisation
# by gestation band — observed/expected deaths per group with expected counts
# from national band-specific rates (exact Poisson CIs; BH within the
# ethnicity and IMD families, house convention). No regression model.
#
# Outputs:
#   data/a5b_mortality_summary.rds  compact summary loaded by modelling_results.qmd
# ============================================================================

library(bit64)
library(tidyverse)

d <- readRDS("data/ncc_base_dataset.rds")
stopifnot(all(c("APCS_Died_In_Hospital", "APCS_Stillbirth_Coded") %in% names(d)))

# ----------------------------------------------------------------------------
# Cohort: live births, with the tiny MSDS/APCS stillbirth discordance removed
# ----------------------------------------------------------------------------

n_fy <- nrow(d)
lb_all <- d %>% filter(Pregnancy_Outcome == "01")
n_live <- nrow(lb_all)

# Babies MSDS calls live births but APCS coded as stillbirth (Discharge_Method
# '5'): vital status too uncertain to keep in a mortality denominator.
n_sb_discordant <- sum(coalesce(as.integer(lb_all$APCS_Stillbirth_Coded), 0L) == 1L)

lb <- lb_all %>%
  filter(coalesce(as.integer(APCS_Stillbirth_Coded), 0L) == 0L) %>%
  mutate(
    Died_MSDS = !is.na(Baby_Death_Date),
    Died_APCS = coalesce(as.integer(APCS_Died_In_Hospital), 0L) == 1L,
    Died = Died_MSDS | Died_APCS,
    Death_Source = case_when(
      Died_MSDS & Died_APCS ~ "Both sources",
      Died_MSDS ~ "MSDS only",
      Died_APCS ~ "APCS only",
      TRUE ~ NA_character_
    ),

    # Same derivations as the Phase 1 models (ncc_logistic_model.R)
    Gestation_Weeks = {
      gw <- as.integer(Gestation_Length_At_Birth) / 7
      if_else(gw < 22 | gw > 44, NA_real_, gw)
    },
    Gestation_Band = cut(
      Gestation_Weeks,
      breaks = c(22, 28, 32, 34, 37, 45),
      right = FALSE,
      labels = c("Extremely preterm (<28w)", "Very preterm (28-31w)",
                 "Moderate preterm (32-33w)", "Late preterm (34-36w)",
                 "Term (37w+)")
    ),
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
      TRUE ~ NA_character_
    ),
    Ethnicity_Baby_Grouped = factor(Ethnicity_Baby_Grouped,
                                    levels = c("White British", "White Other", "Mixed",
                                               "Indian", "Pakistani", "Bangladeshi",
                                               "Other Asian", "Black", "Chinese", "Other")),
    IMD_Quintile = case_when(
      IMD_Decile_2015 %in% c("01 - Most deprived", "02") ~ "1 - Most deprived",
      IMD_Decile_2015 %in% c("03", "04") ~ "2",
      IMD_Decile_2015 %in% c("05", "06") ~ "3",
      IMD_Decile_2015 %in% c("07", "08") ~ "4",
      IMD_Decile_2015 %in% c("09", "10 - Least deprived") ~ "5 - Least deprived",
      TRUE ~ NA_character_
    ),
    IMD_Quintile = factor(IMD_Quintile,
                          levels = c("5 - Least deprived", "4", "3", "2", "1 - Most deprived")),
    NCC_Admitted = as.integer(NCC_Admitted)
  )

cat("FY 2023/24 births:", n_fy, "\n")
cat("Live births (Pregnancy_Outcome 01):", n_live, "\n")
cat("Removed (APCS stillbirth-coded, vital status uncertain):", n_sb_discordant, "\n")
cat("Mortality cohort:", nrow(lb), "\n\n")

# ----------------------------------------------------------------------------
# Source overlap and date concordance
# ----------------------------------------------------------------------------

source_overlap <- lb %>% filter(Died) %>% count(Death_Source)
cat("Deaths by source:\n"); print(source_overlap)

both <- lb %>%
  filter(Died_MSDS, Died_APCS, !is.na(APCS_Death_Spell_Discharge_Date))
date_gap <- as.integer(as.Date(both$APCS_Death_Spell_Discharge_Date) -
                         as.Date(both$Baby_Death_Date))
concordance <- list(
  n_both_dates = length(date_gap),
  within_1_day = sum(abs(date_gap) <= 1),
  median_gap = median(date_gap)
)
cat(sprintf("\nDate concordance (both sources): %d of %d within 1 day (median gap %d days)\n\n",
            concordance$within_1_day, concordance$n_both_dates, concordance$median_gap))

# ----------------------------------------------------------------------------
# Crude rates per 1,000 with Wilson 95% CIs
# ----------------------------------------------------------------------------

wilson <- function(x, n, z = 1.96) {
  p <- x / n
  centre <- (p + z^2 / (2 * n)) / (1 + z^2 / n)
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / (1 + z^2 / n)
  tibble(lo = pmax(centre - half, 0), hi = centre + half)
}

rate_by <- function(data, grp) {
  data %>%
    filter(!is.na(.data[[grp]])) %>%
    group_by(across(all_of(grp))) %>%
    summarise(n = dplyr::n(), deaths = sum(Died), .groups = "drop") %>%
    bind_cols(wilson(.$deaths, .$n) * 1000) %>%
    mutate(rate = 1000 * deaths / n)
}

crude_overall <- lb %>%
  summarise(n = dplyr::n(),
            deaths = sum(Died),
            deaths_msds = sum(Died_MSDS),
            deaths_apcs = sum(Died_APCS),
            rate = 1000 * deaths / n)
crude_eth  <- rate_by(lb, "Ethnicity_Baby_Grouped")
crude_imd  <- rate_by(lb, "IMD_Quintile")
crude_gest <- rate_by(lb, "Gestation_Band")
crude_ncc  <- rate_by(lb, "NCC_Admitted")

cat("Overall:\n"); print(as.data.frame(crude_overall), digits = 3)
cat("\nCrude by gestation band:\n"); print(as.data.frame(crude_gest), digits = 3)
cat("\nCrude by NCC admission:\n");  print(as.data.frame(crude_ncc), digits = 3)
cat("\nCrude by ethnicity:\n");      print(as.data.frame(crude_eth), digits = 3)
cat("\nCrude by IMD quintile:\n");   print(as.data.frame(crude_imd), digits = 3)

# ----------------------------------------------------------------------------
# Indirect standardisation by gestation band (observed / expected)
# ----------------------------------------------------------------------------
# Expected deaths per group = sum over gestation bands of the national
# band-specific death rate x the group's births in that band. O/E > 1 means
# more deaths than the group's gestational mix predicts. Exact Poisson CIs
# via poisson.test; BH adjustment within each family.

std <- lb %>% filter(!is.na(Gestation_Band))
n_no_gest <- nrow(lb) - nrow(std)
deaths_no_gest <- sum(lb$Died[is.na(lb$Gestation_Band)])
cat(sprintf("\nStandardisation excludes %d babies with missing/invalid gestation (%d deaths)\n",
            n_no_gest, deaths_no_gest))

band_rates <- std %>%
  group_by(Gestation_Band) %>%
  summarise(band_rate = mean(Died), .groups = "drop")

oe_by <- function(data, grp, family) {
  data %>%
    filter(!is.na(.data[[grp]])) %>%
    left_join(band_rates, by = "Gestation_Band") %>%
    group_by(Group = .data[[grp]]) %>%
    summarise(n = dplyr::n(),
              observed = sum(Died),
              expected = sum(band_rate),
              .groups = "drop") %>%
    rowwise() %>%
    mutate(
      OE = observed / expected,
      lo = poisson.test(observed, T = expected)$conf.int[1],
      hi = poisson.test(observed, T = expected)$conf.int[2],
      p.value = poisson.test(observed, T = expected)$p.value
    ) %>%
    ungroup() %>%
    mutate(family = family, p.adj_BH = p.adjust(p.value, method = "BH"))
}

oe_eth <- oe_by(std, "Ethnicity_Baby_Grouped", "ethnicity")
oe_imd <- oe_by(std, "IMD_Quintile", "imd")

cat("\nGestation-standardised O/E by ethnicity:\n")
print(as.data.frame(oe_eth), digits = 3)
cat("\nGestation-standardised O/E by IMD quintile:\n")
print(as.data.frame(oe_imd), digits = 3)

# ----------------------------------------------------------------------------
# Follow-up truncation check (labour-admission month as birth-month proxy)
# ----------------------------------------------------------------------------
# The APCS window closes 30 Apr 2024, so a baby born in March 2024 has ~2
# months of in-window hospital observation vs ~13 for one born in April 2023.
# If truncation materially bit, recorded death rates would fall towards the
# end of the FY.

truncation <- lb %>%
  mutate(birth_month = format(as.Date(Mother_Admission_Date), "%Y-%m")) %>%
  filter(birth_month >= "2023-04", birth_month <= "2024-03") %>%
  group_by(birth_month) %>%
  summarise(n = dplyr::n(), deaths = sum(Died),
            rate = 1000 * deaths / n, .groups = "drop")

cat("\nDeath rate by birth month (truncation check):\n")
print(as.data.frame(truncation), digits = 3)

# ----------------------------------------------------------------------------
# Save compact summary for the report
# ----------------------------------------------------------------------------

a5b_summary <- list(
  n_fy = n_fy,
  n_live = n_live,
  n_sb_discordant = n_sb_discordant,
  n_cohort = nrow(lb),
  crude_overall = crude_overall,
  source_overlap = source_overlap,
  concordance = concordance,
  crude_eth = crude_eth,
  crude_imd = crude_imd,
  crude_gest = crude_gest,
  crude_ncc = crude_ncc,
  n_no_gest = n_no_gest,
  deaths_no_gest = deaths_no_gest,
  band_rates = band_rates,
  oe_eth = oe_eth,
  oe_imd = oe_imd,
  truncation = truncation,
  created = Sys.time()
)
saveRDS(a5b_summary, "data/a5b_mortality_summary.rds")
cat("\nSaved data/a5b_mortality_summary.rds\n")
