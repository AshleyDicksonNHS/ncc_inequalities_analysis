# Neonatal Critical Care Inequalities Analysis

Analysis of inequalities in access to Neonatal Critical Care (NCC) in England, using linked NHS administrative data.

## Overview

This project examines whether there are inequalities in NCC access based on:
- Ethnicity (baby and mother)
- Socioeconomic deprivation
- Geographic location
- Social factors recorded at antenatal booking

The analysis links data from the Maternity Services Dataset (MSDS) with Critical Care records to create a comprehensive birth-level dataset for hierarchical modelling.

## Report

View the full methodology and descriptive statistics report:
**[NCC Base Dataset Report](https://ashleydicksonnhs.github.io/ncc_inequalities_analysis/)**

## Data Sources

- **MSDS (Maternity Services Dataset)**: Birth details, maternal demographics, social factors
- **Critical Care (PbR_CC_Monthly)**: NCC admission details, length of stay, care levels
- **APCS (Admitted Patient Care Spells)**: Linkage between datasets via NHS Number

## Setup

### Prerequisites

- R (version 4.0+)
- Access to NHS UDAL (Unified Data Access Layer)
- ODBC Driver 17 for SQL Server

### Configuration

Set your UDAL email as an environment variable before running scripts:

```r
Sys.setenv(UDAL_USER = "your.name@udal.nhs.uk")
```

Or add to your `.Renviron` file for persistence:
```
UDAL_USER=your.name@udal.nhs.uk
```

### Running the Analysis

1. **Build the base dataset**:
   ```bash
   Rscript build_ncc_base_dataset.R
   ```
   This executes the SQL query and saves results to `data/ncc_base_dataset.rds`

2. **Render the report**:
   ```bash
   quarto render index.qmd
   ```

## File Structure

```
├── index.qmd                    # Main Quarto report
├── build_ncc_base_dataset.R     # Script to build dataset from SQL
├── NCC_base_dataset_query.sql   # SQL query joining all data sources
├── analyze_ncc_sources.R        # Analysis of MSDS vs CC data quality
├── data/                        # Data files (gitignored)
└── docs/                        # Rendered HTML report for GitHub Pages
```

## Key Findings

- **512,032 births** in financial year 2023/24
- **12.52% NCC admission rate** (64,109 babies)
- Critical Care data captures 3.76x more NCC admissions than MSDS
- Significant data deduplication required (MSDS tables had 2-10x duplication)

## Author

Ashley Dickson, NHS England
