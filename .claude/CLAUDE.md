# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an R-based healthcare data analysis project examining Neonatal Critical Care (NCC) access and inequalities. The analysis uses NHS administrative data from multiple sources: MSDS (Maternity Services Dataset), Critical Care (PbR_CC_Monthly), and APCS (Admitted Patient Care Spells) to study inequalities in NCC access.

**Key goal**: Build a hierarchical model to analyze patient characteristics (fixed effects), hospital/provider effects (random effects), and inequality measures (ethnicity, deprivation, geography) in NCC admission patterns.

## Statistical Modeling Approach

The analysis will use a **Mixed Effects Survival Model** (also known as a **Frailty Model**) to handle two key aspects of NCC access:

1. **Binary outcome**: Whether a baby is admitted to NCC at all (`NCC_Admitted`)
2. **Time-to-event outcome**: Time from birth to NCC admission, accounting for delayed access

This approach is necessary because access inequalities may manifest in two ways:
- **Absolute access**: Some groups may be less likely to receive NCC care when needed
- **Delayed access**: Some groups may experience longer delays before receiving NCC care

The survival modeling framework handles:
- **Right censoring**: Babies who are never admitted to NCC (event does not occur)
- **Time-varying covariates**: If clinical status changes over time
- **Competing risks**: Death or discharge before NCC admission
- **Frailty (random effects)**: Hospital-level and provider-level variation in access patterns

**Key outcome variable**: Time from `Baby_Birth_Date`/`Baby_Birth_Time` to NCC admission, measured by `Hours_Birth_To_NCC_MSDS` or `Hours_Birth_To_NCC_CC`.

## Data Architecture

### Core Data Sources
- **MSDS (MESH_MSDS schema)**: Birth and maternity data - one record per baby
  - `MSD401_BabyDemographics_1`: Base table with birth details, Apgar scores, outcomes
  - `MSD301_LabourDelivery_1`: Labour and delivery details
  - `MSD001_MotherDemog_1`: Mother demographics
  - `MSD101_PregnancyBooking_1`: Pregnancy and booking details, social factors
  - `MSD402_NeonatalAdmission_1`: MSDS-reported neonatal admissions

- **Critical Care (MESH_APC.PbR_CC_Monthly)**: Daily-level NCC records
  - **Important**: Records are at DAILY level (one record per day of stay)
  - Filtered by `CC_Type = 'NCC'` for neonatal critical care
  - Contains organ support details, severity measures, care levels

- **APCS (MESH_APC.APCS_Core_Daily)**: Spell-level admission data
  - **Critical linkage**: Provides NHS_Number to link CC data to MSDS births
  - Contains demographic and geographic information

### Data Linkage Strategy
1. Start with MSDS births (MSD401_BabyDemographics_1) as base
2. Join MSDS tables via `Labour_Delivery_ID`, `UniqPregID`, `Person_ID_Mother`
3. Link to CC data via NHS_Number (through APCS): `baby.NHS_Number_Baby = cc_ncc.NCC_CC_NHS_Number`
4. Apply date proximity filter (within 90 days) when linking birth to CC admission
5. NCC admission status from TWO sources for data quality checks:
   - `NCC_MSDS_Admitted`: From MSD402
   - `NCC_CC_Admitted`: From PbR_CC_Monthly
   - `NCC_Admitted`: Combined flag (1 if in EITHER source)
   - `NCC_In_Both_Sources`: Data quality indicator

## Database Connection

All scripts connect to Azure Synapse Analytics:
- **Server**: `udalsyndataprod.sql.azuresynapse.net`
- **Database**: `UDAL_Warehouse`
- **Authentication**: ActiveDirectoryInteractive (will prompt for login)
- **Driver**: ODBC Driver 17 for SQL Server

Connection pattern used across all R scripts:
```r
con <- DBI::dbConnect(odbc(),
                      Driver = "ODBC Driver 17 for SQL Server",
                      Server = "udalsyndataprod.sql.azuresynapse.net",
                      Database = "UDAL_Warehouse",
                      UID = "ashley.dickson@udal.nhs.uk",
                      Authentication = "ActiveDirectoryInteractive",
                      Port = 1433)
```

## Running the Analysis

### Build the base dataset
```bash
Rscript build_ncc_base_dataset.R
```
This script:
1. Reads `NCC_base_dataset_query.sql`
2. Executes the SQL query against the data warehouse
3. Saves results to `ncc_base_dataset.rds`
4. Prints summary statistics (NCC admission rates, financial year breakdowns)

**Expected output**: RDS file with one record per birth (2019/20 onwards) containing birth details, maternal demographics, and NCC admission status/details.

### Test queries during development
```bash
Rscript test_query.R
```
Use this script to test SQL query modifications without saving results. It provides detailed error messages and displays the first few rows if successful.

### Explore interactively
Open `NCC_exploratory_notebook.Rmd` in RStudio for interactive exploration.

## File Structure

