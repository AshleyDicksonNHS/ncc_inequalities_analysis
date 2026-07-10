/*
============================================================================
NCC BASE DATASET CONSTRUCTION QUERY
============================================================================
Project: Neonatal Critical Care Access & Inequalities
Purpose: Create base dataset for hierarchical model

STRUCTURE:
- Base: MSDS births (one record per baby, MSD401_BabyDemographics_1)
  * DEDUPLICATED: All MSDS tables have 2-10x duplication due to multiple
    submissions. Each table uses ROW_NUMBER() to keep most recent submission.
  * DATA QUALITY: Excludes babies with multiple mothers (0.15%)
  * MULTI-ORG HANDLING: When baby has records from multiple providers,
    prioritises record where submitting org matches delivery site (CQIM methodology)
- Linked: Mother demographics, pregnancy, and delivery details (all deduplicated)
- Joined: NCC critical care data (aggregated from daily to birth-level)
- Compared: NCC data from both MSDS (MSD402) and PbR_CC_Monthly sources
- Linkage: via APCS NHS_Number

OUTPUT: One record per birth with NCC admission status and details
EXPECTED: ~507k births per financial year after DQ exclusions (from ~541k raw)

CHANGES FROM PREVIOUS VERSION (based on CQIM/Databricks methodology review):
- Added exclusion of babies with multiple mothers (DQ issue)
- Added multi-organisation handling (prioritise matching provider)
- Added optional unknown Person_ID filter
- Enhanced partition key to include Person_ID_Mother, UniqPregID
============================================================================
*/

-- ============================================================================
-- CONFIGURATION: Set to 1 to exclude unknown Person IDs, 0 to keep them
-- Unknown IDs start with 'U' and represent ~2.8% of records
-- ============================================================================
-- DECLARE @ExcludeUnknownIDs INT = 1;  -- Uncomment for SSMS/ADS

