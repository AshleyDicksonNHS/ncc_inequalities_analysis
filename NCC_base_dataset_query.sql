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
- Linked: Mother demographics, pregnancy, and delivery details (all deduplicated)
- Joined: NCC critical care data (aggregated from daily to birth-level)
- Compared: NCC data from both MSDS (MSD402) and PbR_CC_Monthly sources
- Linkage: via APCS NHS_Number

OUTPUT: One record per birth with NCC admission status and details
EXPECTED: ~540k births per financial year (2019/20 onwards)
============================================================================
*/

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
    AND cc.Der_Financial_Year = '2023/24'

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
    apcs.Der_Postcode_MSOA_2011_Code

  FROM UDAL_Warehouse.MESH_APC.APCS_Core_Daily apcs
  WHERE apcs.Der_Financial_Year = '2023/24'
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
-- STEP 4: Get MSDS Baby Demographics and Birth Details (BASE TABLE)
-- ========================================================================
-- DEDUPLICATION: MSD401 has ~3.4 records per baby due to multiple submissions
-- Analysis shows 99%+ of duplicates have identical clinical data, only differ
-- in submission metadata (UniqSubmissionID, AuditId, etc.)
-- Strategy: Keep most recent submission per Person_ID_Baby
-- ========================================================================

msds_babies_raw AS (
  SELECT
    -- === IDENTIFIERS ===
    baby.Person_ID_Baby,
    baby.pseudo_nhs_number_ncdr_baby AS NHS_Number_Baby,
    baby.Person_ID_Mother AS Mother_Person_ID,
    baby.UniqPregID,
    baby.LabourDeliveryID AS Labour_Delivery_ID,

    -- === BIRTH DETAILS ===
    -- NOTE: Person_Birth_Date_Baby needs to be constructed from YearOfBirthBaby, MonthOfBirthBaby, MerOfBirthBaby
    DATEFROMPARTS(baby.YearOfBirthBaby, baby.MonthOfBirthBaby, ISNULL(baby.MerOfBirthBaby, 1)) AS Baby_Birth_Date,
    baby.PersonBirthTimeBaby AS Baby_Birth_Time,
    baby.BirthOrderMaternitySUS AS Birth_Order,
    baby.GestationLengthBirth AS Gestation_Length_At_Birth,
    -- baby.Birth_Weight,  -- NOT IN MSD401 TABLE - USE MSD405CareActivityBaby_1
    baby.PersonPhenSex AS Baby_Sex,
    baby.EthnicCategoryBaby AS Ethnic_Category_Baby,
    baby.PregOutcome AS Pregnancy_Outcome,

    -- === DELIVERY DETAILS ===
    baby.DeliveryMethodCode AS Delivery_Method_Code,
    baby.WaterDeliveryInd AS Delivered_in_Water_Indicator,
    baby.FetusPresentation AS Presentation_of_Fetus,
    baby.OrgSiteIDActualDelivery AS Org_Site_ID_Actual_Place_Delivery,

    -- === BABY CONDITION AT BIRTH ===
    -- baby.Apgar_Score_At_1_Minute,  -- NOT IN MSD401 TABLE - USE MSD405CareActivityBaby_1
    -- baby.Apgar_Score_At_2_Minutes,  -- NOT IN MSD401 TABLE
    -- baby.Apgar_Score_At_5_Minutes,  -- NOT IN MSD401 TABLE - USE MSD405CareActivityBaby_1
    -- baby.Apgar_Score_At_10_Minutes,  -- NOT IN MSD401 TABLE

    -- === FEEDING ===
    baby.BabyFirstFeedDate AS Baby_First_Feed_Date,
    baby.BabyFirstFeedIndCode AS Baby_First_Feed_Breast_Milk_Indication_Code,
    baby.SkinToSkinContact1HourInd AS Skin_to_Skin_Contact_Within_1_Hour_Indicator,

    -- === DISCHARGE/OUTCOME ===
    baby.DischargeDateBabyHosp AS Baby_Discharge_Date,
    baby.DischargeTimeBabyHosp AS Baby_Discharge_Time,
    baby.PersonDeathDateBaby AS Person_Death_Date_Baby,
    baby.PersonDeathTimeBaby AS Person_Death_Time_Baby,

    -- Derived financial year
    CASE
      WHEN baby.MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(baby.YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(baby.YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(baby.YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(baby.YearOfBirthBaby AS VARCHAR(4)), 2))
    END AS Baby_Birth_Financial_Year,

    -- Deduplication row number
    ROW_NUMBER() OVER (
      PARTITION BY baby.Person_ID_Baby
      ORDER BY baby.UniqSubmissionID DESC, baby.LabourDeliveryID
    ) AS rn

  FROM UDAL_Warehouse.MESH_MSDS.MSD401BabyDemographics_1 baby
  WHERE CASE
      WHEN baby.MonthOfBirthBaby >= 4
        THEN CONCAT(CAST(baby.YearOfBirthBaby AS VARCHAR(4)), '/',
                    RIGHT(CAST((CAST(baby.YearOfBirthBaby AS BIGINT) + 1) AS VARCHAR(10)), 2))
      ELSE CONCAT(CAST((CAST(baby.YearOfBirthBaby AS BIGINT) - 1) AS VARCHAR(10)), '/',
                  RIGHT(CAST(baby.YearOfBirthBaby AS VARCHAR(4)), 2))
    END = '2023/24'
),

msds_babies AS (
  SELECT
    Person_ID_Baby,
    NHS_Number_Baby,
    Mother_Person_ID,
    UniqPregID,
    Labour_Delivery_ID,
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
    Baby_Birth_Financial_Year
  FROM msds_babies_raw
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
    -- ld.Maternity_Care_Setting_Actual_Place_Birth,  -- NOTE: According to mapping, SettingPlaceBirth is in Baby table, not Labour table

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
-- DEDUPLICATION: MSD001 has duplicates per Person_ID_Mother
-- Strategy: Keep most recent submission per Person_ID_Mother
-- ========================================================================

msds_mothers_raw AS (
  SELECT
    mother.Person_ID_Mother,

    -- Demographics
    -- mother.Person_Birth_Date_Mother,  -- NOT IN TABLE - need to derive from age if needed
    mother.EthnicCategoryMother AS Ethnic_Category_Mother,
    -- mother.Postcode_Usual_Address_Mother,  -- NOT IN TABLE - use PostcodeDistrictMother, LSOAMother2011 instead
    mother.PersonDeathDateMother AS Person_Death_Date_Mother,

    -- Geography
    mother.OrgIDResidenceResp AS Mother_CCG_Residence,

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
    Mother_CCG_Residence
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
-- STEP 8: Get MSDS Neonatal Admission indicator
-- ========================================================================
-- DEDUPLICATION: MSD402 has ~2.1 records per baby
-- This table contains multiple transfers per baby AND duplicate submissions
-- Strategy: First deduplicate submissions, then aggregate transfers to baby level
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

msds_neonatal_adm AS (
  SELECT
    Person_ID_Baby,
    MIN(NeonatalTransferStartDate) AS NCC_MSDS_First_Transfer_Date,
    MIN(NeonatalTransferStartTime) AS NCC_MSDS_First_Transfer_Time,
    MAX(CASE WHEN NeoCritCareInd = 'Y' THEN 1 ELSE 0 END) AS NCC_MSDS_Admitted
  FROM msds_neonatal_adm_raw
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
    -- baby.Birth_Weight,  -- NOT IN MSD401 TABLE - USE MSD405CareActivityBaby_1
    baby.Baby_Sex,
    baby.Ethnic_Category_Baby,
    baby.Pregnancy_Outcome,
    baby.Baby_Birth_Financial_Year,

    -- === DELIVERY DETAILS ===
    baby.Delivery_Method_Code,
    baby.Delivered_in_Water_Indicator,
    baby.Presentation_of_Fetus,
    baby.Org_Site_ID_Actual_Place_Delivery AS Delivery_Site_Code,

    -- === BABY CONDITION AT BIRTH (SEVERITY) ===
    -- baby.Apgar_Score_At_1_Minute,  -- NOT IN MSD401 TABLE - USE MSD405CareActivityBaby_1
    -- baby.Apgar_Score_At_2_Minutes,  -- NOT IN MSD401 TABLE
    -- baby.Apgar_Score_At_5_Minutes,  -- NOT IN MSD401 TABLE - USE MSD405CareActivityBaby_1
    -- baby.Apgar_Score_At_10_Minutes,  -- NOT IN MSD401 TABLE

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
    -- labour.Maternity_Care_Setting_Actual_Place_Birth,  -- NOTE: SettingPlaceBirth is in Baby table (MSD401), not Labour table
    labour.Procedure_Date_Caesarean_Section,
    labour.Mother_Admission_Date,
    labour.Mother_Discharge_Date,

    -- === MATERNAL DEMOGRAPHICS (FOR INEQUALITIES ANALYSIS) ===
    -- mother.Person_Birth_Date_Mother,  -- NOT IN TABLE - need to derive from age if needed
    -- DATEDIFF(year, mother.Person_Birth_Date_Mother, baby.Baby_Birth_Date) AS Mother_Age_At_Delivery,  -- Cannot calculate without birth date
    mother.Ethnic_Category_Mother,
    -- mother.Postcode_Usual_Address_Mother AS Mother_Postcode,  -- NOT IN TABLE - use PostcodeDistrictMother, LSOAMother2011 instead
    mother.Mother_CCG_Residence,

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
    -- NCC TIMING (from MSDS)
    -- ===================================================================
    msds_ncc.NCC_MSDS_First_Transfer_Date,
    msds_ncc.NCC_MSDS_First_Transfer_Time,

    -- Hours from birth to NCC admission (MSDS)
    CASE
      WHEN msds_ncc.NCC_MSDS_Admitted = 1 THEN
        DATEDIFF(
          hour,
          DATEADD(second,
                  ISNULL(CAST(DATEDIFF(second, '00:00:00', CAST(baby.Baby_Birth_Time AS TIME)) AS BIGINT), 0),
                  CAST(baby.Baby_Birth_Date AS DATETIME)),
          DATEADD(second,
                  ISNULL(CAST(DATEDIFF(second, '00:00:00', CAST(msds_ncc.NCC_MSDS_First_Transfer_Time AS TIME)) AS BIGINT), 0),
                  CAST(msds_ncc.NCC_MSDS_First_Transfer_Date AS DATETIME))
        )
      ELSE NULL
    END AS Hours_Birth_To_NCC_MSDS,

    -- ===================================================================
    -- NCC DETAILS (from PbR CC data)
    -- ===================================================================
    cc_ncc.NCC_CC_First_Admission_Date,
    cc_ncc.NCC_CC_First_Admission_Time,
    cc_ncc.NCC_CC_Last_Discharge_Date,

    -- Hours from birth to NCC admission (CC)
    CASE
      WHEN cc_ncc.NCC_CC_Admitted = 1 THEN
        DATEDIFF(
          hour,
          DATEADD(second,
                  ISNULL(CAST(DATEDIFF(second, '00:00:00', CAST(baby.Baby_Birth_Time AS TIME)) AS BIGINT), 0),
                  CAST(baby.Baby_Birth_Date AS DATETIME)),
          DATEADD(second,
                  ISNULL(CAST(DATEDIFF(second, '00:00:00', CAST(cc_ncc.NCC_CC_First_Admission_Time AS TIME)) AS BIGINT), 0),
                  CAST(cc_ncc.NCC_CC_First_Admission_Date AS DATETIME))
        )
      ELSE NULL
    END AS Hours_Birth_To_NCC_CC,

    -- Length of stay
    cc_ncc.NCC_CC_Total_Days,
    cc_ncc.NCC_CC_Number_Of_Periods,

    -- Clinical details from CC
    cc_ncc.NCC_CC_Gestation_Weeks,
    cc_ncc.NCC_CC_Birth_Weight_Grams,

    -- Severity indicators (organ support) - COMMENTED OUT: column names not found
    -- cc_ncc.NCC_CC_Adv_Resp_Days,
    -- cc_ncc.NCC_CC_Basic_Resp_Days,
    -- cc_ncc.NCC_CC_Adv_CV_Days,
    -- cc_ncc.NCC_CC_Basic_CV_Days,
    -- cc_ncc.NCC_CC_Renal_Days,
    -- cc_ncc.NCC_CC_Neuro_Days,
    -- cc_ncc.NCC_CC_Gastro_Days,
    -- cc_ncc.NCC_CC_Max_Organs_Supported,

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
    cc_ncc.NCC_CC_Provider_Code AS NCC_Hospital_Provider_Code

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

  -- Link to MSDS neonatal admission
  LEFT JOIN msds_neonatal_adm msds_ncc
    ON baby.Person_ID_Baby = msds_ncc.Person_ID_Baby

  -- Link to CC NCC data via NHS Number
  LEFT JOIN ncc_cc_with_nhs cc_ncc
    ON baby.NHS_Number_Baby = cc_ncc.NCC_CC_NHS_Number
    AND ABS(DATEDIFF(day, baby.Baby_Birth_Date, cc_ncc.NCC_CC_First_Activity_Date)) <= 90

  -- Filter: Only babies with a hospital admission/spell
  WHERE labour.Mother_Admission_Date IS NOT NULL
)

-- ========================================================================
-- FINAL OUTPUT
-- ========================================================================
SELECT * FROM base_dataset
WHERE Baby_Birth_Financial_Year = '2023/24'
ORDER BY
  Baby_Birth_Date,
  NHS_Number_Baby;

/*
============================================================================
NOTES:
============================================================================
1. DEDUPLICATION (CRITICAL):
   All MSDS tables have significant duplication due to multiple submissions:
   - MSD401 (Baby Demographics): ~3.4 records per baby
   - MSD301 (Labour/Delivery): ~3.6 records per LabourDeliveryID
   - MSD101 (Pregnancy/Booking): ~10 records per UniqPregID
   - MSD402 (Neonatal Admissions): ~2.1 records per baby
   - MSD001 (Mother Demographics): duplicates per Person_ID_Mother

   Analysis showed 99%+ of duplicates have identical clinical data, differing
   only in submission metadata (UniqSubmissionID, AuditId, RecordNumber).

   Deduplication strategy: ROW_NUMBER() partitioned by natural key, ordered by
   UniqSubmissionID DESC (most recent submission), then filter WHERE rn = 1.

   WITHOUT deduplication, the final dataset would have ~3-4x the expected
   number of births (should be ~540k babies, would be ~1.8M records).

2. NCC admission status comes from TWO sources for comparison:
   - NCC_MSDS_Admitted: From MSD402_NeonatalAdmission_1
   - NCC_CC_Admitted: From Pbr_CC_Monthly (CC_Type='NCC')
   - NCC_Admitted: Combined flag (1 if in EITHER source)

3. NCC_In_Both_Sources checks data consistency:
   - 1 = In both MSDS and CC data (good data quality)
   - 0 = In only one source (investigate discrepancies)
   - NULL = Not admitted to NCC

4. Timing uses MSDS transfer date (more reliable for first admission)
   CC dates available for comparison

5. Severity/organ support only available from CC data

6. For hierarchical model:
   - Fixed effects: Birth weight, gestation, Apgar scores, maternal age,
                    ethnicity, deprivation (needs IMD lookup on postcode)
   - Random effects: NCC_Hospital_Provider_Code, Delivery_Site_Code,
                     Org_ID_Commissioner
============================================================================
*/
