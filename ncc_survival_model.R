# ============================================================================
# NCC Access Inequalities - Survival / Frailty Model
# ============================================================================
# Outcome: Time from birth to NCC admission (hours)
# Event: NCC admission
# Censoring: Discharge, death without NCC, or 28-day window
# Competing risk: Death before NCC admission
#
# STRUCTURE:
#   1. Descriptive: Kaplan-Meier curves by ethnicity (unadjusted)
#   2. Cox frailty model: Clinical adjustment + hospital random effects
#   3. Proportional hazards diagnostics
#   4. Competing risks sensitivity (Fine-Gray)
#
# NOTE: HR > 1 = faster admission (event sooner), HR < 1 = slower (delay)
#       This is the opposite intuition to odds ratios.
# ============================================================================

library(tidyverse)
library(bit64)
library(readxl)
library(survival)
library(coxme)        # Cox model with random effects (frailty)
library(survminer)    # KM plot helpers (ggsurvplot)

# ============================================================================
# 1. LOAD AND PREPARE DATA
# ============================================================================

ncc_data <- readRDS("data/ncc_base_dataset.rds")
cat("Loaded", nrow(ncc_data), "records\n\n")

# ----------------------------------------------------------------------------
# Build survival dataset
# ----------------------------------------------------------------------------
# Every birth enters the risk set at time 0 (birth).
# Event = NCC admission. Time measured in hours.
# Censored at: discharge, death (without NCC), or 28 days (672 hours).
#
# Event time for admitted babies comes from Hours_Birth_To_First_CC, the
# SQL-derived unified field. It prefers MSDS (minute resolution, single
# ranked CC-flagged transfer row) and falls back to PbR (day resolution).
# Negative raw values are floored to 0 in SQL.
#
# We deliberately AVOID reconstructing the datetime in R from
# NCC_CC_First_Admission_Date/Time — PbR_CC_Monthly has NULL CC_Start_Time
# for NCC records, so every PbR-only admission would default to midnight
# and overwhelm the minute-resolution MSDS source.
# ----------------------------------------------------------------------------

