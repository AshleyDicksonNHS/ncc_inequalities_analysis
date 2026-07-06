# SQL Query Update Summary

## Overview
Updated `NCC_base_dataset_query.sql` with correct table and column names from the actual database schema as documented in `MSDS_and_CC_columns.csv`.

## Changes Made

### 1. Table Names Fixed (removed underscores)
- `MSD401_BabyDemographics_1` → `MSD401BabyDemographics_1`
- `MSD301_LabourDelivery_1` → `MSD301LabourDelivery_1`
- `MSD001_MotherDemog_1` → `MSD001MotherDemog_1`
- `MSD101_PregnancyBooking_1` → `MSD101PregnancyBooking_1`
- `MSD402_NeonatalAdmission_1` → `MSD402NeonatalAdmission_1`

### 2. Column Names Updated
All column names updated to match actual database schema. See `column_name_mappings.txt` for complete mapping.

### 3. Special Handling

#### Birth Date Construction
`Person_Birth_Date_Baby` doesn't exist as a single column. Now constructed from:
```sql
DATEFROMPARTS(baby.YearOfBirthBaby, baby.MonthOfBirthBaby, ISNULL(baby.MerOfBirthBaby, 1))
```

#### NHS Number
Changed from `NHS_Number_Baby` to `pseudo_nhs_number_ncdr_baby` (the pseudonymized version available in the database)

#### Missing Columns - Commented Out
The following columns don't exist in their expected tables and have been commented out:
- **Birth_Weight** - not in MSD401BabyDemographics_1 (available in MSD405CareActivityBaby_1)
- **Apgar scores** (1, 2, 5, 10 minutes) - not in MSD401BabyDemographics_1 (available in MSD405CareActivityBaby_1)
- **Person_Birth_Date_Mother** - not in MSD001MotherDemog_1
- **Mother_Age_At_Delivery** - cannot calculate without mother's birth date
- **Postcode_Usual_Address_Mother** - not in MSD001MotherDemog_1 (but LSOAMother2011, PostcodeDistrictMother are available)
- **Maternity_Care_Setting_Actual_Place_Birth** - referenced in labour table but actually in baby demographics table

### 4. Organ Support Columns Added
Added the missing severity/organ support columns to the `ncc_from_cc` CTE:
- `NCC_CC_Adv_Resp_Days`
- `NCC_CC_Basic_Resp_Days`
- `NCC_CC_Adv_CV_Days`
- `NCC_CC_Basic_CV_Days`
- `NCC_CC_Renal_Days`
- `NCC_CC_Neuro_Days`
- `NCC_CC_Gastro_Days`
- `NCC_CC_Derm_Days`
- `NCC_CC_Liver_Days`
- `NCC_CC_Max_Organs_Supported`
- `NCC_CC_Level2_Days`
- `NCC_CC_Level3_Days`

## Next Steps

### To Get Birth Weight and Apgar Scores
You'll need to add a LEFT JOIN to `MSD405CareActivityBaby_1`:
```sql
LEFT JOIN UDAL_Warehouse.MESH_MSDS.MSD405CareActivityBaby_1 care
  ON baby.Person_ID_Baby = care.Person_ID_Baby
```

Then you can select:
- `care.BirthWeight`
- `care.ApgarScore` (this appears to be a combined field, not separate 1/5/10 minute scores)

### Mother's Age
To get mother's age at delivery, you may need to:
1. Use `AgeAtBirthMother` directly from baby demographics table (if it exists)
2. Or derive from other available age fields in the mother demographics table
3. Or calculate based on difference between mother's age at death and baby's age (if mother deceased)

### Mother's Postcode
Instead of full postcode, use:
- `LSOAMother2011` - for deprivation analysis (can link to IMD)
- `PostcodeDistrictMother` - for geographic analysis
- `CCGResidenceMother` - for commissioning analysis

## Testing
The query should now run without column name errors. However, you may want to:
1. Remove or adjust the `TOP 1000` limits added for testing
2. Uncomment the financial year filter: `AND cc.Der_Financial_Year >= '2019/20'`
3. Decide which missing columns are critical and add necessary joins
