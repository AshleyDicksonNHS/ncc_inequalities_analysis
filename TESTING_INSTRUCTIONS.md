# Testing Instructions for NCC Base Dataset Query

## Quick Test in RStudio

### Option 1: Use the test script
Open and run `test_query.R` in RStudio. This will:
1. Connect to the database
2. Execute the query
3. Display any errors
4. Show summary statistics if successful

### Option 2: Use the original build script
Run `build_ncc_base_dataset.R` - this will execute the query and save the results to `ncc_base_dataset.rds`

### Option 3: Run manually in RStudio
```r
source("build_ncc_base_dataset.R")
```

## What to Watch For

### Potential Issues and Solutions

#### 1. Column Name Errors
**Error**: `Invalid column name 'X'`

**Solution**: The column doesn't exist in that table. Check `column_name_mappings.txt` for the correct name.

#### 2. Table Name Errors
**Error**: `Invalid object name 'UDAL_Warehouse.MESH_MSDS.MSD401_BabyDemographics_1'`

**Solution**: Table names should NOT have underscores between number and name. Should be `MSD401BabyDemographics_1`

#### 3. DATEFROMPARTS Errors
**Error**: Issues with `DATEFROMPARTS(baby.YearOfBirthBaby, baby.MonthOfBirthBaby, ...)`

**Possible causes**:
- Null or invalid values in year/month/day fields
- Days > 28/29/30/31 depending on month

**Solution**: The query uses `ISNULL(baby.MerOfBirthBaby, 1)` to default to 1st of month if day is missing.

#### 4. Data Type Conversion Errors
**Error**: Issues with `CAST(... AS TIME)` or `CAST(... AS INT)`

**Solution**: Check for invalid time formats or non-numeric values in the source data.

#### 5. Aggregation Errors in ncc_from_cc
**Error**: Column 'X' is invalid in the select list because it is not contained in either an aggregate function or the GROUP BY clause

**Solution**: The ncc_from_cc CTE groups by `APCS_Ident` and `Hospital_Spell_No`. Any new columns must use an aggregate function (MIN, MAX, SUM, COUNT, etc.)

## Expected Results

If the query runs successfully, you should see:

```
Base dataset created successfully!
Records: [number of births]
Fields: [number of columns]

=== SUMMARY STATISTICS ===

NCC Admission Rate:
  0    1
[count] [count]
Percentage admitted to NCC: X.XX %

NCC Admissions by Financial Year:
     Year NCC
[cross-tabulation of years and NCC admissions]

Births by Financial Year:
[counts by year]

Data quality - NCC admissions with both MSDS and CC data:
[counts showing how many in both sources]
```

## Current Limitations

The query currently has:
- `TOP 1000` limit on ncc_from_cc CTE (line 24)
- `TOP 100` limit on apcs_link CTE (line 95)
- `TOP 1000` limit on msds_babies CTE (line 128)
- Financial year filter commented out (line 84)

### To Run Full Query
Remove the TOP limits and uncomment the financial year filter:

**Line 24**: Change `SELECT top 1000` to `SELECT`
**Line 84**: Uncomment `AND cc.Der_Financial_Year >= '2019/20'`
**Line 95**: Change `SELECT top 100` to `SELECT`
**Line 128**: Change `SELECT top 1000` to `SELECT`

## Testing Strategy

### Phase 1: Test with Limits (Current State)
Run the query as-is with TOP limits. This should run quickly and help identify any column name or syntax errors.

### Phase 2: Test One CTE at a Time
If you get errors, test each CTE individually:

```sql
-- Test ncc_from_cc
SELECT TOP 10 *
FROM UDAL_Warehouse.MESH_APC.Pbr_CC_Monthly cc
WHERE cc.CC_Type = 'NCC'

-- Test msds_babies
SELECT TOP 10 *
FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1 baby
WHERE baby.YearOfBirthBaby >= 2019

-- Test msds_labour
SELECT TOP 10 *
FROM UDAL_Warehouse.MESH_MSDS.MSD301LabourDelivery_1 ld
WHERE ld.StartDateMotherDeliveryHospProvSpell >= '2019-04-01'

-- etc...
```

### Phase 3: Remove Limits and Run Full Query
Once all errors are resolved, remove the TOP limits and run the full query.

## Performance Notes

The full query (without TOP limits) may take **several minutes to hours** depending on:
- Amount of data (2019/20 onwards = 5+ years of births)
- Server load
- Network speed
- Complexity of joins

Consider:
- Running during off-peak hours
- Starting with a smaller date range (e.g., just 2023/24)
- Monitoring query progress in Azure Synapse portal

## After Successful Execution

The `build_ncc_base_dataset.R` script will save the results to `ncc_base_dataset.rds`. You can load this later with:

```r
ncc_data <- readRDS("ncc_base_dataset.rds")
```

## Next Steps After Testing

Once the query runs successfully, consider:

1. **Add birth weight and Apgar scores**: Join to `MSD405CareActivityBaby_1` table
2. **Add maternal geographic data**: Use `LSOAMother2011` from mother demographics for IMD linkage
3. **Add maternal age**: Check if `AgeAtBirthMother` exists in baby demographics table
4. **Validate the data**: Check for reasonable values, missing data patterns, outliers
5. **Begin exploratory analysis**: Use `NCC_exploratory_notebook.Rmd`