surv_data <- ncc_data %>%
  mutate(
    # --- Event indicator ---
    # 0 = censored (no NCC admission observed)
    # 1 = NCC admission
    # 2 = death before NCC (competing risk)
    event = case_when(
      NCC_Admitted == 1 ~ 1L,
      !is.na(Baby_Death_Date) & (is.na(NCC_CC_First_Admission_Date)) ~ 2L,
      TRUE ~ 0L
    ),

    # Birth datetime (used for censoring/competing-risk time arithmetic)
    Birth_DT = as.POSIXct(
      paste(Baby_Birth_Date, ifelse(is.na(Baby_Birth_Time), "00:00:00", Baby_Birth_Time)),
      format = "%Y-%m-%d %H:%M:%S"
    ),

    # Censoring datetime (discharge or death, whichever comes first)
    Censor_DT = pmin(
      as.POSIXct(Baby_Discharge_Date, format = "%Y-%m-%d"),
      as.POSIXct(Baby_Death_Date, format = "%Y-%m-%d"),
      na.rm = TRUE
    ),

    Time_To_NCC_Hours = case_when(
      # Admitted: use SQL-derived unified hours (MSDS preferred, PbR fallback)
      event == 1 & !is.na(Hours_Birth_To_First_CC) ~
        as.numeric(Hours_Birth_To_First_CC),
      # Admitted with no timing at all: NA (excluded downstream)
      event == 1 ~ NA_real_,
      # Death before NCC (competing risk)
      event == 2 & !is.na(Baby_Death_Date) & !is.na(Birth_DT) ~
        as.numeric(difftime(as.POSIXct(Baby_Death_Date), Birth_DT, units = "hours")),
      # Censored (no NCC): time to discharge/death
      !is.na(Censor_DT) & !is.na(Birth_DT) ~
        as.numeric(difftime(Censor_DT, Birth_DT, units = "hours")),
      TRUE ~ NA_real_
    ),

    # Cap at 28 days (672 hours) — anything beyond is not clinically
    # meaningful for "access to NCC" and avoids long-tail distortion
    Time_To_NCC_Hours = pmin(Time_To_NCC_Hours, 672),

    # If time is missing, cap at 672 (administrative censoring)
    Time_To_NCC_Hours = ifelse(is.na(Time_To_NCC_Hours), 672, Time_To_NCC_Hours),

    # Fix negative or zero times (same-hour admission = set to 0.1 hours / 6 min)
    Time_To_NCC_Hours = ifelse(Time_To_NCC_Hours <= 0, 0.1, Time_To_NCC_Hours),

    # If time > 672 and event = 1, censor instead (NCC admission > 28 days
    # post birth is likely a data linkage artefact, not acute NCC access)
    event = ifelse(Time_To_NCC_Hours >= 672 & event == 1, 0L, event)
  ) %>%

  # --- Clean covariates (same as logistic model for consistency) ---
  mutate(
    Gestation_Days = as.integer(Gestation_Length_At_Birth),
    Gestation_Weeks = Gestation_Days / 7,
    Gestation_Weeks = case_when(
      Gestation_Weeks < 22 ~ NA_real_,
      Gestation_Weeks > 44 ~ NA_real_,
      TRUE ~ Gestation_Weeks
    ),

    Birth_Weight_Clean = case_when(
      Birth_Weight_Grams < 200 ~ NA_real_,
      Birth_Weight_Grams > 6000 ~ NA_real_,
      TRUE ~ as.numeric(Birth_Weight_Grams)
    ),
    Birth_Weight_kg = Birth_Weight_Clean / 1000,

    Apgar_5_Clean = case_when(
      Apgar_Score_5_Minutes < 0 ~ NA_integer_,
      Apgar_Score_5_Minutes > 10 ~ NA_integer_,
      TRUE ~ as.integer(Apgar_Score_5_Minutes)
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
      Ethnic_Category_Baby %in% c("Z", "99", "") ~ NA_character_,
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
    IMD_Quintile = factor(IMD_Quintile, levels = c("5 - Least deprived", "4", "3", "2", "1 - Most deprived")),

    Delivery_Site = factor(Delivery_Site_Code)
  )

# ----------------------------------------------------------------------------
# Map delivery sites to NNAP neonatal units and unit types
# ----------------------------------------------------------------------------
# The NNAP mapping links ODS trust codes to recognised neonatal units and
# their designation (NICU / LNU / SCBU). We use this to:
#   (a) Filter to births at hospitals with a recognised NNAP neonatal unit
#   (b) Include unit type as a covariate in the conditional timing models
#
# Mapping: Delivery_Site_Code -> parent trust (via ODS) -> NNAP unit type
# For trusts with multiple units, we use the highest designation level
# (NICU > LNU > SCBU), since NCC admissions route to the highest available.
# ----------------------------------------------------------------------------

cat("--- Linking delivery sites to NNAP neonatal units ---\n\n")

# ODS trust sites: maps site codes to parent trust codes
ods_sites <- read_csv("data/ods_trust_sites.csv", col_names = FALSE, show_col_types = FALSE) %>%
  select(site_code = X1, trust_code = X15)

# NNAP mapping: trust code -> unit type(s)
nnap_mapping <- read_csv("data/ncc_provider_to_nnap_mapping.csv", show_col_types = FALSE)

# Get highest unit type per trust (NICU=3, LNU=2, SCBU=1)
nnap_trust_level <- nnap_mapping %>%
  mutate(unit_rank = case_when(
    unit_type == "NICU" ~ 3L, unit_type == "LNU" ~ 2L, unit_type == "SCBU" ~ 1L
  )) %>%
  group_by(trust_code) %>%
  summarise(
    highest_unit_type = unit_type[which.max(unit_rank)],
    ODN = first(ODN),
    n_nnap_units = n(),
    .groups = "drop"
  )

# Join: delivery site -> trust -> NNAP unit type
surv_data <- surv_data %>%
  left_join(ods_sites, by = c("Delivery_Site_Code" = "site_code")) %>%
  left_join(nnap_trust_level, by = "trust_code") %>%
  mutate(
    At_NNAP_Trust = !is.na(highest_unit_type),
    Delivery_Unit_Type = factor(highest_unit_type, levels = c("NICU", "LNU", "SCBU"))
  )

cat("NNAP linkage summary:\n")
cat("  Total births:", nrow(surv_data), "\n")
cat("  At NNAP trusts:", sum(surv_data$At_NNAP_Trust, na.rm = TRUE),
    "(", round(100 * mean(surv_data$At_NNAP_Trust, na.rm = TRUE), 1), "%)\n")
cat("  Missing delivery site:", sum(is.na(surv_data$Delivery_Site_Code)), "\n\n")

cat("Delivery site unit type (among births at NNAP trusts):\n")
print(table(surv_data$Delivery_Unit_Type, useNA = "ifany"))

cat("\nNCC admissions by delivery unit type:\n")
surv_data %>%
  filter(event == 1, At_NNAP_Trust) %>%
  count(Delivery_Unit_Type) %>%
  mutate(pct = round(100 * n / sum(n), 1)) %>%
  print()
cat("\n")


# ============================================================================
# 2. DESCRIPTIVE SUMMARY OF TIME VARIABLE
# ============================================================================

cat("=== SURVIVAL DATA SUMMARY ===\n\n")

# Diagnostic: how many admitted babies had no NCC timing data?
n_admitted_no_time <- sum(surv_data$NCC_Admitted == 1 & is.na(surv_data$Time_To_NCC_Hours) |
                          (surv_data$NCC_Admitted == 1 & surv_data$event == 0), na.rm = TRUE)
cat("NCC timing data quality:\n")
cat("  Admitted babies with no NCC datetime (excluded/censored):", n_admitted_no_time, "\n")
cat("  These had neither CC nor MSDS admission dates and were excluded\n")
cat("  from the survival analysis to avoid confusing discharge time\n")
cat("  with NCC admission time.\n\n")

cat("Event distribution:\n")
print(table(surv_data$event, useNA = "ifany"))
cat("  0 = censored (no NCC), 1 = NCC admitted, 2 = died before NCC\n\n")

ncc_times <- surv_data %>% filter(event == 1)
cat("Time to NCC admission (hours) among admitted babies:\n")
cat("  N:      ", nrow(ncc_times), "\n")
cat("  Median: ", round(median(ncc_times$Time_To_NCC_Hours), 1), "hours\n")
cat("  Mean:   ", round(mean(ncc_times$Time_To_NCC_Hours), 1), "hours\n")
cat("  IQR:    ", round(quantile(ncc_times$Time_To_NCC_Hours, 0.25), 1), "-",
    round(quantile(ncc_times$Time_To_NCC_Hours, 0.75), 1), "hours\n")
cat("  <=1h:   ", round(100 * mean(ncc_times$Time_To_NCC_Hours <= 1), 1), "%\n")
cat("  <=6h:   ", round(100 * mean(ncc_times$Time_To_NCC_Hours <= 6), 1), "%\n")
cat("  <=24h:  ", round(100 * mean(ncc_times$Time_To_NCC_Hours <= 24), 1), "%\n")
cat("  <=72h:  ", round(100 * mean(ncc_times$Time_To_NCC_Hours <= 72), 1), "%\n\n")

# Time to NCC by ethnicity (descriptive)
cat("Median hours to NCC by ethnicity:\n")
ncc_times %>%
  filter(!is.na(Ethnicity_Baby_Grouped)) %>%
  group_by(Ethnicity_Baby_Grouped) %>%
  summarise(
    n = n(),
    median_hours = round(median(Time_To_NCC_Hours), 1),
    q25 = round(quantile(Time_To_NCC_Hours, 0.25), 1),
    q75 = round(quantile(Time_To_NCC_Hours, 0.75), 1),
    pct_within_1h = round(100 * mean(Time_To_NCC_Hours <= 1), 1),
    .groups = "drop"
  ) %>%
  print(n = 20)


# ============================================================================
# 3. KAPLAN-MEIER CURVES BY ETHNICITY (UNADJUSTED)
# ============================================================================
#
# IMPORTANT: With only ~13% of all births admitted to NCC, an all-births KM
# curve sits at ~0.87-1.0 and ethnicity differences are invisible.
#
# Instead we produce TWO informative plots:
#   Plot 1: Among NCC-admitted babies — KM of time to admission by ethnicity
#           (directly answers "do some groups wait longer?")
#   Plot 2: Among high-risk babies (preterm <37 weeks) — where ~50%+ are
#           admitted, making curves readable and clinically meaningful
#
# The Cox model (section 4) still uses ALL births for proper inference.
# ============================================================================

cat("\n\n========================================\n")
cat("KAPLAN-MEIER CURVES BY ETHNICITY\n")
cat("========================================\n\n")

nhs_blue <- "#005EB8"
nhs_pink <- "#AE2573"

# Custom colour palette for ethnicity groups
# survminer maps palette by position (matching factor level order), not by name
eth_colours <- c(
  "#005EB8",   # White British - NHS blue
  "#41B6E6",   # White Other - NHS light blue
  "#768692",   # Mixed - NHS grey
  "#009639",   # Indian - NHS green
  "#006747",   # Pakistani - Dark green
  "#00A499",   # Bangladeshi - Teal
  "#78BE20",   # Other Asian - Light green
  "#AE2573",   # Black - NHS pink
  "#ED8B00",   # Chinese - NHS orange
  "#8A1538"    # Other - NHS dark pink
)

# --- Plot 1: Among NCC-admitted babies only ---
# This answers: "Among babies who ARE admitted to NCC, how quickly are they
# admitted, and does this differ by ethnicity?"
# Here ALL babies have the event — those admitted quickly vs those with delays.
# We right-censor at 72 hours to focus on the acute access window.

km_admitted <- surv_data %>%
  filter(
    event == 1,  # only NCC-admitted babies
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Time_To_NCC_Hours),
    Time_To_NCC_Hours > 0
  ) %>%
  mutate(
    # Cap at 72h for visualisation; censor beyond that
    Time_Plot = pmin(Time_To_NCC_Hours, 72),
    Event_Plot = ifelse(Time_To_NCC_Hours <= 72, 1L, 0L)
  ) %>%
  droplevels()

