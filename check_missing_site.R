# ============================================================================
# Diagnose the 17% of babies with Delivery_Site_Code = NA
# ============================================================================
# Questions:
#  - Are these babies missing OrgCodeProvider too, or just the site field?
#  - Do they have a different NCC rate, ethnicity profile, or IMD profile
#    than the babies WITH a site code?
#  - If we used OrgCodeProvider as a fallback, how many would we recover?
# ============================================================================

library(tidyverse)

ncc <- readRDS("data/ncc_base_dataset.rds")
ncc <- ncc %>% mutate(no_site = is.na(Delivery_Site_Code))

cat("Cohort split by site availability:\n")
print(ncc %>% count(no_site))
cat("\n")

# --- Provider-level fallback availability ----------------------------------
provider_col <- intersect(c("Submitting_Org_Code", "OrgCodeProvider"), names(ncc))[1]
if (!is.na(provider_col)) {
  cat("Among babies with NO Delivery_Site_Code, how many have ",
      provider_col, "?\n", sep = "")
  print(ncc %>% filter(no_site) %>%
          summarise(
            n_total           = n(),
            has_provider_code = sum(!is.na(.data[[provider_col]])),
            pct_recoverable   = round(100 * mean(!is.na(.data[[provider_col]])), 1)
          ))
  cat("\n")

  cat("Distinct providers represented in the no-site cohort:\n")
  print(ncc %>% filter(no_site) %>%
          count(.data[[provider_col]], sort = TRUE) %>%
          slice_head(n = 15))
  cat("\n")
} else {
  cat("No provider-level column (Submitting_Org_Code / OrgCodeProvider) found.\n\n")
}

# --- NCC rate comparison ---------------------------------------------------
cat("NCC admission rate by site-availability:\n")
print(ncc %>% group_by(no_site) %>%
        summarise(
          n         = n(),
          ncc       = sum(NCC_Admitted, na.rm = TRUE),
          ncc_rate  = round(100 * mean(NCC_Admitted, na.rm = TRUE), 2)
        ))
cat("\n")

# --- Ethnicity profile -----------------------------------------------------
cat("Ethnicity composition (% within group):\n")
eth_compare <- ncc %>%
  count(no_site, Ethnic_Category_Baby) %>%
  group_by(no_site) %>%
  mutate(pct = round(100 * n / sum(n), 1)) %>%
  ungroup() %>%
  pivot_wider(names_from = no_site, values_from = c(n, pct),
              names_glue = "{ifelse(no_site, 'no_site', 'with_site')}_{.value}")
print(eth_compare, n = 30)
cat("\n")

# --- IMD profile -----------------------------------------------------------
cat("IMD profile (% within group):\n")
imd_compare <- ncc %>%
  count(no_site, IMD_Decile_2015) %>%
  group_by(no_site) %>%
  mutate(pct = round(100 * n / sum(n), 1)) %>%
  ungroup() %>%
  pivot_wider(names_from = no_site, values_from = c(n, pct),
              names_glue = "{ifelse(no_site, 'no_site', 'with_site')}_{.value}")
print(imd_compare, n = 12)
cat("\n")

# --- Gestation completeness in the no-site group ---------------------------
cat("Clinical-covariate completeness within no-site group:\n")
print(ncc %>% filter(no_site) %>%
        summarise(
          gestation = round(100 * mean(!is.na(Gestation_Length_At_Birth)), 1),
          birth_wt  = round(100 * mean(!is.na(Birth_Weight_Grams)), 1),
          apgar_5   = round(100 * mean(!is.na(Apgar_Score_5_Minutes)), 1)
        ))
