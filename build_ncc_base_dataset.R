# ============================================================================
# NCC Base Dataset Construction
# ============================================================================
# Project: Neonatal Critical Care Access & Inequalities
# Purpose: Build base dataset for hierarchical model of NCC access
#
# Analysis goals:
# - Patient characteristics (fixed effects)
# - Severity indicators (case-mix adjustment)
# - Hospital/provider identifiers (random effects)
# - Inequality measures (ethnicity, deprivation, geography)
#
# Structure: MSDS births as base, with NCC data aggregated from daily to
#            birth-level, linked via APCS NHS Number
# ============================================================================

library(tidyverse)
library(DBI)
library(odbc)

setwd("~/NCC_Analysis")

# Database connection
driver <- "ODBC Driver 18 for SQL Server"
server <- "udalsyndataprod.sql.azuresynapse.net"
database <- "UDAL_Warehouse"
uid <- Sys.getenv("UDAL_USER", unset = "ashley.dickson@udal.nhs.uk")

con <- DBI::dbConnect(odbc(),
                      Driver = driver,
                      Server = server,
                      Database = database,
                      UID = uid,
                      Authentication = "ActiveDirectoryInteractive",
                      Port = 1433)

# ============================================================================
# Execute base dataset query
# ============================================================================

query_file <- "NCC_base_dataset_query.sql"

if (file.exists(query_file)) {
  query <- readLines(query_file) %>%
    paste(collapse = "\n")

  cat("Executing base dataset query...\n")
  cat("This may take several minutes...\n\n")

  ncc_base_data <- dbGetQuery(con, query)

  cat("Base dataset created successfully!\n")
  cat("Records:", nrow(ncc_base_data), "\n")
  cat("Fields:", ncol(ncc_base_data), "\n\n")

  # Summary statistics
  cat("=== SUMMARY STATISTICS ===\n\n")

  cat("NCC Admission Rate:\n")
  print(table(ncc_base_data$NCC_Admitted, useNA = "ifany"))
  cat("Percentage admitted to NCC:",
      round(100 * mean(ncc_base_data$NCC_Admitted, na.rm = TRUE), 2), "%\n\n")

  cat("NCC Admissions by Financial Year:\n")
  print(table(Year = ncc_base_data$Baby_Birth_Financial_Year,
              NCC = ncc_base_data$NCC_Admitted))

  cat("\n")
  cat("Births by Financial Year:\n")
  print(table(ncc_base_data$Baby_Birth_Financial_Year))

  cat("\n")
  cat("Data quality - NCC admissions with both MSDS and CC data:\n")
  if ("NCC_In_Both_Sources" %in% names(ncc_base_data)) {
    print(table(ncc_base_data$NCC_In_Both_Sources, useNA = "ifany"))
  }

  # ------------------------------------------------------------------------
  # Phase 2 timing fields (time from birth to first critical-care episode)
  # ------------------------------------------------------------------------
  # MSDS supplies minute resolution; PbR_CC supplies day resolution.
  # Hours_Birth_To_First_CC is the unified "best available" field.
  # ------------------------------------------------------------------------
  if ("Hours_Birth_To_First_CC" %in% names(ncc_base_data)) {
    cat("\n=== PHASE 2 TIMING (first critical-care episode) ===\n\n")

    cat("Source of unified timing (Hours_Birth_To_First_CC_Source):\n")
    print(table(ncc_base_data$Hours_Birth_To_First_CC_Source, useNA = "ifany"))

    admitted <- ncc_base_data[ncc_base_data$NCC_Admitted == 1, ]

    cat("\nUnified Hours_Birth_To_First_CC (admitted babies only):\n")
    print(summary(admitted$Hours_Birth_To_First_CC))

    cat("\nMSDS-only Hours_Birth_To_First_CC_MSDS (minute resolution, admitted babies):\n")
    print(summary(admitted$Hours_Birth_To_First_CC_MSDS))

    cat("\nPbR-only Hours_Birth_To_First_CC_PbR (day resolution, admitted babies):\n")
    print(summary(admitted$Hours_Birth_To_First_CC_PbR))

    cat("\nDistribution of MSDS-derived hours (admitted babies):\n")
    msds_hours <- admitted$Hours_Birth_To_First_CC_MSDS
    msds_hours <- msds_hours[!is.na(msds_hours)]
    if (length(msds_hours) > 0) {
      buckets <- cut(msds_hours,
                     breaks = c(-Inf, 1, 6, 24, 24 * 7, 24 * 28, Inf),
                     labels = c("<=1h", "1-6h", "6-24h", "1-7d", "7-28d", ">28d"),
                     right = TRUE)
      print(table(buckets, useNA = "ifany"))
    }
  }

  # Save the dataset
  output_file <- "data/ncc_base_dataset.rds"
  saveRDS(ncc_base_data, output_file)
  cat("\nDataset saved to:", output_file, "\n")

} else {
  cat("Error: Query file not found:", query_file, "\n")
  cat("Please ensure NCC_base_dataset_query.sql is in the working directory.\n")
}

dbDisconnect(con)

cat("\n=== COMPLETE ===\n")