cat("Plot 1: NCC-admitted babies\n")
cat("  N:", nrow(km_admitted), "\n")
cat("  Ethnicity groups:", paste(levels(km_admitted$Ethnicity_Baby_Grouped), collapse = ", "), "\n\n")

km_fit_admitted <- survfit(
  Surv(Time_Plot, Event_Plot) ~ Ethnicity_Baby_Grouped,
  data = km_admitted
)

pdf("data/km_curves_admitted.pdf", width = 12, height = 8)

p_km_admitted <- ggsurvplot(
  km_fit_admitted,
  data = km_admitted,
  fun = "event",             # Plot CUMULATIVE INCIDENCE (1 - S(t))
  xlim = c(0, 72),
  break.x.by = 6,
  conf.int = FALSE,
  palette = eth_colours,
  legend.title = "Ethnicity",
  legend.labs = levels(km_admitted$Ethnicity_Baby_Grouped),
  xlab = "Hours from birth",
  ylab = "Cumulative proportion admitted to NCC",
  title = "Time to NCC Admission by Ethnicity (Among Admitted Babies)",
  subtitle = "FY 2023/24. Higher curve = faster admission. All babies shown were admitted to NCC.",
  risk.table = FALSE,
  ggtheme = theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      legend.position = "right"
    )
)
print(p_km_admitted)

dev.off()
cat("Saved: data/km_curves_admitted.pdf\n")

# --- Plot 2: Zoomed first 24 hours (where most action is) ---
pdf("data/km_curves_admitted_24h.pdf", width = 12, height = 8)

p_km_admitted_zoom <- ggsurvplot(
  km_fit_admitted,
  data = km_admitted,
  fun = "event",
  xlim = c(0, 24),
  break.x.by = 2,
  conf.int = FALSE,
  palette = eth_colours,
  legend.title = "Ethnicity",
  legend.labs = levels(km_admitted$Ethnicity_Baby_Grouped),
  xlab = "Hours from birth",
  ylab = "Cumulative proportion admitted to NCC",
  title = "Time to NCC Admission by Ethnicity (First 24 Hours, Admitted Babies)",
  subtitle = "FY 2023/24. Higher curve = faster admission.",
  risk.table = FALSE,
  ggtheme = theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      legend.position = "right"
    )
)
print(p_km_admitted_zoom)

dev.off()
cat("Saved: data/km_curves_admitted_24h.pdf\n")

# Log-rank test (among admitted babies)
lr_admitted <- survdiff(
  Surv(Time_Plot, Event_Plot) ~ Ethnicity_Baby_Grouped,
  data = km_admitted
)
cat("\nLog-rank test (among NCC-admitted babies):\n")
print(lr_admitted)
cat("p-value:", format.pval(1 - pchisq(lr_admitted$chisq, length(lr_admitted$n) - 1)), "\n")

# --- Plot 3: High-risk subgroup (preterm <37 weeks) ---
# Among preterm babies a much larger proportion are admitted to NCC,
# making the all-births KM curves readable. This also shows the
# access picture for the population where NCC is most critical.

km_preterm <- surv_data %>%
  filter(
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Time_To_NCC_Hours),
    !is.na(Gestation_Weeks),
    Gestation_Weeks < 37,
    Time_To_NCC_Hours > 0
  ) %>%
  mutate(
    event_binary = ifelse(event == 1, 1L, 0L),
    Time_Plot = pmin(Time_To_NCC_Hours, 72),
    Event_Plot = ifelse(event == 1 & Time_To_NCC_Hours <= 72, 1L, 0L)
  ) %>%
  droplevels()

cat("\n\nPlot 3: Preterm babies (<37 weeks)\n")
cat("  N:", nrow(km_preterm), "\n")
cat("  NCC admitted:", sum(km_preterm$event_binary), "(", round(100 * mean(km_preterm$event_binary), 1), "%)\n\n")

km_fit_preterm <- survfit(
  Surv(Time_Plot, Event_Plot) ~ Ethnicity_Baby_Grouped,
  data = km_preterm
)

pdf("data/km_curves_preterm.pdf", width = 12, height = 8)

p_km_preterm <- ggsurvplot(
  km_fit_preterm,
  data = km_preterm,
  fun = "event",
  xlim = c(0, 72),
  break.x.by = 6,
  conf.int = FALSE,
  palette = eth_colours,
  legend.title = "Ethnicity",
  legend.labs = levels(km_preterm$Ethnicity_Baby_Grouped),
  xlab = "Hours from birth",
  ylab = "Cumulative proportion admitted to NCC",
  title = "Time to NCC Admission by Ethnicity (Preterm Babies <37 Weeks)",
  subtitle = "FY 2023/24. Higher curve = faster admission to NCC.",
  risk.table = FALSE,
  ggtheme = theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      legend.position = "right"
    )
)
print(p_km_preterm)

dev.off()
cat("Saved: data/km_curves_preterm.pdf\n")

# Log-rank test (preterm)
lr_preterm <- survdiff(
  Surv(Time_Plot, Event_Plot) ~ Ethnicity_Baby_Grouped,
  data = km_preterm
)
cat("\nLog-rank test (preterm babies):\n")
print(lr_preterm)
cat("p-value:", format.pval(1 - pchisq(lr_preterm$chisq, length(lr_preterm$n) - 1)), "\n")

