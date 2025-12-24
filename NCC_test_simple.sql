-- Progressive test to isolate the overflow error
-- Test 1: ncc_from_cc with all aggregations

WITH ncc_from_cc AS (
  SELECT
    cc.APCS_Ident,
    1 AS NCC_CC_Admitted,
    MIN(cc.CC_Start_Date) AS NCC_CC_First_Admission_Date,
    COUNT(*) AS NCC_CC_Total_Days,

    -- Test the SUM operations that might overflow
    SUM(CAST(ISNULL(cc.Advanced_Resp_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Adv_Resp_Days,
    SUM(CAST(ISNULL(cc.Basic_Resp_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Basic_Resp_Days,
    SUM(CAST(ISNULL(cc.Advanced_Cardiovasc_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Adv_CV_Days,
    SUM(CAST(ISNULL(cc.Basic_Cardiovasc_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Basic_CV_Days,
    SUM(CAST(ISNULL(cc.Renal_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Renal_Days,
    SUM(CAST(ISNULL(cc.Neurological_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Neuro_Days,
    SUM(CAST(ISNULL(cc.Gastro_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Gastro_Days,
    SUM(CAST(ISNULL(cc.Dermatological_Supp_Days, 0) AS BIGINT)) AS NCC_CC_Derm_Days,
    SUM(CAST(ISNULL(cc.Liver_Supp_days, 0) AS BIGINT)) AS NCC_CC_Liver_Days,
    SUM(CAST(ISNULL(cc.CC_Level2_days, 0) AS BIGINT)) AS NCC_CC_Level2_Days,
    SUM(CAST(ISNULL(cc.CC_Level3_Days, 0) AS BIGINT)) AS NCC_CC_Level3_Days

  FROM UDAL_Warehouse.MESH_APC.Pbr_CC_Monthly cc
  WHERE cc.CC_Type = 'NCC'
    AND cc.Der_Financial_Year = '2023/24'
  GROUP BY cc.APCS_Ident
)
SELECT COUNT(*) as record_count FROM ncc_from_cc;