- **`build_ncc_base_dataset.R`**: Main script to build base dataset from SQL query
- **`test_query.R`**: Testing script for query development and debugging
- **`NCC_base_dataset_query.sql`**: Complex SQL query that joins MSDS, CC, and APCS data
- **`NCC_exploratory_notebook.Rmd`**: R Markdown notebook for interactive data exploration
- **`MSDS_and_CC_columns.csv`**: Schema documentation reference
- **`column_name_mappings.txt`**: Mapping of intended column names to actual database schema
- **`SQL_UPDATE_SUMMARY.md`**: Documentation of schema corrections and known missing fields
- **`TESTING_INSTRUCTIONS.md`**: Detailed testing workflow and troubleshooting guide

## Key Variables for Analysis

### Fixed Effects (Patient Characteristics)
- **Severity indicators**: `Birth_Weight`, `Gestation_Length_At_Birth`, `Apgar_Score_At_1_Minute`, `Apgar_Score_At_5_Minutes`
- **Organ support days** (from CC data): `NCC_CC_Adv_Resp_Days`, `NCC_CC_Basic_Resp_Days`, `NCC_CC_Adv_CV_Days`, etc.
- **Care levels**: `NCC_CC_Level2_Days`, `NCC_CC_Level3_Days`

### Inequality Measures
- **Ethnicity**: `Ethnic_Category_Baby`, `Ethnic_Category_Mother`
- **Deprivation**: Mother's postcode (`Mother_Postcode`) - requires IMD lookup
- **Social factors**: `Complex_Social_Factors_Indicator_At_Antenatal_Booking`, `Employment_Status_Mother_At_Antenatal_Booking`, `Disability_Indicator_At_Antenatal_Booking`
- **Geography**: `Mother_CCG_Residence`, mother's LSOA/MSOA (derive from postcode)

### Random Effects (Hospital/Provider)
- `NCC_Hospital_Provider_Code`: Where NCC care was provided
- `Delivery_Site_Code`: Where baby was born
- `Org_ID_Commissioner`: Commissioning organization

### Timing Variables
- `Hours_Birth_To_NCC_MSDS`: Time from birth to NCC admission (MSDS source)
- `Hours_Birth_To_NCC_CC`: Time from birth to NCC admission (CC source)

## Critical Care Data Aggregation

**Important**: PbR_CC_Monthly records are at the DAILY level. The SQL query aggregates these to birth-level:
- `COUNT(*)` → `NCC_CC_Total_Days`
- `COUNT(DISTINCT cc.CC_Period_Number)` → `NCC_CC_Number_Of_Periods`
- `SUM(organ_support_days)` → Total organ support across all days
- `MIN(dates/times)` → First admission details
- `MAX(dates/times)` → Last discharge details

## Time Period
All data filters apply `>= '2019-04-01'` (financial year 2019/20 onwards).

## SQL Query Development

### Schema Conventions
- **Table names**: No underscores between numbers and names (e.g., `MSD401BabyDemographics_1` not `MSD401_BabyDemographics_1`)
- **NHS Numbers**: Use `pseudo_nhs_number_ncdr_baby` (pseudonymized version) not `NHS_Number_Baby`
- **Birth dates**: Construct from separate fields using `DATEFROMPARTS(YearOfBirthBaby, MonthOfBirthBaby, ISNULL(MerOfBirthBaby, 1))`

### Known Missing Fields
These fields are NOT available in their expected tables and are commented out in the query:
- **Birth_Weight** and **Apgar_Score_At_X_Minutes**: Not in MSD401BabyDemographics_1 (available in MSD405CareActivityBaby_1)
- **Person_Birth_Date_Mother**: Not in MSD001MotherDemog_1 (prevents calculation of Mother_Age_At_Delivery)
- **Postcode_Usual_Address_Mother**: Not in MSD001MotherDemog_1 (use LSOAMother2011 or PostcodeDistrictMother instead)

To add birth weight and Apgar scores, join to `MSD405CareActivityBaby_1` on `Person_ID_Baby`.

### Common SQL Errors
- **Invalid column name**: Check `column_name_mappings.txt` for correct field names
- **Invalid object name**: Verify table naming convention (no underscores between numbers)
- **DATEFROMPARTS errors**: Check for null/invalid day values (query defaults to 1st of month if day missing)
- **Aggregation errors in ncc_from_cc CTE**: All non-aggregated columns must be in GROUP BY clause

### Testing Strategy
1. Test with TOP limits first (fast, catches syntax errors)
2. Remove TOP limits for full dataset (may take several minutes)
3. Use `test_query.R` to iterate on query development
4. See `TESTING_INSTRUCTIONS.md` for detailed troubleshooting

## R Package Dependencies
```r
packages <- c('tidyverse', 'DBI', 'odbc', 'rstudioapi', 'readxl')
```

## Data Quality Considerations

- **Dual source validation**: NCC admission status comes from both MSDS (MSD402) and Critical Care (PbR_CC_Monthly)
- **Completeness flags**: `NCC_In_Both_Sources` indicates babies with NCC records in both datasets
- **Date proximity**: CC data is only linked to births if within 90 days of birth date
- **Daily aggregation**: PbR_CC_Monthly records are daily; the query aggregates to birth-level using SUM/MIN/MAX