# Keep full km_data for the summary table later
km_data <- surv_data %>%
  filter(
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Time_To_NCC_Hours),
    Time_To_NCC_Hours > 0
  ) %>%
  mutate(event_binary = ifelse(event == 1, 1L, 0L))


# ============================================================================
# 3b. CLEAN KM PLOTS — BROAD ETHNICITY, HOURLY STEPS
# ============================================================================
# Interpretation: Among admitted babies (who we KNOW needed NCC), what
# proportion are STILL WAITING for admission at each time point?
# Curve starts at 100% and steps down — faster drop = faster access.
#
# Time is rounded up to the nearest hour (ceiling). This gives classic
# KM step-function aesthetics — big drops in early hours where most
# admissions cluster, then a long flattening tail.
#
# Plot A: Broad groups — White / Asian / Black / Mixed & Other
# Plot B: Asian disaggregation — White (ref) + Indian / Pakistani /
#         Bangladeshi / Other Asian / Chinese
# ============================================================================

cat("\n\n========================================\n")
cat("CLEAN KM PLOTS — HOURLY STEPS, BROAD GROUPS\n")
cat("========================================\n\n")

# --- Prepare admitted-babies data with binned time ---
km_clean <- surv_data %>%
  filter(
    event == 1,                         # admitted babies only
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Time_To_NCC_Hours),
    Time_To_NCC_Hours > 0,
    Time_To_NCC_Hours <= 72             # within acute access window
  ) %>%
  mutate(
    # Broad ethnicity groups
    Ethnicity_Broad = case_when(
      Ethnicity_Baby_Grouped %in% c("White British", "White Other") ~ "White",
      Ethnicity_Baby_Grouped %in% c("Indian", "Pakistani", "Bangladeshi",
                                     "Other Asian", "Chinese") ~ "Asian",
      Ethnicity_Baby_Grouped == "Black" ~ "Black",
      Ethnicity_Baby_Grouped %in% c("Mixed", "Other") ~ "Mixed & Other"
    ),
    Ethnicity_Broad = factor(Ethnicity_Broad,
                              levels = c("White", "Asian", "Black", "Mixed & Other")),

    # Round up to nearest hour — gives classic KM step shape
    Time_Binned = ceiling(Time_To_NCC_Hours)
  )

cat("Admitted babies (within 72h):", nrow(km_clean), "\n\n")
cat("By broad group:\n")
print(table(km_clean$Ethnicity_Broad))
cat("\n")

# --- Plot A: Broad ethnicity groups (4 curves) ---
km_fit_broad <- survfit(
  Surv(Time_Binned, rep(1L, nrow(km_clean))) ~ Ethnicity_Broad,
  data = km_clean
)

broad_colours <- c(
  "#005EB8",   # White - NHS blue
  "#009639",   # Asian - NHS green
  "#AE2573",   # Black - NHS pink
  "#768692"    # Mixed & Other - NHS grey
)

p_broad <- ggsurvplot(
  km_fit_broad,
  data = km_clean,
  # Standard survival orientation: starts at 1.0, steps down
  xlim = c(0, 72),
  ylim = c(0, 1),
  conf.int = TRUE,
  conf.int.alpha = 0.12,
  palette = broad_colours,
  legend.title = "Ethnicity",
  legend.labs = levels(km_clean$Ethnicity_Broad),
  xlab = "Hours from birth",
  ylab = "Proportion still awaiting NCC admission",
  title = "Time to NCC Admission by Broad Ethnicity Group",
  subtitle = paste0(
    "FY 2023/24 | N = ", format(nrow(km_clean), big.mark = ","),
    " admitted babies | Lower curve = faster access"
  ),
  risk.table = FALSE,
  ggtheme = theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(size = 10, colour = "grey40"),
      legend.position = "right"
    )
)

# Custom x-axis breaks at bin boundaries
p_broad$plot <- p_broad$plot +
  scale_x_continuous(breaks = c(0, 1, 6, 12, 24, 48, 72))

ggsave("data/km_broad_ethnicity.pdf", p_broad$plot, width = 10, height = 7)
cat("Saved: data/km_broad_ethnicity.pdf\n")


# --- Plot B: Asian disaggregation (White as reference + Asian subgroups) ---
km_asian <- surv_data %>%
  filter(
    event == 1,
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Time_To_NCC_Hours),
    Time_To_NCC_Hours > 0,
    Time_To_NCC_Hours <= 72,
    Ethnicity_Baby_Grouped %in% c("White British", "Indian", "Pakistani",
                                   "Bangladeshi", "Other Asian", "Chinese")
  ) %>%
  mutate(
    Ethnicity_Asian = factor(
      as.character(Ethnicity_Baby_Grouped),
      levels = c("White British", "Indian", "Pakistani",
                 "Bangladeshi", "Other Asian", "Chinese")
    ),
    Time_Binned = ceiling(Time_To_NCC_Hours)
  ) %>%
  droplevels()

cat("\nPlot B: Asian disaggregation\n")
cat("  N:", nrow(km_asian), "\n")
print(table(km_asian$Ethnicity_Asian))
cat("\n")

km_fit_asian <- survfit(
  Surv(Time_Binned, rep(1L, nrow(km_asian))) ~ Ethnicity_Asian,
  data = km_asian
)

asian_colours <- c(
  "#005EB8",   # White British - NHS blue (reference)
  "#009639",   # Indian - NHS green
  "#006747",   # Pakistani - dark green
  "#00A499",   # Bangladeshi - teal
  "#78BE20",   # Other Asian - light green
  "#ED8B00"    # Chinese - NHS orange
)

p_asian <- ggsurvplot(
  km_fit_asian,
  data = km_asian,
  xlim = c(0, 72),
  ylim = c(0, 1),
  conf.int = TRUE,
  conf.int.alpha = 0.12,
  palette = asian_colours,
  legend.title = "Ethnicity",
  legend.labs = levels(km_asian$Ethnicity_Asian),
  xlab = "Hours from birth",
  ylab = "Proportion still awaiting NCC admission",
  title = "Time to NCC Admission: Asian Subgroups vs White British",
  subtitle = paste0(
    "FY 2023/24 | N = ", format(nrow(km_asian), big.mark = ","),
    " admitted babies | Lower curve = faster access"
  ),
  risk.table = FALSE,
  ggtheme = theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(size = 10, colour = "grey40"),
      legend.position = "right"
    )
)

p_asian$plot <- p_asian$plot +
  scale_x_continuous(breaks = c(0, 1, 6, 12, 24, 48, 72))