-- ========================================================================
-- STEP 1: Aggregate NCC data from PbR_CC_Monthly (daily to birth-level)
-- ========================================================================
WITH ncc_from_cc AS (
  SELECT
    -- Join keys
    cc.APCS_Ident,

    -- Binary admission flag
    1 AS NCC_CC_Admitted,

    -- Timing
    MIN(cc.CC_Start_Date) AS NCC_CC_First_Admission_Date,
    MIN(cc.CC_Start_Time) AS NCC_CC_First_Admission_Time,
    MAX(cc.CC_Discharge_Date) AS NCC_CC_Last_Discharge_Date,
    MAX(cc.CC_Discharge_Time) AS NCC_CC_Last_Discharge_Time,
    MIN(cc.CC_Activity_Date) AS NCC_CC_First_Activity_Date,

    -- Length of stay
    COUNT(*) AS NCC_CC_Total_Days,  -- Daily records
    COUNT(DISTINCT cc.CC_Period_Number) AS NCC_CC_Number_Of_Periods,

    -- Birth/clinical details from CC data
    MAX(cc.CC_Delivery_Gestation_Length) AS NCC_CC_Gestation_Weeks,
    MAX(CAST(cc.Person_Weight AS FLOAT)) AS NCC_CC_Birth_Weight_Grams,

    -- Severity indicators - SUM organ support days across all daily records
    --SUM(CAST(ISNULL(cc.Advanced_Resp_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Adv_Resp_Days,
    --SUM(CAST(ISNULL(cc.Basic_Resp_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Basic_Resp_Days,
    --SUM(CAST(ISNULL(cc.Advanced_Cardiovasc_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Adv_CV_Days,
    --SUM(CAST(ISNULL(cc.Basic_Cardiovasc_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Basic_CV_Days,
    --SUM(CAST(ISNULL(cc.Renal_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Renal_Days,
    --SUM(CAST(ISNULL(cc.Neurological_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Neuro_Days,
    --SUM(CAST(ISNULL(cc.Gastro_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Gastro_Days,
    --SUM(CAST(ISNULL(cc.Dermatological_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Derm_Days,
    --SUM(CAST(ISNULL(cc.Liver_Supp_days, 0) AS BIGINT)) AS NCC_CC_Liver_Days,
    --MAX(ISNULL(cc.Organ_Supp_Max, 0)) AS NCC_CC_Max_Organs_Supported,

    -- Care levels
    SUM(CAST(ISNULL(cc.CC_Level2_days, 0) AS BIGINT)) AS NCC_CC_Level2_Days,
    SUM(CAST(ISNULL(cc.CC_Level3_Days, 0) AS BIGINT)) AS NCC_CC_Level3_Days,

    -- Unit characteristics (from first admission)
    MIN(cc.CC_Unit_Function) AS NCC_CC_First_Unit_Function,
    MIN(cc.CC_Unit_Bed_Config) AS NCC_CC_First_Unit_Bed_Config,
    MIN(cc.CC_Admission_Source) AS NCC_CC_Admission_Source,
    MIN(cc.CC_Source_Location) AS NCC_CC_Source_Location,
    MIN(cc.CC_Admission_Type) AS NCC_CC_Admission_Type,

    -- Discharge (from last discharge)
    MAX(cc.CC_Discharge_Status) AS NCC_CC_Final_Discharge_Status,
    MAX(cc.CC_Discharge_Destination) AS NCC_CC_Final_Discharge_Destination,
    MAX(cc.CC_Discharge_Location) AS NCC_CC_Final_Discharge_Location,

    -- Provider (for hospital random effects)
    MIN(cc.Der_Provider_Code) AS NCC_CC_Provider_Code,
    MIN(cc.Provider_Code) AS NCC_CC_Provider_Code_Raw,

    -- Time period
    MIN(cc.Der_Financial_Year) AS NCC_CC_Financial_Year

  FROM UDAL_Warehouse.MESH_APC.Pbr_CC_Monthly cc
  WHERE cc.CC_Type = 'NCC'
    -- Include FY 2023/24 plus the first ~30 days of FY 2024/25 so we don't
    -- under-count NCC admissions for babies born late in March 2024.
    AND (
      cc.Der_Financial_Year = '2023/24'
      OR (cc.Der_Financial_Year = '2024/25' AND cc.CC_Activity_Date < '2024-05-01')
    )

  GROUP BY
    cc.APCS_Ident
),

-- ========================================================================
-- STEP 2: Get APCS spell data for linking (has NHS_Number)
-- ========================================================================
apcs_link AS (
  SELECT
    apcs.APCS_Ident,
    apcs.Hospital_Spell_No,
    apcs.Der_Pseudo_NHS_Number,
    apcs.Admission_Date,
    apcs.Discharge_Date,
    apcs.Ethnic_Group,
    apcs.Sex,
    apcs.Age_At_Start_of_Spell_SUS,
    apcs.Der_Postcode_LSOA_2011_Code,
    apcs.Der_Postcode_MSOA_2011_Code,
    apcs.Discharge_Method

  FROM UDAL_Warehouse.MESH_APC.APCS_Core_Daily apcs
  -- Mirror the widened CC window above so APCS rows that link the late-March
  -- 2024 NCC admissions to NHS numbers are still available.
  WHERE apcs.Der_Financial_Year = '2023/24'
     OR (apcs.Der_Financial_Year = '2024/25' AND apcs.Admission_Date < '2024-05-01')
),

-- ========================================================================
-- STEP 3: Link NCC CC data to NHS Numbers via APCS
-- ========================================================================
ncc_cc_with_nhs AS (
  SELECT
    ncc.*,
    apcs.Der_Pseudo_NHS_Number AS NCC_CC_NHS_Number
  FROM ncc_from_cc ncc
  LEFT JOIN apcs_link apcs
    ON ncc.APCS_Ident = apcs.APCS_Ident
),

-- ========================================================================
-- STEP 3b: Collapse multiple APCS spells per NHS number to ONE row per baby
-- ========================================================================
-- Without this step, a baby who is transferred between providers (multiple
-- APCS_Idents in the FY) appears multiple times in the final output, which
-- inflates the NCC rate and biases hospital-level variance estimates.
-- We aggregate spells by NHS number: SUM stay-day fields, MIN/MAX dates,
-- and pick the FIRST spell's provider/unit characteristics.
-- ========================================================================
ncc_cc_per_baby AS (
  SELECT
    NCC_CC_NHS_Number,
    1 AS NCC_CC_Admitted,

    -- Counts across all spells the baby had in the FY
    COUNT(*) AS NCC_CC_Number_Of_Spells,
    SUM(NCC_CC_Total_Days) AS NCC_CC_Total_Days,
    SUM(NCC_CC_Number_Of_Periods) AS NCC_CC_Number_Of_Periods,
    SUM(NCC_CC_Level2_Days) AS NCC_CC_Level2_Days,
    SUM(NCC_CC_Level3_Days) AS NCC_CC_Level3_Days,

    -- Earliest activity / admission across spells
    MIN(NCC_CC_First_Activity_Date) AS NCC_CC_First_Activity_Date,
    MIN(NCC_CC_First_Admission_Date) AS NCC_CC_First_Admission_Date,
    MIN(NCC_CC_First_Admission_Time) AS NCC_CC_First_Admission_Time,

    -- Latest discharge across spells
    MAX(NCC_CC_Last_Discharge_Date) AS NCC_CC_Last_Discharge_Date,
    MAX(NCC_CC_Last_Discharge_Time) AS NCC_CC_Last_Discharge_Time,

    -- Birth-recorded clinical (use MAX as a deterministic pick; values agree
    -- across spells in the vast majority of cases)
    MAX(NCC_CC_Gestation_Weeks) AS NCC_CC_Gestation_Weeks,
    MAX(NCC_CC_Birth_Weight_Grams) AS NCC_CC_Birth_Weight_Grams,

    -- Provider / unit characteristics: take values from the EARLIEST spell
    -- (the one closest to birth), so hospital-level analysis attributes the
    -- baby to where their NCC journey started.
    MIN(CASE WHEN spell_rank = 1 THEN NCC_CC_Provider_Code END)        AS NCC_CC_Provider_Code,
    MIN(CASE WHEN spell_rank = 1 THEN NCC_CC_First_Unit_Function END)  AS NCC_CC_First_Unit_Function,
    MIN(CASE WHEN spell_rank = 1 THEN NCC_CC_Admission_Source END)     AS NCC_CC_Admission_Source,

    -- Final discharge status from the LAST spell
    MIN(CASE WHEN spell_rank_desc = 1 THEN NCC_CC_Final_Discharge_Status END)
      AS NCC_CC_Final_Discharge_Status,
    MIN(CASE WHEN spell_rank_desc = 1 THEN NCC_CC_Final_Discharge_Destination END)
      AS NCC_CC_Final_Discharge_Destination
  FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY NCC_CC_NHS_Number
        ORDER BY NCC_CC_First_Activity_Date ASC, APCS_Ident ASC
      ) AS spell_rank,
      ROW_NUMBER() OVER (
        PARTITION BY NCC_CC_NHS_Number
        ORDER BY NCC_CC_Last_Discharge_Date DESC, APCS_Ident DESC
      ) AS spell_rank_desc
    FROM ncc_cc_with_nhs
    WHERE NCC_CC_NHS_Number IS NOT NULL  -- can't link a spell with no NHS number
  ) ranked
  GROUP BY NCC_CC_NHS_Number
),

-- ========================================================================
-- STEP 3c: APCS spell outcome per baby (second, independent death source)
-- ========================================================================
-- Aggregates ALL APCS spells in the window (not just CC-linked ones) to
-- ONE row per pseudo NHS number BEFORE joining, so the LEFT JOIN in the
-- base dataset cannot change the row count or disturb existing columns.
-- Discharge_Method national codes: 1-3 = discharged, 4 = died,
-- 5 = stillbirth (verified unique APCS_Ident in window: 20,989,799 rows =
-- 20,989,799 distinct idents; scratch_probe_apcs_discharge_method.R).
-- NULL join result downstream means "baby never linked to any APCS spell",
-- which is distinct from "linked and did not die" (flag = 0).
-- ========================================================================
apcs_outcome_per_baby AS (
  SELECT
    Der_Pseudo_NHS_Number,
    COUNT(*) AS APCS_Spell_Count,
    MAX(CASE WHEN Discharge_Method = '4' THEN 1 ELSE 0 END) AS APCS_Died_In_Hospital,
    MAX(CASE WHEN Discharge_Method = '5' THEN 1 ELSE 0 END) AS APCS_Stillbirth_Coded,
    -- Discharge date of the death spell (for concordance vs MSDS death date)
    MAX(CASE WHEN Discharge_Method = '4' THEN Discharge_Date END) AS APCS_Death_Spell_Discharge_Date
  FROM apcs_link
  WHERE Der_Pseudo_NHS_Number IS NOT NULL
  GROUP BY Der_Pseudo_NHS_Number
),

-- ========================================================================
-- STEP 4: Get MSDS Baby Demographics and Birth Details (BASE TABLE)
-- ========================================================================
-- DEDUPLICATION STRATEGY (aligned with CQIM methodology):
--   1. Filter by financial year
--   2. Identify and exclude babies with multiple mothers (DQ issue - 0.15%)
--   3. Handle multi-organisation submissions (3.6% of babies):
--      - Prioritise records where OrgCodeProvider matches delivery site
--      - Use ROW_NUMBER with org-match flag in ordering
--   4. Keep most recent submission per Person_ID_Baby
--   5. Optional: Filter out unknown Person IDs (starting with 'U')
-- ========================================================================

-- Step 4a: Raw baby records with financial year filter
msds_babies_raw AS (
  SELECT
    -- === IDENTIFIERS ===
    baby.Person_ID_Baby,
    baby.pseudo_nhs_number_ncdr_baby AS NHS_Number_Baby,
    baby.Person_ID_Mother AS Mother_Person_ID,
    baby.UniqPregID,
    baby.LabourDeliveryID AS Labour_Delivery_ID,
    baby.OrgCodeProvider,
    baby.OrgSiteIDActualDelivery AS Org_Site_ID_Actual_Place_Delivery,

    -- === BIRTH DETAILS ===
    -- Baby_Birth_Date is intentionally NULL in this environment.
    -- MSD401BabyDemographics_1 here records only YearOfBirthBaby and
    -- MonthOfBirthBaby — there is NO day-of-birth field. The previously
    -- used DATEFROMPARTS(... MerOfBirthBaby) construction was silently
    -- broken: MerOfBirthBaby is the AM/PM meridian flag, not day-of-month.
    -- Phase 2 (timing-from-birth) is on hold pending access to a separate
    -- environment that contains a real day-of-birth source.
    CAST(NULL AS DATE) AS Baby_Birth_Date,
    baby.PersonBirthTimeBaby AS Baby_Birth_Time,
    baby.BirthOrderMaternitySUS AS Birth_Order,
    baby.GestationLengthBirth AS Gestation_Length_At_Birth,
    baby.PersonPhenSex AS Baby_Sex,
    baby.EthnicCategoryBaby AS Ethnic_Category_Baby,
    baby.PregOutcome AS Pregnancy_Outcome,

    -- === DELIVERY DETAILS ===
    baby.DeliveryMethodCode AS Delivery_Method_Code,
    baby.WaterDeliveryInd AS Delivered_in_Water_Indicator,
    baby.FetusPresentation AS Presentation_of_Fetus,

    -- === FEEDING ===
    baby.BabyFirstFeedDate AS Baby_First_Feed_Date,
    baby.BabyFirstFeedIndCode AS Baby_First_Feed_Breast_Milk_Indication_Code,
    baby.SkinToSkinContact1HourInd AS Skin_to_Skin_Contact_Within_1_Hour_Indicator,

    -- === DISCHARGE/OUTCOME ===
    baby.DischargeDateBabyHosp AS Baby_Discharge_Date,
    baby.DischargeTimeBabyHosp AS Baby_Discharge_Time,
    baby.PersonDeathDateBaby AS Person_Death_Date_Baby,
    baby.PersonDeathTimeBaby AS Person_Death_Time_Baby,

    -- Submission metadata for deduplication
    baby.UniqSubmissionID,
    baby.RecordNumber,

    -- Derived financial year
    CASE
      WHEN baby.MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(baby.YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(baby.YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(baby.YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(baby.YearOfBirthBaby AS VARCHAR(4)), 2))
    END AS Baby_Birth_Financial_Year

  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1 baby
  WHERE CASE
      WHEN baby.MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(baby.YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(baby.YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(baby.YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(baby.YearOfBirthBaby AS VARCHAR(4)), 2))
    END = '2023/24'
    -- Optional: Exclude unknown Person IDs (uncomment to enable)
    -- AND baby.Person_ID_Baby NOT LIKE 'U%'
),

-- Step 4b: Identify babies with multiple mothers (DQ issue - exclude these)
babies_multiple_mothers AS (
  SELECT Person_ID_Baby
  FROM msds_babies_raw
  GROUP BY Person_ID_Baby
  HAVING COUNT(DISTINCT Mother_Person_ID) > 1
),

-- Step 4c: Identify babies with multiple organisations (need special handling)
babies_org_counts AS (
  SELECT
    Person_ID_Baby,
    COUNT(DISTINCT OrgCodeProvider) AS org_count
  FROM msds_babies_raw
  GROUP BY Person_ID_Baby
),

-- Step 4d: Apply deduplication with CQIM-style org matching
msds_babies_deduped AS (
  SELECT
    b.*,
    -- Flag: 1 if provider matches delivery site (first 3 chars), 0 otherwise
    -- This prioritises records from the organisation that actually delivered the baby
    CASE
      WHEN LEFT(b.OrgCodeProvider, 3) = LEFT(b.Org_Site_ID_Actual_Place_Delivery, 3) THEN 1
      WHEN b.Org_Site_ID_Actual_Place_Delivery IS NULL THEN 1  -- Don't penalise missing site
      ELSE 0
    END AS org_matches_delivery,

    -- Deduplication row number with enhanced ordering:
    -- 1. Prioritise records where org matches delivery site
    -- 2. Then by most recent submission
    -- 3. Then by RecordNumber (CQIM methodology)
    --
    -- Partition by Person_ID_Baby ONLY: babies with multiple Mother_Person_ID
    -- values are already excluded via babies_multiple_mothers, and a baby
    -- with multiple UniqPregID values for the same Mother is a DQ artefact
    -- — including UniqPregID in the partition key would let those duplicates
    -- through (~0.6% of babies). One row per baby is what downstream
    -- modelling expects.
    ROW_NUMBER() OVER (
      PARTITION BY b.Person_ID_Baby
      ORDER BY
        CASE
          WHEN LEFT(b.OrgCodeProvider, 3) = LEFT(b.Org_Site_ID_Actual_Place_Delivery, 3) THEN 0
          WHEN b.Org_Site_ID_Actual_Place_Delivery IS NULL THEN 1
          ELSE 2
        END,
        b.UniqSubmissionID DESC,
        b.RecordNumber DESC
    ) AS rn

  FROM msds_babies_raw b
  -- Exclude babies with multiple mothers (DQ issue)
  WHERE b.Person_ID_Baby NOT IN (SELECT Person_ID_Baby FROM babies_multiple_mothers)
),

-- Step 4e: Final baby selection - one record per baby
msds_babies AS (
  SELECT
    Person_ID_Baby,
    NHS_Number_Baby,
    Mother_Person_ID,
    UniqPregID,
    Labour_Delivery_ID,
    OrgCodeProvider,
    Baby_Birth_Date,
    Baby_Birth_Time,
    Birth_Order,
    Gestation_Length_At_Birth,
    Baby_Sex,
    Ethnic_Category_Baby,
    Pregnancy_Outcome,
    Delivery_Method_Code,
    Delivered_in_Water_Indicator,
    Presentation_of_Fetus,
    Org_Site_ID_Actual_Place_Delivery,
    Baby_First_Feed_Date,
    Baby_First_Feed_Breast_Milk_Indication_Code,
    Skin_to_Skin_Contact_Within_1_Hour_Indicator,
    Baby_Discharge_Date,
    Baby_Discharge_Time,
    Person_Death_Date_Baby,
    Person_Death_Time_Baby,
    Baby_Birth_Financial_Year,
    org_matches_delivery  -- Keep for QA purposes
  FROM msds_babies_deduped
  WHERE rn = 1
),

-- ========================================================================
-- STEP 5: Get MSDS Labour and Delivery details
-- ========================================================================
-- DEDUPLICATION: MSD301 has ~3.6 records per LabourDeliveryID
-- Strategy: Keep most recent submission per LabourDeliveryID
-- ========================================================================

msds_labour_raw AS (
  SELECT
    ld.LabourDeliveryID AS Labour_Delivery_ID,
    ld.UniqPregID,

    -- Labour details
    ld.LabourOnsetMethod AS Labour_Delivery_Onset_Method_Code,
    ld.LabourOnsetDate AS Onset_Established_Labour_Date,
    ld.LabourOnsetTime AS Onset_Established_Labour_Time,

    -- Delivery location
    ld.OrgSiteIDIntra AS Org_Site_ID_Start_Intrapartum_Care,
    ld.SettingIntraCare AS Maternity_Care_Setting_Start_Intrapartum_Care,

    -- Caesarean section
    ld.CaesareanDate AS Procedure_Date_Caesarean_Section,
    ld.CaesareanTime AS Procedure_Time_Caesarean_Section,
    ld.DecisionToDeliverDate AS Decision_to_Deliver_Date,
    ld.DecisionToDeliverTime AS Decision_to_Deliver_Time,

    -- Mother's hospital spell
    ld.StartDateMotherDeliveryHospProvSpell AS Mother_Admission_Date,
    ld.DischargeDateMotherHosp AS Mother_Discharge_Date,

    -- Deduplication row number
    ROW_NUMBER() OVER (
      PARTITION BY ld.LabourDeliveryID
      ORDER BY ld.UniqSubmissionID DESC
    ) AS rn

  FROM UDAL_Warehouse.MESH_MSDS.MSD301LabourDelivery_1 ld
  WHERE ld.StartDateMotherDeliveryHospProvSpell >= '2023-04-01'
    and ld.StartDateMotherDeliveryHospProvSpell < '2024-04-01'
),

msds_labour AS (
  SELECT
    Labour_Delivery_ID,
    UniqPregID,
    Labour_Delivery_Onset_Method_Code,
    Onset_Established_Labour_Date,
    Onset_Established_Labour_Time,
    Org_Site_ID_Start_Intrapartum_Care,
    Maternity_Care_Setting_Start_Intrapartum_Care,
    Procedure_Date_Caesarean_Section,
    Procedure_Time_Caesarean_Section,
    Decision_to_Deliver_Date,
    Decision_to_Deliver_Time,
    Mother_Admission_Date,
    Mother_Discharge_Date
  FROM msds_labour_raw
  WHERE rn = 1
),

-- ========================================================================
-- STEP 6: Get MSDS Mother Demographics
-- ========================================================================
-- DEDUPLICATION: MSD001 has ~10x duplication per Person_ID_Mother
-- Strategy: Keep most recent submission per Person_ID_Mother
-- ========================================================================

msds_mothers_raw AS (
  SELECT
    mother.Person_ID_Mother,

    -- Demographics
    mother.EthnicCategoryMother AS Ethnic_Category_Mother,
    mother.PersonDeathDateMother AS Person_Death_Date_Mother,

    -- Geography
    mother.OrgIDResidenceResp AS Mother_CCG_Residence,
    mother.LSOAMother2011 AS Mother_LSOA_2011,
    mother.Der_Postcode_LSOA_Code AS Mother_LSOA_Derived,

    -- Deprivation (pre-derived in MSDS - 2015 vintage)
    mother.Rank_IMD_Decile_2015 AS IMD_Decile_2015,

    -- Deduplication row number
    ROW_NUMBER() OVER (
      PARTITION BY mother.Person_ID_Mother
      ORDER BY mother.UniqSubmissionID DESC
    ) AS rn

  FROM UDAL_Warehouse.MESH_MSDS.MSD001MotherDemog_1 mother
),

msds_mothers AS (
  SELECT
    Person_ID_Mother,
    Ethnic_Category_Mother,
    Person_Death_Date_Mother,
    Mother_CCG_Residence,
    COALESCE(Mother_LSOA_2011, Mother_LSOA_Derived) AS Mother_LSOA,
    IMD_Decile_2015
  FROM msds_mothers_raw
  WHERE rn = 1
),

-- ========================================================================
-- STEP 7: Get MSDS Pregnancy and Booking details
-- ========================================================================
-- DEDUPLICATION: MSD101 has ~10 records per UniqPregID (worst duplication!)
-- Strategy: Keep most recent submission per UniqPregID
-- ========================================================================

msds_pregnancy_raw AS (
  SELECT
    preg.UniqPregID,
    preg.Person_ID_Mother,

    -- Booking
    preg.AntenatalAppDate AS Antenatal_Booking_Date,
    preg.PregFirstConDate AS Pregnancy_First_Contact_Date,
    preg.EDDAgreed AS Estimated_Date_Delivery_Agreed,
    preg.LastMenstrualPeriodDate AS Last_Menstrual_Period_Date,

    -- Obstetric history
    preg.PreviousCaesareanSections AS Previous_Caesareans,
    preg.PreviousLiveBirths AS Previous_Live_Births,
    preg.PreviousStillBirths AS Previous_Stillbirths,
    preg.PreviousLossesLessThan24Weeks AS Previous_Losses,

    -- Social factors (for inequalities analysis)
    preg.DisabilityIndMother AS Disability_Indicator_At_Antenatal_Booking,
    preg.MHPredictionDetectionIndMother AS Mental_Health_Prediction_Detection_Indicator_At_Antenatal_Booking,
    preg.ComplexSocialFactorsInd AS Complex_Social_Factors_Indicator_At_Antenatal_Booking,
    preg.EmploymentStatusMother AS Employment_Status_Mother_At_Antenatal_Booking,
    preg.SupportStatusIndMother AS Support_Status_Indicator_At_Antenatal_Booking,

    -- Commissioner
    preg.OrgIDComm AS Org_ID_Commissioner,

    -- Deduplication row number
    ROW_NUMBER() OVER (
      PARTITION BY preg.UniqPregID
      ORDER BY preg.UniqSubmissionID DESC
    ) AS rn

  FROM UDAL_Warehouse.MESH_MSDS.MSD101PregnancyBooking_1 preg
),

msds_pregnancy AS (
  SELECT
    UniqPregID,
    Person_ID_Mother,
    Antenatal_Booking_Date,
    Pregnancy_First_Contact_Date,
    Estimated_Date_Delivery_Agreed,
    Last_Menstrual_Period_Date,
    Previous_Caesareans,
    Previous_Live_Births,
    Previous_Stillbirths,
    Previous_Losses,
    Disability_Indicator_At_Antenatal_Booking,
    Mental_Health_Prediction_Detection_Indicator_At_Antenatal_Booking,
    Complex_Social_Factors_Indicator_At_Antenatal_Booking,
    Employment_Status_Mother_At_Antenatal_Booking,
    Support_Status_Indicator_At_Antenatal_Booking,
    Org_ID_Commissioner
  FROM msds_pregnancy_raw
  WHERE rn = 1
),

-- ========================================================================
-- STEP 8: Get MSDS Neonatal Admission indicator + first-CC timing
-- ========================================================================
-- DEDUPLICATION: MSD402 has ~1.4 records per baby (lowest duplication)
-- This table contains multiple transfers per baby AND duplicate submissions.
--
-- TIMING NOTE (Phase 2 reframe):
-- The MSD402 NeonatalTransferStartDate/Time fields are used as the primary
-- source of timing for "time from birth to first critical-care episode".
-- PbR_CC_Monthly NCC records have NULL CC_Start_Time (only ACC has it),
-- so MSDS is the only source with minute-resolution timing.
--
-- Two row-number passes:
--   1. rn       — dedupe duplicate submissions of the same transfer
--   2. cc_rn    — pick the FIRST critical-care transfer per baby
--
-- Critical: getting the first CC date+time as a SINGLE ROW (rather than
-- MIN(date), MIN(time) independently) avoids combining values from
-- different transfers, which produced the negative-time bug.
-- ========================================================================

msds_neonatal_adm_raw AS (
  SELECT
    nadm.Person_ID_Baby,
    nadm.NeonatalTransferStartDate,
    nadm.NeonatalTransferStartTime,
    nadm.NeoCritCareInd,

    -- Deduplication row number (per baby + transfer date/time to handle duplicate submissions)
    ROW_NUMBER() OVER (
      PARTITION BY nadm.Person_ID_Baby,
                   nadm.NeonatalTransferStartDate,
                   nadm.NeonatalTransferStartTime
      ORDER BY nadm.UniqSubmissionID DESC
    ) AS rn

  FROM UDAL_Warehouse.MESH_MSDS.MSD402NeonatalAdmission_1 nadm
),

-- First critical-care transfer per baby (filters to NeoCritCareInd='Y').
-- Date and time come from the SAME row, so they cannot be mismatched.
msds_neonatal_first_cc AS (
  SELECT
    Person_ID_Baby,
    NeonatalTransferStartDate AS NCC_MSDS_First_CC_Date,
    NeonatalTransferStartTime AS NCC_MSDS_First_CC_Time
  FROM (
    SELECT
      Person_ID_Baby,
      NeonatalTransferStartDate,
      NeonatalTransferStartTime,
      ROW_NUMBER() OVER (
        PARTITION BY Person_ID_Baby
        ORDER BY NeonatalTransferStartDate ASC,
                 NeonatalTransferStartTime ASC
      ) AS cc_rn
    FROM msds_neonatal_adm_raw
    WHERE rn = 1
      AND NeoCritCareInd = 'Y'
      AND NeonatalTransferStartDate IS NOT NULL
  ) ranked
  WHERE cc_rn = 1
),

msds_neonatal_adm AS (
  SELECT
    Person_ID_Baby,
    MAX(CASE WHEN NeoCritCareInd = 'Y' THEN 1 ELSE 0 END) AS NCC_MSDS_Admitted
  FROM msds_neonatal_adm_raw
  WHERE rn = 1
  GROUP BY Person_ID_Baby
),

-- ========================================================================
-- STEP 8b: Get Birth Weight and Apgar Scores from MSD405
-- ========================================================================
-- MSD405 stores clinical observations in EAV format (one row per observation)
-- ObsCode contains SNOMED CT codes identifying the observation type:
--   - 364589006 = Birth weight (grams)
--   - 27113001  = Body weight (grams) - alternative code for birth weight
--   - 169895004 = Apgar score at 1 minute
--   - 169909004 = Apgar score at 5 minutes
-- Strategy: Pivot observations to columns, deduplicate, aggregate per baby
-- ========================================================================

msds_observations_raw AS (
  SELECT
    obs.Person_ID_Baby,
    obs.ObsCode,
    obs.ObsValue,
    obs.BirthWeight,
    obs.ApgarScore,
    obs.ClinInterDateBaby,

    -- Deduplication: keep most recent submission per baby + observation type
    ROW_NUMBER() OVER (
      PARTITION BY obs.Person_ID_Baby, obs.ObsCode
      ORDER BY obs.UniqSubmissionID DESC
    ) AS rn

  FROM UDAL_Warehouse.MESH_MSDS.MSD405CareActivityBaby obs
  WHERE obs.RPStartDate >= '2023-04-01'
    AND obs.RPStartDate < '2024-04-01'
    -- Filter to relevant observation codes (birth weight, Apgar 1 min, Apgar 5 min)
    AND (
      obs.ObsCode IN ('364589006', '27113001', '169895004', '169909004')  -- SNOMED codes
      OR obs.BirthWeight IS NOT NULL
      OR obs.ApgarScore IS NOT NULL
    )
),

msds_observations AS (
  SELECT
    Person_ID_Baby,

    -- Birth weight (grams) - try BirthWeight column first, then ObsValue for SNOMED codes
    MAX(CASE
      WHEN BirthWeight IS NOT NULL THEN TRY_CAST(BirthWeight AS INT)
      WHEN ObsCode IN ('364589006', '27113001') THEN TRY_CAST(ObsValue AS INT)
      ELSE NULL
    END) AS Birth_Weight_Grams,

    -- Apgar score at 1 minute
    MAX(CASE
      WHEN ObsCode = '169895004' THEN TRY_CAST(COALESCE(ApgarScore, ObsValue) AS INT)
      ELSE NULL
    END) AS Apgar_Score_1_Minute,

    -- Apgar score at 5 minutes
    MAX(CASE
      WHEN ObsCode = '169909004' THEN TRY_CAST(COALESCE(ApgarScore, ObsValue) AS INT)
      ELSE NULL
    END) AS Apgar_Score_5_Minutes

  FROM msds_observations_raw
  WHERE rn = 1
  GROUP BY Person_ID_Baby
),

-- ========================================================================
-- STEP 9: Main query - Join everything together
-- ========================================================================
base_dataset AS (
  SELECT
    -- === BABY IDENTIFIERS ===
    baby.Person_ID_Baby,
    baby.NHS_Number_Baby,

    -- === BIRTH DETAILS ===
    baby.Baby_Birth_Date,
    baby.Baby_Birth_Time,
    baby.Birth_Order,
    baby.Gestation_Length_At_Birth,
    baby.Baby_Sex,
    baby.Ethnic_Category_Baby,
    baby.Pregnancy_Outcome,
    baby.Baby_Birth_Financial_Year,

    -- === CLINICAL SEVERITY (from MSD405) ===
    obs.Birth_Weight_Grams,
    obs.Apgar_Score_1_Minute,
    obs.Apgar_Score_5_Minutes,

    -- === DELIVERY DETAILS ===
    baby.Delivery_Method_Code,
    baby.Delivered_in_Water_Indicator,
    baby.Presentation_of_Fetus,
    baby.Org_Site_ID_Actual_Place_Delivery AS Delivery_Site_Code,
    baby.OrgCodeProvider AS Submitting_Org_Code,  -- Added for transparency

    -- === DATA QUALITY FLAG ===
    baby.org_matches_delivery AS DQ_Org_Matches_Delivery,  -- 1 = provider matches delivery site

    -- === FEEDING ===
    baby.Baby_First_Feed_Date,
    baby.Baby_First_Feed_Breast_Milk_Indication_Code,
    baby.Skin_to_Skin_Contact_Within_1_Hour_Indicator,

    -- === BABY DISCHARGE/OUTCOME ===
    baby.Baby_Discharge_Date,
    baby.Person_Death_Date_Baby AS Baby_Death_Date,

    -- === LABOUR AND DELIVERY ===
    labour.Labour_Delivery_Onset_Method_Code,
    labour.Onset_Established_Labour_Date,
    labour.Maternity_Care_Setting_Start_Intrapartum_Care,
    labour.Procedure_Date_Caesarean_Section,
    labour.Mother_Admission_Date,
    labour.Mother_Discharge_Date,

    -- === MATERNAL DEMOGRAPHICS (FOR INEQUALITIES ANALYSIS) ===
    mother.Ethnic_Category_Mother,
    mother.Mother_CCG_Residence,
    mother.Mother_LSOA,
    mother.IMD_Decile_2015,

    -- === PREGNANCY/BOOKING (SOCIAL FACTORS FOR INEQUALITIES) ===
    preg.Antenatal_Booking_Date,
    preg.Pregnancy_First_Contact_Date,
    preg.Previous_Caesareans,
    preg.Previous_Live_Births,
    preg.Previous_Stillbirths,
    preg.Disability_Indicator_At_Antenatal_Booking,
    preg.Mental_Health_Prediction_Detection_Indicator_At_Antenatal_Booking,
    preg.Complex_Social_Factors_Indicator_At_Antenatal_Booking,
    preg.Employment_Status_Mother_At_Antenatal_Booking,
    preg.Org_ID_Commissioner,

    -- ===================================================================
    -- NCC ADMISSION FLAGS (Compare MSDS vs CC data)
    -- ===================================================================
    COALESCE(msds_ncc.NCC_MSDS_Admitted, 0) AS NCC_MSDS_Admitted,
    COALESCE(cc_ncc.NCC_CC_Admitted, 0) AS NCC_CC_Admitted,

    -- Combined NCC admission flag (1 if in EITHER source)
    CASE
      WHEN COALESCE(msds_ncc.NCC_MSDS_Admitted, 0) = 1
        OR COALESCE(cc_ncc.NCC_CC_Admitted, 0) = 1
      THEN 1
      ELSE 0
    END AS NCC_Admitted,

    -- Data quality flag (1 if in BOTH sources, 0 if in one, NULL if in neither)
    CASE
      WHEN COALESCE(msds_ncc.NCC_MSDS_Admitted, 0) = 1
       AND COALESCE(cc_ncc.NCC_CC_Admitted, 0) = 1
      THEN 1
      WHEN COALESCE(msds_ncc.NCC_MSDS_Admitted, 0) = 1
        OR COALESCE(cc_ncc.NCC_CC_Admitted, 0) = 1
      THEN 0
      ELSE NULL
    END AS NCC_In_Both_Sources,

    -- ===================================================================
    -- TIMING TO FIRST CRITICAL-CARE EPISODE (Phase 2 outcome)
    -- ===================================================================
    -- Two raw timing sources:
    --   * MSDS (MSD402) — minute resolution, from a single ranked row
    --     (filtered to NeoCritCareInd='Y'). Coverage is partial: not all
    --     CC-admitted babies appear in MSD402, and providers vary in
    --     submission completeness.
    --   * PbR_CC_Monthly — date only (CC_Start_Time is NULL for NCC),
    --     so resolution is days. Broader coverage.
    --
    -- A unified "best available" field is computed in the final SELECT.
    -- Negative values (clock-skew artefacts) are floored to 0 there too.
    -- ===================================================================

    -- MSDS first critical-care transfer (date and time from the SAME row)
    msds_first_cc.NCC_MSDS_First_CC_Date,
    msds_first_cc.NCC_MSDS_First_CC_Time,

    -- Minutes from birth to first CC episode (MSDS, minute resolution)
    CASE
      WHEN msds_first_cc.NCC_MSDS_First_CC_Date IS NOT NULL THEN
        DATEDIFF(
          minute,
          DATEADD(second,
                  ISNULL(CAST(DATEDIFF(second, '00:00:00', CAST(baby.Baby_Birth_Time AS TIME)) AS BIGINT), 0),
                  CAST(baby.Baby_Birth_Date AS DATETIME)),
          DATEADD(second,
                  ISNULL(CAST(DATEDIFF(second, '00:00:00', CAST(msds_first_cc.NCC_MSDS_First_CC_Time AS TIME)) AS BIGINT), 0),
                  CAST(msds_first_cc.NCC_MSDS_First_CC_Date AS DATETIME))
        )
      ELSE NULL
    END AS Minutes_Birth_To_First_CC_MSDS_Raw,

    -- ===================================================================
    -- NCC DETAILS (from PbR CC data)
    -- ===================================================================
    COALESCE(cc_ncc.NCC_CC_First_Admission_Date, cc_ncc.NCC_CC_First_Activity_Date) AS NCC_CC_First_Admission_Date,
    cc_ncc.NCC_CC_First_Admission_Time,
    cc_ncc.NCC_CC_Last_Discharge_Date,

    -- Days from birth to first CC admission (PbR, date only — time is NULL for NCC)
    CASE
      WHEN cc_ncc.NCC_CC_Admitted = 1 THEN
        DATEDIFF(
          day,
          CAST(baby.Baby_Birth_Date AS DATE),
          CAST(COALESCE(cc_ncc.NCC_CC_First_Admission_Date, cc_ncc.NCC_CC_First_Activity_Date) AS DATE)
        )
      ELSE NULL
    END AS Days_Birth_To_First_CC_PbR_Raw,

    -- Length of stay (and how many APCS spells were collapsed per baby)
    cc_ncc.NCC_CC_Number_Of_Spells,
    cc_ncc.NCC_CC_Total_Days,
    cc_ncc.NCC_CC_Number_Of_Periods,

    -- Clinical details from CC
    cc_ncc.NCC_CC_Gestation_Weeks,
    cc_ncc.NCC_CC_Birth_Weight_Grams,

    -- Combined birth weight: MSDS first, CC as fallback (improves NCC completeness from 47% to 94%)
    COALESCE(obs.Birth_Weight_Grams, cc_ncc.NCC_CC_Birth_Weight_Grams) AS Birth_Weight_Combined,

    -- Care levels
    cc_ncc.NCC_CC_Level2_Days,
    cc_ncc.NCC_CC_Level3_Days,

    -- Unit characteristics
    cc_ncc.NCC_CC_First_Unit_Function,
    cc_ncc.NCC_CC_Admission_Source,

    -- Discharge
    cc_ncc.NCC_CC_Final_Discharge_Status,
    cc_ncc.NCC_CC_Final_Discharge_Destination,

    -- Provider (for hospital random effects)
    cc_ncc.NCC_CC_Provider_Code AS NCC_Hospital_Provider_Code,

    -- ===================================================================
    -- APCS SPELL OUTCOME (A5b — second, independent death source)
    -- ===================================================================
    -- From ALL APCS spells linked by pseudo NHS number, not just CC-linked
    -- ones. NULL = baby never linked to an APCS spell in the window;
    -- 0/1 flags only where a link exists.
    apcs_out.APCS_Spell_Count,
    apcs_out.APCS_Died_In_Hospital,
    apcs_out.APCS_Stillbirth_Coded,
    apcs_out.APCS_Death_Spell_Discharge_Date

  FROM msds_babies baby

  -- Link to labour/delivery
  LEFT JOIN msds_labour labour
    ON baby.Labour_Delivery_ID = labour.Labour_Delivery_ID

  -- Link to pregnancy
  LEFT JOIN msds_pregnancy preg
    ON baby.UniqPregID = preg.UniqPregID

  -- Link to mother
  LEFT JOIN msds_mothers mother
    ON baby.Mother_Person_ID = mother.Person_ID_Mother

  -- Link to clinical observations (birth weight, Apgar scores)
  LEFT JOIN msds_observations obs
    ON baby.Person_ID_Baby = obs.Person_ID_Baby

  -- Link to MSDS neonatal admission (admitted flag)
  LEFT JOIN msds_neonatal_adm msds_ncc
    ON baby.Person_ID_Baby = msds_ncc.Person_ID_Baby

  -- Link to MSDS first critical-care transfer (date+time from a single row)
  LEFT JOIN msds_neonatal_first_cc msds_first_cc
    ON baby.Person_ID_Baby = msds_first_cc.Person_ID_Baby

  -- Link to CC NCC data via NHS Number — one row per baby (multiple APCS
  -- spells already collapsed in ncc_cc_per_baby). The 90-day proximity
  -- filter that lived here previously depended on Baby_Birth_Date, which
  -- in this environment is unreliable (no day-of-birth field — see comments
  -- in msds_babies_raw). FY containment on both sides now restricts the
  -- linkage window.
  LEFT JOIN ncc_cc_per_baby cc_ncc
    ON baby.NHS_Number_Baby = cc_ncc.NCC_CC_NHS_Number

  -- Link to APCS spell outcome — one row per pseudo NHS number (aggregated
  -- in apcs_outcome_per_baby), so this join cannot fan out the base.
  LEFT JOIN apcs_outcome_per_baby apcs_out
    ON baby.NHS_Number_Baby = apcs_out.Der_Pseudo_NHS_Number

  -- Filter: Only babies with a hospital admission/spell
  WHERE labour.Mother_Admission_Date IS NOT NULL
)

-- ========================================================================
-- FINAL OUTPUT
-- ========================================================================
-- Adds derived timing fields:
--   * Hours_Birth_To_First_CC_MSDS  — minute-resolution, floored at 0
--   * Hours_Birth_To_First_CC_PbR   — day-resolution × 24, floored at 0
--   * Hours_Birth_To_First_CC       — unified, prefer MSDS where available
--   * Hours_Birth_To_First_CC_Source — 'MSDS' | 'PbR' | NULL
--
-- Negative raw values arise from clock skew / midnight rollovers and are
-- floored to 0 (a baby cannot enter critical care before being born).
-- ========================================================================
SELECT
  bd.*,

  -- MSDS-derived hours (minute precision / 60), non-negative
  CASE
    WHEN bd.Minutes_Birth_To_First_CC_MSDS_Raw IS NULL THEN NULL
    ELSE CAST(
      CASE WHEN bd.Minutes_Birth_To_First_CC_MSDS_Raw < 0 THEN 0
           ELSE bd.Minutes_Birth_To_First_CC_MSDS_Raw
      END AS FLOAT) / 60.0
  END AS Hours_Birth_To_First_CC_MSDS,

  -- PbR-derived hours (day precision × 24), non-negative
  CASE
    WHEN bd.Days_Birth_To_First_CC_PbR_Raw IS NULL THEN NULL
    ELSE CAST(
      CASE WHEN bd.Days_Birth_To_First_CC_PbR_Raw < 0 THEN 0
           ELSE bd.Days_Birth_To_First_CC_PbR_Raw
      END AS FLOAT) * 24.0
  END AS Hours_Birth_To_First_CC_PbR,

  -- Unified "best available" timing: prefer MSDS (minute resolution), fall back to PbR (day resolution)
  CASE
    WHEN bd.Minutes_Birth_To_First_CC_MSDS_Raw IS NOT NULL THEN
      CAST(
        CASE WHEN bd.Minutes_Birth_To_First_CC_MSDS_Raw < 0 THEN 0
             ELSE bd.Minutes_Birth_To_First_CC_MSDS_Raw
        END AS FLOAT) / 60.0
    WHEN bd.Days_Birth_To_First_CC_PbR_Raw IS NOT NULL THEN
      CAST(
        CASE WHEN bd.Days_Birth_To_First_CC_PbR_Raw < 0 THEN 0
             ELSE bd.Days_Birth_To_First_CC_PbR_Raw
        END AS FLOAT) * 24.0
    ELSE NULL
  END AS Hours_Birth_To_First_CC,

  -- Source flag for the unified timing field
  CASE
    WHEN bd.Minutes_Birth_To_First_CC_MSDS_Raw IS NOT NULL THEN 'MSDS'
    WHEN bd.Days_Birth_To_First_CC_PbR_Raw IS NOT NULL THEN 'PbR'
    ELSE NULL
  END AS Hours_Birth_To_First_CC_Source

FROM base_dataset bd
WHERE bd.Baby_Birth_Financial_Year = '2023/24'
-- Order by NHS number only: Baby_Birth_Date is NULL in this environment
-- (no day-of-birth field), so it cannot be used as a sort key.
ORDER BY
  bd.NHS_Number_Baby;

/*
============================================================================
NOTES:
============================================================================
1. DEDUPLICATION (CRITICAL):
   All MSDS tables have significant duplication due to multiple submissions:
   - MSD401 (Baby Demographics): ~3.4 records per baby
   - MSD301 (Labour/Delivery): ~3.6 records per LabourDeliveryID
   - MSD101 (Pregnancy/Booking): ~10 records per UniqPregID
   - MSD402 (Neonatal Admissions): ~1.4 records per baby
   - MSD001 (Mother Demographics): ~10 records per Person_ID_Mother
   - MSD405 (Care Activity/Observations): Multiple rows per baby (EAV format)

   Deduplication strategy: ROW_NUMBER() partitioned by natural key, ordered by
   UniqSubmissionID DESC (most recent submission), then filter WHERE rn = 1.

2. DATA QUALITY EXCLUSIONS (NEW - aligned with CQIM methodology):
   - Babies with multiple mothers: 823 records (0.15%) EXCLUDED
   - Babies with multiple orgs: 19,488 records (3.6%) - HANDLED via org-match priority
   - Unknown Person IDs: ~15,000 records (2.8%) - OPTIONAL filter (uncomment to enable)

   After exclusions: ~507k babies (from ~541k raw) = 93.6% retained

3. MULTI-ORGANISATION HANDLING (NEW):
   When a baby has records from multiple providers (3.6% of cases), we prioritise
   the record where OrgCodeProvider matches OrgSiteIDActualDelivery (first 3 chars).
   This follows CQIM methodology used in official NHS maternity statistics.

   DQ_Org_Matches_Delivery flag indicates whether the selected record matched.

4. NCC admission status comes from TWO sources for comparison:
   - NCC_MSDS_Admitted: From MSD402_NeonatalAdmission_1
   - NCC_CC_Admitted: From Pbr_CC_Monthly (CC_Type='NCC')
   - NCC_Admitted: Combined flag (1 if in EITHER source)

5. NCC_In_Both_Sources checks data consistency:
   - 1 = In both MSDS and CC data (good data quality)
   - 0 = In only one source (investigate discrepancies)
   - NULL = Not admitted to NCC

6. CLINICAL SEVERITY (from MSD405CareActivityBaby):
   - Birth_Weight_Grams: From BirthWeight column or SNOMED codes 364589006, 27113001
   - Apgar_Score_1_Minute: From SNOMED code 169895004
   - Apgar_Score_5_Minutes: From SNOMED code 169909004
   - Birth_Weight_Combined: COALESCE(MSDS, CC) - improves NCC baby completeness 47%→94%
   MSD405 uses EAV format - observations pivoted to columns per baby.

7. DEPRIVATION (from MSD001MotherDemog_1):
   - Mother_LSOA: COALESCE(LSOAMother2011, Der_Postcode_LSOA_Code) for IMD lookup
   - IMD_Decile_2015: Pre-derived IMD decile (2015 vintage - consider updating)
   For current IMD (2019), join Mother_LSOA to ONS IMD lookup table.

8. For hierarchical model:
   - Fixed effects: Birth_Weight_Combined, Gestation_Length_At_Birth,
                    Apgar_Score_1_Minute, Apgar_Score_5_Minutes,
                    Ethnic_Category_Baby/Mother, IMD_Decile
   - Random effects: NCC_Hospital_Provider_Code, Delivery_Site_Code,
                     Org_ID_Commissioner

9. PHASE 2 TIMING (reframed — see CLAUDE.md for context):
   The original Hours_Birth_To_NCC_MSDS / Hours_Birth_To_NCC_CC fields
   have been replaced. Issues with the old approach:
     a) MSD402 timing was aggregated as MIN(date), MIN(time) independently,
        which could combine values from different transfers (negative time).
     b) PbR_CC_Monthly NCC records have NULL CC_Start_Time (only ACC has it),
        so PbR can only ever provide DAY resolution, not hour.
     c) Old MSDS path did not filter to NeoCritCareInd='Y', so non-CC
        transfers polluted the "first NCC admission" timing.

   New fields:
     - NCC_MSDS_First_CC_Date / _Time     — first MSD402 row with
       NeoCritCareInd='Y' (single ranked row, date+time consistent)
     - Minutes_Birth_To_First_CC_MSDS_Raw — raw signed minutes (debug only)
     - Days_Birth_To_First_CC_PbR_Raw     — raw signed days (debug only)
     - Hours_Birth_To_First_CC_MSDS       — minute precision, floored at 0
     - Hours_Birth_To_First_CC_PbR        — day precision × 24, floored at 0
     - Hours_Birth_To_First_CC            — unified, prefer MSDS
     - Hours_Birth_To_First_CC_Source     — 'MSDS' | 'PbR' | NULL

   Reframed outcome: "Time from birth to first critical-care episode
   (CC level 2/3)", conditional on having one. The model asks whether,
   conditional on baseline severity (gestation, birth weight, Apgar),
   timing differs by ethnicity / deprivation / hospital. This is NOT
   "time to NCC unit admission" — see CLAUDE.md and survival_results.qmd.
============================================================================
*/