ggsave("data/km_asian_disaggregation.pdf", p_asian$plot, width = 10, height = 7)
cat("Saved: data/km_asian_disaggregation.pdf\n")


# ============================================================================
# 4. COX FRAILTY MODEL
# ============================================================================

cat("\n\n========================================\n")
cat("COX FRAILTY MODEL\n")
cat("========================================\n\n")

# Primary analysis dataset: gestation + ethnicity + IMD + hospital frailty
# (Matches Model 2 from logistic analysis for comparability)
cox_data <- surv_data %>%
  filter(
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Gestation_Weeks),
    !is.na(IMD_Quintile),
    !is.na(Delivery_Site),
    !is.na(Time_To_NCC_Hours),
    Time_To_NCC_Hours > 0,
    event %in% c(0, 1)  # exclude competing deaths for primary analysis
  ) %>%
  mutate(event_binary = ifelse(event == 1, 1L, 0L)) %>%
  droplevels()

cat("Cox analysis dataset:", nrow(cox_data), "births\n")
cat("Events (NCC admissions):", sum(cox_data$event_binary), "\n")
cat("Delivery sites:", length(unique(cox_data$Delivery_Site)), "\n\n")

# ---- Model 4: Cox with shared frailty for delivery site ----
cat("Fitting Cox frailty model (gestation + ethnicity + IMD + hospital frailty)...\n")
cat("(This may take a few minutes with ~500k records)\n\n")

model4_cox <- coxme(
  Surv(Time_To_NCC_Hours, event_binary) ~
    Gestation_Weeks + Ethnicity_Baby_Grouped + IMD_Quintile +
    (1 | Delivery_Site),
  data = cox_data
)

cat("Model 4: Cox frailty model\n")
print(model4_cox)

# Extract fixed effects as hazard ratios
fe4 <- fixef(model4_cox)
# coxme vcov returns the variance-covariance matrix
vcov4 <- as.matrix(vcov(model4_cox))
se4 <- sqrt(diag(vcov4))

hr_table <- data.frame(
  term = names(fe4),
  HR = exp(fe4),
  CI_lower = exp(fe4 - 1.96 * se4),
  CI_upper = exp(fe4 + 1.96 * se4),
  z = fe4 / se4,
  p.value = 2 * pnorm(-abs(fe4 / se4))
)

cat("\n\nHazard Ratios (Model 4 - Cox Frailty):\n")
cat("NOTE: HR > 1 = FASTER admission, HR < 1 = SLOWER admission (potential delay)\n\n")
hr_print <- hr_table %>%
  mutate(across(c(HR, CI_lower, CI_upper, p.value), ~ round(.x, 3))) %>%
  select(term, HR, CI_lower, CI_upper, p.value)
print(hr_print)


# ---- Model 5: Sensitivity — add birth weight + Apgar ----
cat("\n\n========================================\n")
cat("MODEL 5: Sensitivity - Full clinical adjustment\n")
cat("========================================\n\n")

cox_data_full <- surv_data %>%
  filter(
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Gestation_Weeks),
    !is.na(Birth_Weight_kg),
    !is.na(Apgar_5_Clean),
    !is.na(IMD_Quintile),
    !is.na(Delivery_Site),
    !is.na(Time_To_NCC_Hours),
    Time_To_NCC_Hours > 0,
    event %in% c(0, 1)
  ) %>%
  mutate(event_binary = ifelse(event == 1, 1L, 0L)) %>%
  droplevels()

cat("Sensitivity dataset:", nrow(cox_data_full), "births\n")
cat("Events (NCC admissions):", sum(cox_data_full$event_binary), "\n\n")

cat("Fitting sensitivity Cox frailty model...\n\n")

model5_cox <- coxme(
  Surv(Time_To_NCC_Hours, event_binary) ~
    Gestation_Weeks + Birth_Weight_kg + Apgar_5_Clean +
    Ethnicity_Baby_Grouped + IMD_Quintile +
    (1 | Delivery_Site),
  data = cox_data_full
)

cat("Model 5: Cox frailty model (sensitivity)\n")
print(model5_cox)

fe5 <- fixef(model5_cox)
vcov5 <- as.matrix(vcov(model5_cox))
se5 <- sqrt(diag(vcov5))

hr_table_sens <- data.frame(
  term = names(fe5),
  HR = exp(fe5),
  CI_lower = exp(fe5 - 1.96 * se5),
  CI_upper = exp(fe5 + 1.96 * se5),
  z = fe5 / se5,
  p.value = 2 * pnorm(-abs(fe5 / se5))
)

cat("\n\nHazard Ratios (Model 5 - Sensitivity):\n")
hr_print_sens <- hr_table_sens %>%
  mutate(across(c(HR, CI_lower, CI_upper, p.value), ~ round(.x, 3))) %>%
  select(term, HR, CI_lower, CI_upper, p.value)
print(hr_print_sens)


# ============================================================================
# 5. COMPARE PRIMARY VS SENSITIVITY (ETHNICITY HAZARD RATIOS)
# ============================================================================

cat("\n\n========================================\n")
cat("COMPARISON: Primary vs Sensitivity Cox Models\n")
cat("========================================\n\n")

eth_terms <- grep("Ethnicity", names(fe4), value = TRUE)

cat("Ethnicity Hazard Ratios:\n")
cat(sprintf("%-25s %10s %10s %10s\n", "Group", "Primary HR", "Sens. HR", "Difference"))
cat(paste(rep("-", 58), collapse = ""), "\n")

for (term in eth_terms) {
  primary_hr <- exp(fe4[term])
  sens_hr <- exp(fe5[term])
  diff <- sens_hr - primary_hr
  cat(sprintf("%-25s %10.3f %10.3f %+10.3f\n",
              gsub("Ethnicity_Baby_Grouped", "", term),
              primary_hr, sens_hr, diff))
}


# ============================================================================
# 6. PROPORTIONAL HAZARDS DIAGNOSTICS
# ============================================================================

cat("\n\n========================================\n")
cat("PROPORTIONAL HAZARDS DIAGNOSTICS\n")
cat("========================================\n\n")

# coxme doesn't support cox.zph directly, so fit an equivalent coxph
# (without frailty) for diagnostics — the PH assumption applies to
# fixed effects regardless of frailty structure
cat("Fitting standard coxph for PH diagnostics (no frailty)...\n")

model4_coxph <- coxph(
  Surv(Time_To_NCC_Hours, event_binary) ~
    Gestation_Weeks + Ethnicity_Baby_Grouped + IMD_Quintile,
  data = cox_data,
  ties = "efron"
)

ph_test <- cox.zph(model4_coxph)
cat("\nSchoenfeld residual test for proportional hazards:\n")
print(ph_test)

cat("\nInterpretation:\n")
cat("  p < 0.05 suggests the proportional hazards assumption may be violated\n")
cat("  for that covariate. With large N, even trivial departures are significant.\n")
cat("  Examine the magnitude of rho (correlation with time) — |rho| > 0.1 is\n")
cat("  more practically concerning than p-values alone.\n\n")

# Save PH diagnostic plots
pdf("data/ph_diagnostics.pdf", width = 12, height = 10)
par(mfrow = c(3, 4))
plot(ph_test)
dev.off()
cat("Saved: data/ph_diagnostics.pdf\n")


# ============================================================================
# 7. FOREST PLOT OF HAZARD RATIOS
# ============================================================================

cat("\n\n========================================\n")
cat("GENERATING FOREST PLOT\n")
cat("========================================\n\n")

# Prepare data for forest plot (primary model)
forest_data <- hr_table %>%
  filter(!grepl("Gestation_Weeks", term)) %>%
  mutate(
    term = gsub("Ethnicity_Baby_Grouped", "Ethnicity: ", term),
    term = gsub("IMD_Quintile", "IMD: ", term),
    category = ifelse(grepl("Ethnicity", term), "Ethnicity", "Deprivation"),
    term = factor(term, levels = rev(term))
  )

p_forest <- ggplot(forest_data, aes(x = HR, y = term, colour = category)) +
  geom_vline(xintercept = 1, linetype = "dashed", colour = "grey50") +
  geom_errorbarh(aes(xmin = CI_lower, xmax = CI_upper), height = 0.2, linewidth = 0.8) +
  geom_point(size = 3) +
  scale_colour_manual(values = c("Ethnicity" = "#005EB8", "Deprivation" = "#AE2573")) +
  facet_grid(category ~ ., scales = "free_y", space = "free_y") +
  labs(
    title = "Hazard Ratios for Time to NCC Admission (Cox Frailty Model)",
    subtitle = "HR > 1 = faster admission; HR < 1 = slower (potential delay). Ref: White British / Least Deprived.",
    x = "Hazard Ratio (95% CI)",
    y = NULL
  ) +
  theme_minimal() +
  theme(
    legend.position = "none",
    plot.title = element_text(face = "bold", size = 14),
    strip.text = element_text(face = "bold"),
    panel.grid.minor = element_blank()
  )

ggsave("data/forest_plot_hr.pdf", p_forest, width = 10, height = 7)
cat("Saved: data/forest_plot_hr.pdf\n")


# ============================================================================
# 8. SUMMARY TABLE: PROPORTION ADMITTED BY TIME WINDOW AND ETHNICITY
# ============================================================================

cat("\n\n========================================\n")
cat("CLINICIAN-FRIENDLY SUMMARY TABLE\n")
cat("========================================\n\n")

cat("Percentage of babies admitted to NCC by time window and ethnicity:\n")
cat("(Among all births — shows both rate and speed of admission)\n\n")

summary_table <- km_data %>%
  filter(!is.na(Ethnicity_Baby_Grouped)) %>%
  group_by(Ethnicity_Baby_Grouped) %>%
  summarise(
    Total_Births = n(),
    NCC_n = sum(event_binary),
    NCC_Rate_Pct = round(100 * mean(event_binary), 1),
    Admitted_1h = round(100 * sum(event_binary == 1 & Time_To_NCC_Hours <= 1) / n(), 2),
    Admitted_6h = round(100 * sum(event_binary == 1 & Time_To_NCC_Hours <= 6) / n(), 2),
    Admitted_24h = round(100 * sum(event_binary == 1 & Time_To_NCC_Hours <= 24) / n(), 2),
    Admitted_72h = round(100 * sum(event_binary == 1 & Time_To_NCC_Hours <= 72) / n(), 2),
    .groups = "drop"
  )

print(summary_table, n = 20, width = Inf)


# ============================================================================
# 8b. CONDITIONAL TIMING MODELS (ADMITTED BABIES ONLY, NNAP UNITS)
# ============================================================================
# KEY QUESTION: Among babies who WERE admitted to NCC at a recognised NNAP
# neonatal unit, do some ethnic/deprivation groups wait longer for admission?
#
# This isolates the pure timing/delay question from the access/selection
# question (already answered by the logistic models).
#
# All babies in this analysis have the event (NCC admission). The outcome is
# HOW LONG they waited, not whether they were admitted.
#
# FILTERS APPLIED:
#   - Admitted babies only (event == 1)
#   - Born at a hospital within a recognised NNAP trust (At_NNAP_Trust)
#
# COVARIATES NOW INCLUDE:
#   - Delivery_Unit_Type (NICU / LNU / SCBU): the neonatal unit level at the
#     delivery hospital. Babies born at SCBUs needing intensive care must
#     transfer, so we expect SCBU -> slower admission vs NICU.
#
# HR > 1 = faster admission (less delay), HR < 1 = slower (more delay)
# ============================================================================

cat("\n\n========================================\n")
cat("CONDITIONAL TIMING MODELS (ADMITTED BABIES AT NNAP UNITS)\n")
cat("========================================\n\n")

cat("Question: Among babies admitted to NCC at recognised NNAP units,\n")
cat("do some groups wait longer, adjusting for clinical severity,\n")
cat("unit type, and hospital of birth?\n\n")

# --- Model 6: Primary conditional timing model ---
# Gestation + Ethnicity + IMD + Unit Type + hospital frailty
cox_admitted <- surv_data %>%
  filter(
    event == 1,                        # ONLY admitted babies
    At_NNAP_Trust == TRUE,             # Born at recognised NNAP trust
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Gestation_Weeks),
    !is.na(IMD_Quintile),
    !is.na(Delivery_Site),
    !is.na(Delivery_Unit_Type),
    !is.na(Time_To_NCC_Hours),
    Time_To_NCC_Hours > 0,
    Time_To_NCC_Hours <= 672           # within 28-day window
  ) %>%
  mutate(
    event_admitted = 1L,
    Delivery_Site = droplevels(Delivery_Site)
  )

cat("Model 6 dataset (admitted babies at NNAP trusts):\n")
cat("  N:", nrow(cox_admitted), "\n")
cat("  Delivery sites:", length(unique(cox_admitted$Delivery_Site)), "\n")
cat("  Unit type breakdown:\n")
print(table(cox_admitted$Delivery_Unit_Type))
cat("\n")

# Descriptive: median time by ethnicity in this subset
cat("Median hours to NCC by ethnicity (admitted babies, NNAP):\n")
cox_admitted %>%
  group_by(Ethnicity_Baby_Grouped) %>%
  summarise(
    n = n(),
    median_h = round(median(Time_To_NCC_Hours), 2),
    q25 = round(quantile(Time_To_NCC_Hours, 0.25), 2),
    q75 = round(quantile(Time_To_NCC_Hours, 0.75), 2),
    .groups = "drop"
  ) %>%
  print(n = 20)

# Descriptive: median time by unit type
cat("\nMedian hours to NCC by delivery unit type:\n")
cox_admitted %>%
  group_by(Delivery_Unit_Type) %>%
  summarise(
    n = n(),
    median_h = round(median(Time_To_NCC_Hours), 2),
    q25 = round(quantile(Time_To_NCC_Hours, 0.25), 2),
    q75 = round(quantile(Time_To_NCC_Hours, 0.75), 2),
    pct_within_1h = round(100 * mean(Time_To_NCC_Hours <= 1), 1),
    .groups = "drop"
  ) %>%
  print()

cat("\nFitting Model 6: Cox frailty (admitted, NNAP, gestation + unit type)...\n\n")

model6_cox <- coxme(
  Surv(Time_To_NCC_Hours, event_admitted) ~
    Gestation_Weeks + Ethnicity_Baby_Grouped + IMD_Quintile +
    Delivery_Unit_Type +
    (1 | Delivery_Site),
  data = cox_admitted
)

cat("Model 6: Conditional timing — Cox frailty (NNAP, with unit type)\n")
print(model6_cox)

# Extract hazard ratios
fe6 <- fixef(model6_cox)
vcov6 <- as.matrix(vcov(model6_cox))
se6 <- sqrt(diag(vcov6))

hr_table_m6 <- data.frame(
  term = names(fe6),
  HR = exp(fe6),
  CI_lower = exp(fe6 - 1.96 * se6),
  CI_upper = exp(fe6 + 1.96 * se6),
  z = fe6 / se6,
  p.value = 2 * pnorm(-abs(fe6 / se6))
)

cat("\n\nHazard Ratios (Model 6 - Admitted Babies, NNAP Units):\n")
cat("HR > 1 = FASTER admission, HR < 1 = SLOWER (potential delay)\n")
cat("Reference: White British, IMD 5 (Least Deprived), NICU\n\n")
hr_print_m6 <- hr_table_m6 %>%
  mutate(across(c(HR, CI_lower, CI_upper, p.value), ~ round(.x, 4))) %>%
  select(term, HR, CI_lower, CI_upper, p.value)
print(hr_print_m6, right = FALSE)


# --- Model 7: Sensitivity conditional timing model ---
# Add birth weight + Apgar 5 (admitted babies only, NNAP)
cat("\n\n========================================\n")
cat("MODEL 7: Sensitivity (+ birth weight + Apgar, NNAP units)\n")
cat("========================================\n\n")

cox_admitted_full <- surv_data %>%
  filter(
    event == 1,
    At_NNAP_Trust == TRUE,
    !is.na(Ethnicity_Baby_Grouped),
    !is.na(Gestation_Weeks),
    !is.na(Birth_Weight_kg),
    !is.na(Apgar_5_Clean),
    !is.na(IMD_Quintile),
    !is.na(Delivery_Site),
    !is.na(Delivery_Unit_Type),
    !is.na(Time_To_NCC_Hours),
    Time_To_NCC_Hours > 0,
    Time_To_NCC_Hours <= 672
  ) %>%
  mutate(
    event_admitted = 1L,
    Delivery_Site = droplevels(Delivery_Site)
  )

cat("Model 7 dataset: N =", nrow(cox_admitted_full), "\n")
cat("Delivery sites:", length(unique(cox_admitted_full$Delivery_Site)), "\n\n")

cat("Fitting Model 7: Cox frailty (sensitivity, NNAP, + unit type)...\n\n")

model7_cox <- coxme(
  Surv(Time_To_NCC_Hours, event_admitted) ~
    Gestation_Weeks + Birth_Weight_kg + Apgar_5_Clean +
    Ethnicity_Baby_Grouped + IMD_Quintile +
    Delivery_Unit_Type +
    (1 | Delivery_Site),
  data = cox_admitted_full
)

cat("Model 7: Conditional timing — Cox frailty (sensitivity, NNAP)\n")
print(model7_cox)

fe7 <- fixef(model7_cox)
vcov7 <- as.matrix(vcov(model7_cox))
se7 <- sqrt(diag(vcov7))

hr_table_m7 <- data.frame(
  term = names(fe7),
  HR = exp(fe7),
  CI_lower = exp(fe7 - 1.96 * se7),
  CI_upper = exp(fe7 + 1.96 * se7),
  z = fe7 / se7,
  p.value = 2 * pnorm(-abs(fe7 / se7))
)

cat("\n\nHazard Ratios (Model 7 - Sensitivity, NNAP Units):\n")
cat("HR > 1 = FASTER admission, HR < 1 = SLOWER (potential delay)\n\n")
hr_print_m7 <- hr_table_m7 %>%
  mutate(across(c(HR, CI_lower, CI_upper, p.value), ~ round(.x, 4))) %>%
  select(term, HR, CI_lower, CI_upper, p.value)
print(hr_print_m7, right = FALSE)


# --- Compare Models 6 vs 7 (ethnicity HRs) ---
cat("\n\n========================================\n")
cat("COMPARISON: Model 6 (primary) vs Model 7 (sensitivity) — NNAP Units\n")
cat("========================================\n\n")

eth_terms_cond <- grep("Ethnicity", names(fe6), value = TRUE)

cat("Ethnicity Hazard Ratios (conditional on admission, NNAP units):\n")
cat(sprintf("%-25s %12s %12s %10s\n", "Group", "M6 (Primary)", "M7 (Sens.)", "Change"))
cat(paste(rep("-", 62), collapse = ""), "\n")

for (term in eth_terms_cond) {
  hr6 <- exp(fe6[term])
  hr7 <- exp(fe7[term])
  diff <- hr7 - hr6
  cat(sprintf("%-25s %12.3f %12.3f %+10.3f\n",
              gsub("Ethnicity_Baby_Grouped", "", term),
              hr6, hr7, diff))
}

cat("\nIMD Hazard Ratios (conditional on admission, NNAP units):\n")
imd_terms <- grep("IMD", names(fe6), value = TRUE)
cat(sprintf("%-25s %12s %12s %10s\n", "Group", "M6 (Primary)", "M7 (Sens.)", "Change"))
cat(paste(rep("-", 62), collapse = ""), "\n")

for (term in imd_terms) {
  hr6 <- exp(fe6[term])
  hr7 <- exp(fe7[term])
  diff <- hr7 - hr6
  cat(sprintf("%-25s %12.3f %12.3f %+10.3f\n",
              gsub("IMD_Quintile", "", term),
              hr6, hr7, diff))
}

cat("\nUnit Type Hazard Ratios (ref = NICU):\n")
ut_terms <- grep("Delivery_Unit_Type", names(fe6), value = TRUE)
cat(sprintf("%-25s %12s %12s %10s\n", "Type", "M6 (Primary)", "M7 (Sens.)", "Change"))
cat(paste(rep("-", 62), collapse = ""), "\n")

for (term in ut_terms) {
  hr6 <- exp(fe6[term])
  hr7 <- exp(fe7[term])
  diff <- hr7 - hr6
  cat(sprintf("%-25s %12.3f %12.3f %+10.3f\n",
              gsub("Delivery_Unit_Type", "", term),
              hr6, hr7, diff))
}


# --- PH diagnostics for conditional model ---
cat("\n\n========================================\n")
cat("PH DIAGNOSTICS (Conditional Model, NNAP)\n")
cat("========================================\n\n")

model6_coxph <- coxph(
  Surv(Time_To_NCC_Hours, event_admitted) ~
    Gestation_Weeks + Ethnicity_Baby_Grouped + IMD_Quintile +
    Delivery_Unit_Type,
  data = cox_admitted,
  ties = "efron"
)

ph_test_cond <- cox.zph(model6_coxph)
cat("Schoenfeld residual test (admitted babies, NNAP units):\n")
print(ph_test_cond)

pdf("data/ph_diagnostics_conditional.pdf", width = 14, height = 10)
par(mfrow = c(4, 4))
plot(ph_test_cond)
dev.off()
cat("\nSaved: data/ph_diagnostics_conditional.pdf\n")


# --- Forest plot: conditional timing model (with unit type) ---
forest_cond <- hr_table_m6 %>%
  filter(!grepl("Gestation_Weeks", term)) %>%
  mutate(
    term = gsub("Ethnicity_Baby_Grouped", "Ethnicity: ", term),
    term = gsub("IMD_Quintile", "IMD: ", term),
    term = gsub("Delivery_Unit_Type", "Unit: ", term),
    category = case_when(
      grepl("Ethnicity", term) ~ "Ethnicity",
      grepl("IMD", term) ~ "Deprivation",
      grepl("Unit", term) ~ "Unit Type"
    ),
    category = factor(category, levels = c("Ethnicity", "Deprivation", "Unit Type")),
    term = factor(term, levels = rev(term))
  )

p_forest_cond <- ggplot(forest_cond, aes(x = HR, y = term, colour = category)) +
  geom_vline(xintercept = 1, linetype = "dashed", colour = "grey50") +
  geom_errorbarh(aes(xmin = CI_lower, xmax = CI_upper), height = 0.2, linewidth = 0.8) +
  geom_point(size = 3) +
  scale_colour_manual(values = c(
    "Ethnicity" = "#005EB8", "Deprivation" = "#AE2573", "Unit Type" = "#009639"
  )) +
  facet_grid(category ~ ., scales = "free_y", space = "free_y") +
  labs(
    title = "Time to NCC Admission — Admitted Babies at NNAP Units (Cox Frailty Model)",
    subtitle = "HR > 1 = faster admission; HR < 1 = slower. Ref: White British / Least Deprived / NICU.",
    x = "Hazard Ratio (95% CI)",
    y = NULL
  ) +
  theme_minimal() +
  theme(
    legend.position = "none",
    plot.title = element_text(face = "bold", size = 13),
    plot.subtitle = element_text(size = 9, colour = "grey40"),
    strip.text = element_text(face = "bold"),
    panel.grid.minor = element_blank()
  )

ggsave("data/forest_plot_hr_conditional.pdf", p_forest_cond, width = 10, height = 8)
cat("Saved: data/forest_plot_hr_conditional.pdf\n")


# ============================================================================
# 9. SAVE RESULTS
# ============================================================================

cat("\n\n========================================\n")
cat("SAVING RESULTS\n")
cat("========================================\n")

saveRDS(model4_cox, "data/model4_cox_frailty.rds")
saveRDS(model5_cox, "data/model5_cox_sensitivity.rds")
saveRDS(model6_cox, "data/model6_cox_conditional.rds")
saveRDS(model7_cox, "data/model7_cox_conditional_sensitivity.rds")
saveRDS(km_fit_admitted, "data/km_fit_admitted.rds")
saveRDS(surv_data, "data/surv_data.rds")

cat("Models saved to data/ folder:\n")
cat("  - model4_cox_frailty.rds (ALL BIRTHS: Cox frailty, gestation-adjusted)\n")
cat("  - model5_cox_sensitivity.rds (ALL BIRTHS: + birth weight + Apgar)\n")
cat("  - model6_cox_conditional.rds (ADMITTED @ NNAP: + unit type, gestation-adjusted)\n")
cat("  - model7_cox_conditional_sensitivity.rds (ADMITTED @ NNAP: + unit type + BW + Apgar)\n")
cat("  - km_fit_admitted.rds (KM curves among admitted babies)\n")
cat("  - surv_data.rds (Survival analysis dataset, with NNAP linkage)\n\n")

cat("Plots saved to data/ folder:\n")
cat("  - km_curves_admitted.pdf (Cumulative incidence, admitted babies, 0-72h)\n")
cat("  - km_curves_admitted_24h.pdf (Cumulative incidence, admitted babies, 0-24h)\n")
cat("  - km_curves_preterm.pdf (Cumulative incidence, preterm <37wk)\n")
cat("  - km_broad_ethnicity.pdf (KM survival, 4 broad groups, binned time)\n")
cat("  - km_asian_disaggregation.pdf (KM survival, Asian subgroups vs White British)\n")
cat("  - forest_plot_hr.pdf (Hazard ratio forest plot, all births)\n")
cat("  - forest_plot_hr_conditional.pdf (Hazard ratio forest plot, NNAP admitted + unit type)\n")
cat("  - ph_diagnostics.pdf (Schoenfeld residual plots, all births)\n")
cat("  - ph_diagnostics_conditional.pdf (Schoenfeld residual plots, NNAP admitted)\n")

cat("\n=== SURVIVAL ANALYSIS COMPLETE ===\n")
