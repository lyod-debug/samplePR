/* =====================================================================================
   08_validation_queries_payments_motor.sql   (ONE file for all validation and data check queries; typelist queries are in file 14)
   READ-ONLY queries. Run them one by one (select the block of one query and run it). Not executed on SQL Server by me.
   (Oct 15) Queries that read ExceptionCode / WarnList / DissSum / IS_PAYMENT_EXCEPTION_MOTOR need the TEST proc
            (usp_Load_IS_PAYMENT_MASTER_MOTOR_TEST, dev only) AND the dev-only columns from 00_DDL_payment_tables_motor_TEST_addon.sql.
            The PROD table does NOT have ExceptionCode, WarnList, DissSum, MasterCountInTran, so these queries fail on a PROD-only table.
            TEST ONLY queries: Q12, Q21, Q22, Q42, the HDR credit query after Q36 area (reads ExceptionCode), V8, AD5. All other queries work with both.
   (Oct 15) New queries AD1 to AD7 at the end of PART 2: AD payments and AD recoveries of claims without AD exposure moved to claim level.
   PART 1 = data checks Q1 to Q46 (old file 09). Most can run BEFORE the payment procs (they read Vectus data).
            Marked "After running proc" = run them AFTER usp_Load_IS_PAYMENT_MASTER_MOTOR (Q21, Q22, Q36, Q42, Q44, Q46).
            PART 1 starts with a temp table #PT: run that first statement in the same session as the queries that use it.
   PART 2 = validation V1 to V9c, V2e, V10, V10b (V10 and V10b need the five main procs). Run AFTER all payment procs and the dummy payee procs (see 00_RUN_ORDER_with_EXEC_commands.sql).
            V1, V3 and the dummy payee checks V2b and V2e must return ZERO rows.
            V2 lists foreign keys that point nowhere: such rows are EXPECTED while a reserve line, recovery coding, payee or claim contact
            is missing. Match each row with its ExceptionCode in IS_PAYMENT_EXCEPTION_MOTOR (TEST proc only). Queries marked "report" are information.
   The MAIN queries to run are listed in 24_FINAL_TODO_open_questions_and_checks.md.
   ===================================================================================== */
USE [IntermediateStaging_DEV];

/* ################################ PART 1: DATA CHECKS (Q1 - Q46) ################################ */
/* -------------------------------------------------------------------------------------
   A. A reusable view of "Motor payments with their case type" (temp table for this session)
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#PT') IS NOT NULL DROP TABLE #PT;
SELECT PT.ID AS TranID, PT.CASEID, CLM.GW_HDR_CASEID, CLM.CLAIM_REF, UPPER(LTRIM(RTRIM(PT.DEBIT_CREDIT))) AS DC
     , PT.AMOUNT, LTRIM(RTRIM(PT.PAY_TYPE)) AS PAY_TYPE, PT.PAYEE_LINKID, PT.ADD_LINKID, PT.PAYEE_NAME
     , PT.ADDRESS_LINE1, PT.ADDRESS_LINE2, PT.ADDRESS_LINE3, PT.POST_CODE
     , CASE WHEN PT.CASEID = CLM.GW_HDR_CASEID THEN 'HDR'
            WHEN AD.ID IS NOT NULL THEN 'AD'
            WHEN TP.ID IS NOT NULL THEN 'TP'
            WHEN PA.ID IS NOT NULL THEN 'PA'
            ELSE 'UNKNOWN' END AS CaseType
INTO #PT
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD ON AD.ID = PT.CASEID AND AD.GW_HDR_CASEID = CLM.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP ON TP.ID = PT.CASEID AND TP.GW_HDR_CASEID = CLM.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY PA ON PA.ID = PT.CASEID AND PA.GW_HDR_CASEID = CLM.GW_HDR_CASEID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR';
CREATE UNIQUE CLUSTERED INDEX IX_PT ON #PT (TranID);

/* Q1. How many motor payments / recoveries per case type (the size of each edge case) */
SELECT CaseType, DC, COUNT(*) AS Trans, SUM(AMOUNT) AS Amount
FROM #PT GROUP BY CaseType, DC ORDER BY CaseType, DC;
/* UNKNOWN must be 0. If not: the payment's CASEID is not the claim, nor an AD / TP / PA case of that claim. */

/* Q2. Transactions with NO dissection row at all (my assumption: use the header amount)  -> BA question 6 */
SELECT P.CaseType, P.DC, COUNT(*) AS Trans, SUM(P.AMOUNT) AS Amount, MIN(P.TranID) AS ExampleTranID
FROM #PT P
WHERE NOT EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_PAY_DISS D WHERE D.GW_PAY_TRAN_ID = P.TranID)
GROUP BY P.CaseType, P.DC;

/* Q3. Dissection rows with a NULL / blank CODE (BA: map as claimcost) */
SELECT P.CaseType, P.DC, COUNT(*) AS DissRows, MIN(P.TranID) AS ExampleTranID
FROM #PT P INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D ON D.GW_PAY_TRAN_ID = P.TranID
WHERE D.CODE IS NULL OR LTRIM(RTRIM(D.CODE)) = ''
GROUP BY P.CaseType, P.DC;

/* Q4. Header amount different from the sum of the dissections */
SELECT TOP 20 P.TranID, P.DC, P.AMOUNT AS HeaderAmount, S.DissSum
FROM #PT P INNER JOIN (SELECT GW_PAY_TRAN_ID, SUM(AMOUNT) AS DissSum FROM SourceStaging.VECCASRN.VEC_GW_PAY_DISS GROUP BY GW_PAY_TRAN_ID) S
     ON S.GW_PAY_TRAN_ID = P.TranID
WHERE ABS(ISNULL(P.AMOUNT,0) - S.DissSum) > 0.005
ORDER BY P.TranID;

/* Q5. Debit dissection codes that have NO row in the lookup for that kind of case (these become UNMAPPED_DISS_CODE) -> BA question 7 */
;WITH K AS
(
  SELECT CASE WHEN K.DISSECTION_CODE IS NULL OR UPPER(LTRIM(RTRIM(K.DISSECTION_CODE))) IN ('','NULL','<NULL>') THEN '~NULL~' ELSE UPPER(LTRIM(RTRIM(K.DISSECTION_CODE))) END AS CodeKey
       , CASE WHEN UPPER(REPLACE(LTRIM(RTRIM(K.V2_CASE)),' ','_')) = 'GW_MOTOR_TP' THEN 'TP'
              WHEN UPPER(REPLACE(LTRIM(RTRIM(K.V2_CASE)),' ','_')) LIKE 'ALL_CASES_APART%' THEN 'NONTP' ELSE 'ALL' END AS VScope
  FROM SourceStaging.dbo.Lkp_Transaction_Typelist K
  WHERE LOWER(LTRIM(RTRIM(K.LOB))) = 'motor' AND UPPER(LTRIM(RTRIM(K.DEBIT_CREDIT))) = 'D'
)
SELECT P.CaseType, UPPER(LTRIM(RTRIM(D.CODE))) AS DissCode, COUNT(*) AS DissRows, MIN(P.TranID) AS ExampleTranID
FROM #PT P INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D ON D.GW_PAY_TRAN_ID = P.TranID
WHERE P.DC = 'D' AND D.CODE IS NOT NULL AND LTRIM(RTRIM(D.CODE)) <> ''
  AND NOT EXISTS (SELECT 1 FROM K WHERE K.CodeKey = UPPER(LTRIM(RTRIM(D.CODE)))
                  AND (K.VScope = 'ALL' OR (K.VScope = 'TP' AND P.CaseType = 'TP') OR (K.VScope = 'NONTP' AND P.CaseType <> 'TP')))
GROUP BY P.CaseType, UPPER(LTRIM(RTRIM(D.CODE)))
ORDER BY COUNT(*) DESC;

/* Q6. Lookup rows that contradict each other (same code + same scope, different cost type). My proc would silently take the alphabetically first. */
SELECT UPPER(LTRIM(RTRIM(DISSECTION_CODE))) AS Code, LTRIM(RTRIM(V2_CASE)) AS V2_CASE, COUNT(DISTINCT LOWER(LTRIM(RTRIM(CostTypeCode)))) AS CostTypes, COUNT(*) AS Rws
FROM SourceStaging.dbo.Lkp_Transaction_Typelist
WHERE LOWER(LTRIM(RTRIM(LOB))) = 'motor' AND UPPER(LTRIM(RTRIM(DEBIT_CREDIT))) = 'D'
GROUP BY UPPER(LTRIM(RTRIM(DISSECTION_CODE))), LTRIM(RTRIM(V2_CASE))
HAVING COUNT(*) > 1;

/* Q7. Split transactions: debit transactions whose dissections map to BOTH claimcost and aoexpense (how many 2-for-1 splits) */
;WITH K AS
(
  SELECT CASE WHEN K.DISSECTION_CODE IS NULL OR UPPER(LTRIM(RTRIM(K.DISSECTION_CODE))) IN ('','NULL','<NULL>') THEN '~NULL~' ELSE UPPER(LTRIM(RTRIM(K.DISSECTION_CODE))) END AS CodeKey
       , CASE WHEN UPPER(REPLACE(LTRIM(RTRIM(K.V2_CASE)),' ','_')) = 'GW_MOTOR_TP' THEN 'TP'
              WHEN UPPER(REPLACE(LTRIM(RTRIM(K.V2_CASE)),' ','_')) LIKE 'ALL_CASES_APART%' THEN 'NONTP' ELSE 'ALL' END AS VScope
       , LOWER(LTRIM(RTRIM(K.CostTypeCode))) AS CostType
       , CASE WHEN UPPER(LTRIM(RTRIM(K.Exposure))) LIKE 'HIRE%' THEN 1 ELSE 0 END AS IsHire
  FROM SourceStaging.dbo.Lkp_Transaction_Typelist K
  WHERE LOWER(LTRIM(RTRIM(K.LOB))) = 'motor' AND UPPER(LTRIM(RTRIM(K.DEBIT_CREDIT))) = 'D'
),
L AS
(
  SELECT P.TranID, P.CaseType, K.CostType, K.IsHire
  FROM #PT P
  INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D ON D.GW_PAY_TRAN_ID = P.TranID
  INNER JOIN K ON K.CodeKey = CASE WHEN D.CODE IS NULL OR UPPER(LTRIM(RTRIM(D.CODE))) IN ('','NULL','<NULL>') THEN '~NULL~' ELSE UPPER(LTRIM(RTRIM(D.CODE))) END
             AND (K.VScope = 'ALL' OR (K.VScope = 'TP' AND P.CaseType = 'TP') OR (K.VScope = 'NONTP' AND P.CaseType <> 'TP'))
  WHERE P.DC = 'D'
)
SELECT CaseType
     , COUNT(*) AS DebitTrans
     , SUM(CASE WHEN Kinds > 1 THEN 1 ELSE 0 END) AS TransThatSplit
     , MIN(CASE WHEN Kinds > 1 THEN TranID END) AS ExampleSplitTranID
FROM (SELECT TranID, CaseType, COUNT(DISTINCT CONCAT(CostType,'|',IsHire)) AS Kinds FROM L GROUP BY TranID, CaseType) X
GROUP BY CaseType;

/* Q8. Hire & Mobility codes MIXED with normal codes in one TP debit transaction (they go to two different exposures) -> BA question 5 */
SELECT TOP 20 P.TranID, P.CLAIM_REF, P.CASEID,
       SUM(CASE WHEN D.CODE IN ('ABA','ABH','ABP','CDW','FSC','OUH','PLH','PLP','RVM','SUB','TEM','TPH') THEN 1 ELSE 0 END) AS HireCodes,
       SUM(CASE WHEN D.CODE IN ('ABA','ABH','ABP','CDW','FSC','OUH','PLH','PLP','RVM','SUB','TEM','TPH') THEN 0 ELSE 1 END) AS OtherCodes
FROM #PT P INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D ON D.GW_PAY_TRAN_ID = P.TranID
WHERE P.CaseType = 'TP' AND P.DC = 'D'
GROUP BY P.TranID, P.CLAIM_REF, P.CASEID
HAVING SUM(CASE WHEN D.CODE IN ('ABA','ABH','ABP','CDW','FSC','OUH','PLH','PLP','RVM','SUB','TEM','TPH') THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN D.CODE IN ('ABA','ABH','ABP','CDW','FSC','OUH','PLH','PLP','RVM','SUB','TEM','TPH') THEN 0 ELSE 1 END) > 0;

/* Q9. TP cases that have vehicle AND injury AND property exposures (mapping does not list VEH/INJ/PRO; I assume vehicle) -> BA question 13 */
SELECT E.GW_HDR_CASEID, E.VectusCaseID_Adm
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
WHERE E.SourceOrigin_Adm IN ('TP_VEH','TP_INJ','TP_PRO')
GROUP BY E.GW_HDR_CASEID, E.VectusCaseID_Adm
HAVING COUNT(DISTINCT E.SourceOrigin_Adm) = 3;

/* Q10. AD: claims with more than one AD case; AD payments whose own case has no exposure -> remapped to the surviving AD (mapping row 136 edge case) */
SELECT AD.GW_HDR_CASEID, COUNT(*) AS AdCases, SUM(CASE WHEN EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm='AD' AND E.VectusCaseID_Adm = CONVERT(VARCHAR(64),AD.ID)) THEN 1 ELSE 0 END) AS AdWithExposure
FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD
WHERE EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER C WHERE C.GW_HDR_CASEID = AD.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR')
GROUP BY AD.GW_HDR_CASEID HAVING COUNT(*) > 1;

SELECT P.DC, COUNT(*) AS Trans, MIN(P.TranID) AS ExampleTranID
FROM #PT P
WHERE P.CaseType = 'AD'
  AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm='AD' AND E.VectusCaseID_Adm = CONVERT(VARCHAR(64),P.CASEID))
GROUP BY P.DC;

/* Q11. Credits (recoveries) per case type, and how many have a recovery reserve line available -> BA question 1 (need confirmation from BA) */
SELECT P.CaseType, COUNT(*) AS Credits, SUM(P.AMOUNT) AS Amount, MIN(P.TranID) AS ExampleTranID
FROM #PT P WHERE P.DC = 'C' GROUP BY P.CaseType;

/* Q11b. AD credits whose AD case (or the surviving AD case) has no recovery reserve line '_rec' */
SELECT P.TranID, P.CLAIM_REF, P.CASEID
FROM #PT P
WHERE P.DC = 'C' AND P.CaseType = 'AD'
  AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_RESERVELINE_MOTOR R
                  WHERE R.GW_HDR_CASEID = P.GW_HDR_CASEID AND R.SourceOrigin_Adm = 'AD' AND RIGHT(R.PublicID,4) = '_rec');

/* Q11c. Claim-level credits (CASEID = claim): claims that need the claim-level 'pm_other_adm' recovery line (lookup row 4). AD credits moved to claim level are counted in AD1 (file 25 PART 2 covers both). */
SELECT P.GW_HDR_CASEID, P.CLAIM_REF, COUNT(*) AS Credits, SUM(P.AMOUNT) AS Amount, MIN(P.TranID) AS ExampleTranID
FROM #PT P WHERE P.DC = 'C' AND P.CaseType = 'HDR'
GROUP BY P.GW_HDR_CASEID, P.CLAIM_REF ORDER BY COUNT(*) DESC;

/* TEST ONLY (reads ExceptionCode). Q12. Injury: debit expense payments that land on a TP injury exposure which has no 'Third Party Solicitors Costs' line  -> BA question 3
        (run AFTER proc 01: this is the NO_MAIN_INJ_CLAIMCOST_LINE / NO_MAIN_INJ_EXPENSE_LINE list) */
SELECT TOP 50 TranID, MasterSuffix, GW_HDR_CASEID, CLAIM_REF, CaseID, CostType, MasterAmount, CASE_STATUS
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
WHERE ExceptionCode IN ('NO_MAIN_INJ_CLAIMCOST_LINE','NO_MAIN_INJ_EXPENSE_LINE');

/* Q13. Statuses: V2 STATUS_TYPE values in use, and whether the typelist knows them */
SELECT S.STATUS_TYPE, S.GCURRENT, COUNT(*) AS Rws
FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S
INNER JOIN #PT P ON P.TranID = S.GW_PAY_TRAN_ID
GROUP BY S.STATUS_TYPE, S.GCURRENT ORDER BY S.GCURRENT DESC, COUNT(*) DESC;

/* Q13b. The 5 typelists I read, exactly as stored  -> need confirmation from BA (how were LifeCycleState / ApprovalStatus keyed?) */
SELECT TypeList_Name, Vectus_TypeCode, GW_TypeCode, [Household/Motor/Both]
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name IN ('TransactionStatus','TransactionLifeCycleState','ApprovalStatus','CheckStatus','PaymentMethod','ReasonToStopCheque_Adm')
ORDER BY TypeList_Name, Vectus_TypeCode;

/* Q14. Transactions with no GCURRENT='X' status, or more than one */
SELECT P.CaseType, X.CurrentRows, COUNT(*) AS Trans, MIN(P.TranID) AS ExampleTranID
FROM #PT P
CROSS APPLY (SELECT COUNT(*) AS CurrentRows FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S WHERE S.GW_PAY_TRAN_ID = P.TranID AND S.GCURRENT = 'X') X
WHERE X.CurrentRows <> 1
GROUP BY P.CaseType, X.CurrentRows;

/* Q15. More than one PAID / PRESENTED / CANX / AUTH / GRP_AUTH record per transaction (BA only decided AUTH / GRP_AUTH = latest) -> BA question 10 */
SELECT S.STATUS_TYPE, COUNT(*) AS TransWithMoreThanOne, MIN(S.GW_PAY_TRAN_ID) AS ExampleTranID
FROM (SELECT GW_PAY_TRAN_ID, STATUS_TYPE FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS
      WHERE STATUS_TYPE IN ('PAID','PRESENTED','CANX','AUTH','GRP_AUTH') GROUP BY GW_PAY_TRAN_ID, STATUS_TYPE HAVING COUNT(*) > 1) S
GROUP BY S.STATUS_TYPE;

/* Q16. Cheque stop reasons: CANX reasons that are not in the typelist (they become issued_in_error - BA rule) */
SELECT TOP 30 LTRIM(RTRIM(S.REASON)) AS V2Reason, COUNT(*) AS Rws
FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S
INNER JOIN #PT P ON P.TranID = S.GW_PAY_TRAN_ID
WHERE S.STATUS_TYPE = 'CANX'
  AND NOT EXISTS (SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING T WHERE LTRIM(RTRIM(T.TypeList_Name)) = 'ReasonToStopCheque_Adm' AND LTRIM(RTRIM(T.Vectus_TypeCode)) = LTRIM(RTRIM(S.REASON)))
GROUP BY LTRIM(RTRIM(S.REASON)) ORDER BY COUNT(*) DESC;

/* Q17. Payee of every DEBIT, resolved the way proc 01 (S10) does it:
        PAYEE_LINKID -> VEC_GW_CF_LINK.ID -> GWCF_HDRID (contact record) -> CONTACT_MASTER_MOTOR.HDR_ID (same claim) -> IS_CLAIMCONTACT
        Supports BA question 11 (what to do with categories 3, 4, 5) and the open contact master / claim contact items.
        Categories 1 to 6 all get a dummy payee (user decision Oct 15): a payee is never empty. */
IF OBJECT_ID('tempdb..#PAYRES') IS NOT NULL DROP TABLE #PAYRES;
SELECT P.TranID, P.GW_HDR_CASEID, P.CLAIM_REF, P.PAYEE_LINKID, L.GWCF_HDRID AS HdrID
     , CASE WHEN P.PAYEE_LINKID IS NULL OR ISNULL(TRY_CONVERT(BIGINT, P.PAYEE_LINKID), 0) = 0 THEN '1 no link (NULL / 0 / not a number)'
            WHEN L.ID IS NULL THEN '2 link not in VEC_GW_CF_LINK'
            WHEN L.GWCF_HDRID IS NULL THEN '3 link has no GWCF_HDRID'
            WHEN NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM WHERE CM.HDR_ID = L.GWCF_HDRID) THEN '4 contact record not in CONTACT_MASTER_MOTOR at all'
            WHEN NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM WHERE CM.HDR_ID = L.GWCF_HDRID AND CM.GW_HDR_CASEID = P.GW_HDR_CASEID) THEN '5 contact record only on ANOTHER claim'
            WHEN NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM
                             INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = CM.GW_HDR_CASEID
                             INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC ON CC.ContactID = CM.PublicID AND CC.ClaimID = CLM.PUBLICID
                             WHERE CM.HDR_ID = L.GWCF_HDRID AND CM.GW_HDR_CASEID = P.GW_HDR_CASEID) THEN '6 contact found but no IS_CLAIMCONTACT row'
            ELSE '7 OK' END AS PayeeCase
INTO #PAYRES
FROM #PT P
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK L ON L.ID = TRY_CONVERT(BIGINT, P.PAYEE_LINKID) AND ISNULL(TRY_CONVERT(BIGINT, P.PAYEE_LINKID), 0) <> 0
WHERE P.DC = 'D';
SELECT PayeeCase, COUNT(*) AS Trans, MIN(TranID) AS ExampleTranID, MIN(CLAIM_REF) AS ExampleClaim FROM #PAYRES GROUP BY PayeeCase ORDER BY 1;

/* Q17b. Category 4: which CONTACT RECORDs (HDR_ID) are missing from the contact master, and why
         (contact master drops a record whose kept link has no row in GWCC_CONTACT_SUBTYPE_MOTOR -> "WHERE EL.Subtype IS NOT NULL") */
SELECT TOP (50) R.HdrID, H.GWCONTH_TYPEID AS HDR_TYPE_ID, HT.HDR_TYPE, HT.PRODUCT AS HDR_TYPE_PRODUCT, COUNT(*) AS Trans, MIN(R.CLAIM_REF) AS ExampleClaim
FROM #PAYRES R
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR H ON H.ID = R.HdrID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HT ON HT.ID = H.GWCONTH_TYPEID
WHERE R.PayeeCase LIKE '4%'
GROUP BY R.HdrID, H.GWCONTH_TYPEID, HT.HDR_TYPE, HT.PRODUCT ORDER BY COUNT(*) DESC;
/* contact master only reads contact record types whose PRODUCT = MOTOR (line 62 of usp_Load_IS_CONTACT_MASTER_MOTOR). If HDR_TYPE_PRODUCT is not MOTOR, that is the reason. */

/* Q17c. Dummy payees (categories 1 and 2): does PAYEE_NAME have text? (blank name = DUMMY_PAYEE_NO_NAME error) and is there an address? */
SELECT R.PayeeCase
     , SUM(CASE WHEN NULLIF(LTRIM(RTRIM(P.PAYEE_NAME)), '') IS NULL THEN 1 ELSE 0 END) AS NoName
     , SUM(CASE WHEN LEN(LTRIM(RTRIM(P.PAYEE_NAME))) > 60 THEN 1 ELSE 0 END) AS NameLongerThan60
     , SUM(CASE WHEN COALESCE(NULLIF(LTRIM(RTRIM(P.ADDRESS_LINE1)),''), NULLIF(LTRIM(RTRIM(P.ADDRESS_LINE2)),''), NULLIF(LTRIM(RTRIM(P.ADDRESS_LINE3)),''), NULLIF(LTRIM(RTRIM(P.POST_CODE)),'')) IS NOT NULL THEN 1 ELSE 0 END) AS WithAddress
     , SUM(CASE WHEN LEN(P.ADDRESS_LINE1) > 60 OR LEN(P.ADDRESS_LINE2) > 60 OR LEN(P.ADDRESS_LINE3) > 60 THEN 1 ELSE 0 END) AS AddressLineLongerThan60
     , COUNT(*) AS Trans
FROM #PAYRES R INNER JOIN #PT P ON P.TranID = R.TranID
WHERE R.PayeeCase LIKE '1%' OR R.PayeeCase LIKE '2%'
GROUP BY R.PayeeCase;

/* Q17d. Real payees: person or company? (decides PayTo, BA question 27). Subtype comes from the contact master. */
SELECT CM.Subtype, COUNT(*) AS Trans
FROM #PAYRES R
INNER JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.HDR_ID = R.HdrID AND CM.GW_HDR_CASEID = R.GW_HDR_CASEID
WHERE R.PayeeCase LIKE '7%'
GROUP BY CM.Subtype ORDER BY COUNT(*) DESC;

/* Q17e. Transfer payments (PAY_TYPE = T): which payee category do they fall in? (PAYEE_NAME holds a claim number there) -> BA question 4 / 27 */
SELECT R.PayeeCase, COUNT(*) AS Trans, MIN(P.PAYEE_NAME) AS ExamplePayeeName
FROM #PAYRES R INNER JOIN #PT P ON P.TranID = R.TranID
WHERE P.PAY_TYPE = 'T'
GROUP BY R.PayeeCase ORDER BY 1;

/* Q17f. In-care-of (ADD_LINKID) of debits: found / not found, and does the in-care-of contact have a primary address row?  -> BA question 29 */
IF OBJECT_ID('tempdb..#ICRES') IS NOT NULL DROP TABLE #ICRES;
SELECT P.TranID, P.GW_HDR_CASEID, P.CLAIM_REF, L.GWCF_HDRID AS HdrID
     , CASE WHEN P.ADD_LINKID IS NULL OR ISNULL(TRY_CONVERT(BIGINT, P.ADD_LINKID), 0) = 0 THEN '1 no in-care-of'
            WHEN L.ID IS NULL THEN '2 ADD_LINKID not in VEC_GW_CF_LINK'
            WHEN NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM WHERE CM.HDR_ID = L.GWCF_HDRID AND CM.GW_HDR_CASEID = P.GW_HDR_CASEID) THEN '3 contact record not in contact master of THIS claim'
            WHEN NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM
                             INNER JOIN IntermediateStaging_DEV.dbo.IS_ADDRESS_CONTACT A ON A.CONTACT_ADDRESS_PUBLICID = CM.PrimaryAddressID
                             WHERE CM.HDR_ID = L.GWCF_HDRID AND CM.GW_HDR_CASEID = P.GW_HDR_CASEID) THEN '4 contact found but NO address row for its PrimaryAddressID'
            ELSE '5 OK (contact + address)' END AS InCareOfCase
INTO #ICRES
FROM #PT P
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK L ON L.ID = TRY_CONVERT(BIGINT, P.ADD_LINKID) AND ISNULL(TRY_CONVERT(BIGINT, P.ADD_LINKID), 0) <> 0
WHERE P.DC = 'D';
SELECT InCareOfCase, COUNT(*) AS Trans, MIN(TranID) AS ExampleTranID, MIN(CLAIM_REF) AS ExampleClaim FROM #ICRES GROUP BY InCareOfCase ORDER BY 1;

/* Q17g. Is the in-care-of contact the same person as the payee? (the BA SQL has "where cc.ClaimContactID <> cc.InCareOf_Adm") */
SELECT COUNT(*) AS InCareOfSameRecordAsPayee
FROM #PAYRES R INNER JOIN #ICRES I ON I.TranID = R.TranID
WHERE I.HdrID IS NOT NULL AND I.HdrID = R.HdrID;

/* Q17h. Contact records whose PrimaryAddressID has no address row: the check would get MailingAddressID NULL / the contact an address that does not exist
         (this is a contact / address proc question: need confirmation from BA) */
SELECT TOP (50) CM.HDR_ID, CM.PublicID, CM.PrimaryAddressID, CM.CLAIM_REF
FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM
WHERE CM.PrimaryAddressID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_ADDRESS_CONTACT A WHERE A.CONTACT_ADDRESS_PUBLICID = CM.PrimaryAddressID);
SELECT COUNT(*) AS ContactsWithPrimaryAddressIdButNoAddressRow
FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM
WHERE CM.PrimaryAddressID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_ADDRESS_CONTACT A WHERE A.CONTACT_ADDRESS_PUBLICID = CM.PrimaryAddressID);

/* Q17i. Claim contacts: payee contacts that are Company-type subtypes WITHOUT ContactNameDenorm, or Person-type without first/last name (PayTo source) */
SELECT CC.ContactID, CC.PublicID, CC.ContactNameDenorm, CC.PersonFirstNameDenorm, CC.PersonLastNameDenorm
FROM IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC
WHERE CC.PublicID IN (SELECT TOP (20) CC2.PublicID FROM IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC2
                      WHERE CC2.ContactNameDenorm IS NULL AND CC2.PersonFirstNameDenorm IS NULL AND CC2.PersonLastNameDenorm IS NULL);
SELECT COUNT(*) AS ClaimContactsWithNoNameAtAll
FROM IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC2
WHERE CC2.ContactNameDenorm IS NULL AND CC2.PersonFirstNameDenorm IS NULL AND CC2.PersonLastNameDenorm IS NULL;

/* Q18. Gateway table: one row per ID? (a duplicate would duplicate payments) */
SELECT ID, COUNT(*) AS Cnt FROM SourceStaging.VECCASRN.VEC_GW_PAY_GATEWAY GROUP BY ID HAVING COUNT(*) > 1;

/* Q19. Transfer payments (PAY_TYPE = T): both sides, and what PAYEE_NAME holds on the debit  -> BA question 4 */
SELECT P.DC, P.CaseType, COUNT(*) AS Trans, MIN(P.TranID) AS ExampleTranID, MIN(P.PAYEE_NAME) AS ExamplePayeeName
FROM #PT P WHERE P.PAY_TYPE = 'T' GROUP BY P.DC, P.CaseType;

/* Q20. Field sizes: values longer than the ClaimCenter column sizes in the mapping sheet (AccountName 50, account 10, sort code 8, cash move 10, cheque no 10) */
SELECT SUM(CASE WHEN LEN(PT.PAYEE_NAME) > 50 THEN 1 ELSE 0 END)     AS PayeeName_gt50
     , SUM(CASE WHEN LEN(PT.ACCOUNT_NUMBER) > 10 THEN 1 ELSE 0 END) AS AccountNo_gt10
     , SUM(CASE WHEN LEN(PT.SORT_CODE) > 8 THEN 1 ELSE 0 END)       AS SortCode_gt8
     , SUM(CASE WHEN LEN(PT.CASH_MOVE_NO) > 10 THEN 1 ELSE 0 END)   AS CashMove_gt10
     , SUM(CASE WHEN LEN(PT.CHEQUE_NUMBER) > 10 THEN 1 ELSE 0 END)  AS ChequeNo_gt10
FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
INNER JOIN #PT P ON P.TranID = PT.ID;

/* TEST ONLY (reads ExceptionCode). Q21. After running proc 01: master rows by first problem found (ExceptionCode NULL = nothing found). All rows are copied except PA recoveries. */
SELECT ExceptionCode, CaseType, DebitCredit, COUNT(*) AS MasterRows, SUM(MasterAmount) AS Amount, MIN(TranID) AS ExampleTranID
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
GROUP BY ExceptionCode, CaseType, DebitCredit ORDER BY CASE WHEN ExceptionCode IS NULL THEN 1 ELSE 0 END, COUNT(*) DESC;

/* TEST ONLY (reads ExceptionCode). Q22. After running proc 01: V2 transactions split into several master rows where only SOME of them have a problem
         (e.g. the claim-cost part has a reserve line, the expense part has none). All rows are still copied; ClaimCenter will reject only the
         bad part. Show these to the BA (question 16). */
SELECT TranID, COUNT(*) AS MasterRows, SUM(CASE WHEN ExceptionCode IS NULL THEN 1 ELSE 0 END) AS RowsWithoutIssue, MIN(CLAIM_REF) AS CLAIM_REF
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
GROUP BY TranID HAVING SUM(CASE WHEN ExceptionCode IS NULL THEN 1 ELSE 0 END) BETWEEN 1 AND COUNT(*) - 1;


/* Q23. TRANS_REF is CHAR(16): how many references carry trailing blanks (BA question 23) */
SELECT COUNT(*) AS Rows_With_Padding, MIN(TRANS_REF) AS ExampleRef
FROM SourceStaging.VECCASRN.VEC_GW_PAY_GATEWAY
WHERE DATALENGTH(TRANS_REF) <> DATALENGTH(RTRIM(TRANS_REF)) OR LEN(TRANS_REF) < DATALENGTH(TRANS_REF);

/* Q24. CASH_MOVE_NO must become a number (ClaimCenter longint): values that are not numeric */
SELECT CASH_MOVE_NO, COUNT(*) AS Rows_
FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS
WHERE NULLIF(LTRIM(RTRIM(CASH_MOVE_NO)), '') IS NOT NULL AND TRY_CONVERT(BIGINT, LTRIM(RTRIM(CASH_MOVE_NO))) IS NULL
GROUP BY CASH_MOVE_NO ORDER BY COUNT(*) DESC;

/* Q25. DISS AMOUNT is DOUBLE: amounts with more than 2 decimals (they are rounded to pennies) */
SELECT TOP (100) D.*
FROM SourceStaging.VECCASRN.VEC_GW_PAY_DISS D
WHERE ABS(CONVERT(FLOAT, D.AMOUNT) * 100 - ROUND(CONVERT(FLOAT, D.AMOUNT) * 100, 0)) > 0.0001;


/* =====================================================================================
   NEW (11 Oct, after the Robo AI review). Each one answers a point that Robo raised or that I found when re-reading proc 01.
   ===================================================================================== */

/* Q26. Does VEC_GW_PAY_DISS have an ID column? (decides the line order; proc 01 S3 looks for it by itself and prints which order it used)
        -> Robo fix 2 (line order). Send me the column list. */
SELECT COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION
FROM SourceStaging.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'VECCASRN' AND TABLE_NAME = 'VEC_GW_PAY_DISS'
ORDER BY ORDINAL_POSITION;

/* Q27. Identical dissection rows inside one V2 transaction (same code AND same amount). These are the rows Robo is worried about.
        They are interchangeable: every loaded value is the same, only which one is called _1 and which _2 can change. */
SELECT D.GW_PAY_TRAN_ID, UPPER(LTRIM(RTRIM(D.CODE))) AS DissCode, D.AMOUNT, COUNT(*) AS SameRows
FROM #PT P INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D ON D.GW_PAY_TRAN_ID = P.TranID
GROUP BY D.GW_PAY_TRAN_ID, UPPER(LTRIM(RTRIM(D.CODE))), D.AMOUNT
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC;

/* Q28. IN-FLIGHT payments: the BA said (BA session, day 2) that a claim with a payment in flight is held back by the CLAIM ELIGIBILITY work
        and that the payment mapping must not worry about it. This query shows whether any claim that IS in IS_CLAIM_MASTER still has such a payment.
        0 rows = claim eligibility already removed them. Rows = send them to the BA (they are claims the eligibility work should have held back).
        The list of in-flight statuses is Robo's (Confluence) and is NOT confirmed: AUTH, CANX_REC, GATEWAY, GRP_AUTH, PRINTED, REQ. */
SELECT P.GW_HDR_CASEID, P.CLAIM_REF, S.STATUS_TYPE, COUNT(*) AS Payments, MIN(P.TranID) AS ExampleTranID
FROM #PT P
INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S ON S.GW_PAY_TRAN_ID = P.TranID AND S.GCURRENT = 'X'
WHERE UPPER(LTRIM(RTRIM(S.STATUS_TYPE))) IN ('AUTH','CANX_REC','GATEWAY','GRP_AUTH','PRINTED','REQ')
GROUP BY P.GW_HDR_CASEID, P.CLAIM_REF, S.STATUS_TYPE
ORDER BY COUNT(*) DESC;

/* Q29. Debit codes on PA ancillary cases (Robo M11 says only P1B, P1E, P2B, P2E should appear there). The lookup says 'All' = any code goes to the PA exposure. */
SELECT UPPER(LTRIM(RTRIM(D.CODE))) AS DissCode, COUNT(*) AS DissRows, SUM(CONVERT(FLOAT, D.AMOUNT)) AS Amount
FROM #PT P INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D ON D.GW_PAY_TRAN_ID = P.TranID
WHERE P.CaseType = 'PA' AND P.DC = 'D'
GROUP BY UPPER(LTRIM(RTRIM(D.CODE))) ORDER BY COUNT(*) DESC;

/* Q30. Codes that the lookup knows ONLY for TP (CDW, FSC, RVM, SUB, TEM) but that appear on AD / HDR / PA cases, and the code SUC that the lookup
        knows only for NON-TP cases but that appears on a TP case. Since Oct 13 proc 01 S4 uses the TP row for the first five (normal payment, IsHire 0); SUC on a TP case still gets UNMAPPED_DISS_CODE. The BA said
        (BA session, hire section) that hire codes on other cases are normal payments on the exposure of that case. -> new BA question N-1 */
;WITH K AS
(
  SELECT UPPER(LTRIM(RTRIM(DISSECTION_CODE))) AS CodeKey
       , MAX(CASE WHEN UPPER(REPLACE(LTRIM(RTRIM(V2_CASE)),' ','_')) = 'GW_MOTOR_TP' THEN 1 ELSE 0 END) AS HasTpRow
       , MAX(CASE WHEN UPPER(REPLACE(LTRIM(RTRIM(V2_CASE)),' ','_')) LIKE 'ALL_CASES_APART%' THEN 1 ELSE 0 END) AS HasNonTpRow
       , MAX(CASE WHEN UPPER(LTRIM(RTRIM(V2_CASE))) = 'ALL' THEN 1 ELSE 0 END) AS HasAllRow
  FROM SourceStaging.dbo.Lkp_Transaction_Typelist
  WHERE LOWER(LTRIM(RTRIM(LOB))) = 'motor' AND UPPER(LTRIM(RTRIM(DEBIT_CREDIT))) = 'D'
  GROUP BY UPPER(LTRIM(RTRIM(DISSECTION_CODE)))
)
SELECT P.CaseType, K.CodeKey, K.HasTpRow, K.HasNonTpRow, K.HasAllRow, COUNT(*) AS DissRows, MIN(P.TranID) AS ExampleTranID
FROM #PT P
INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D ON D.GW_PAY_TRAN_ID = P.TranID
INNER JOIN K ON K.CodeKey = UPPER(LTRIM(RTRIM(D.CODE)))
WHERE P.DC = 'D' AND K.HasAllRow = 0
  AND ((P.CaseType = 'TP' AND K.HasTpRow = 0) OR (P.CaseType <> 'TP' AND K.HasNonTpRow = 0))
GROUP BY P.CaseType, K.CodeKey, K.HasTpRow, K.HasNonTpRow, K.HasAllRow
ORDER BY COUNT(*) DESC;

/* Q31. AD cases WITHOUT an AD exposure, with the reason. The exposure proc creates no AD exposure when the cover type is 'tpo', or 'tpft' without a theft
        circumstance (GW_CIRCS_TYPID = 5), or when the AD case was dropped by MOTOR_AD_DUPLICATE_LOOKUP, or when one of its inner joins finds nothing.
        Shows how many payments / recoveries sit on such AD cases. -> new BA question N-2 (Robo fix 4) */
SELECT AD.ID AS AD_ID, AD.GW_HDR_CASEID, RSK.COVER_TYPE, CIRC.GW_CIRCS_TYPID
     , SUM(CASE WHEN P.DC = 'D' THEN 1 ELSE 0 END) AS Debits, SUM(CASE WHEN P.DC = 'C' THEN 1 ELSE 0 END) AS Credits
     , CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.dbo.MOTOR_AD_DUPLICATE_LOOKUP DUPE WHERE DUPE.GW_MOTOR_AD_ID = AD.ID) THEN 'in duplicate lookup' ELSE '' END AS DupeLookup
FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD
INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = AD.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
LEFT JOIN #PT P ON P.CASEID = AD.ID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR ON SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CIRCS_INC CIRC ON CIRC.GW_HDR_CASEID = AD.GW_HDR_CASEID AND CIRC.GCURRENT = 'X'
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm = 'AD' AND E.VectusCaseID_Adm = CONVERT(VARCHAR(64), AD.ID))
GROUP BY AD.ID, AD.GW_HDR_CASEID, RSK.COVER_TYPE, CIRC.GW_CIRCS_TYPID
HAVING SUM(CASE WHEN P.TranID IS NOT NULL THEN 1 ELSE 0 END) > 0
ORDER BY COUNT(P.TranID) DESC;

/* Q32. PA ancillary cases WITHOUT a PA exposure (the exposure proc needs a PA coverage on the policy) and their payments. -> new BA question N-3 */
SELECT PA.ID AS PA_ID, PA.GW_HDR_CASEID
     , SUM(CASE WHEN P.DC = 'D' THEN 1 ELSE 0 END) AS Debits, SUM(CASE WHEN P.DC = 'C' THEN 1 ELSE 0 END) AS Credits
FROM SourceStaging.VECCASRN.VEC_PA_ANCILLARY PA
INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = PA.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
INNER JOIN #PT P ON P.CASEID = PA.ID
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm = 'PA' AND E.VectusCaseID_Adm = CONVERT(VARCHAR(64), PA.ID))
GROUP BY PA.ID, PA.GW_HDR_CASEID;

/* Q33. TP cases WITHOUT any TP exposure (no row in VEC_GW_TP_SUMMARY, so no VEH/INJ/PRO and no hire) and their payments. -> new BA question N-4 */
SELECT TP.ID AS TP_ID, TP.GW_HDR_CASEID
     , SUM(CASE WHEN P.DC = 'D' THEN 1 ELSE 0 END) AS Debits, SUM(CASE WHEN P.DC = 'C' THEN 1 ELSE 0 END) AS Credits
FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP
INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = TP.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
INNER JOIN #PT P ON P.CASEID = TP.ID
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E WHERE E.GW_HDR_CASEID = TP.GW_HDR_CASEID AND E.VectusCaseID_Adm = CONVERT(VARCHAR(64), TP.ID)
                  AND E.SourceOrigin_Adm IN ('TP_VEH','TP_PRO','TP_INJ','TP_HIRE'))
GROUP BY TP.ID, TP.GW_HDR_CASEID;

/* Q34. Is GCURRENT really 'X' for the current status (Robo M13)? The mapping row 125 says GCURRENT = 'X' and the exposure procs use it too. */
SELECT GCURRENT, COUNT(*) AS Rows_ FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS GROUP BY GCURRENT;

/* Q35. Transfers: does the PaymentMethod typelist know PAY_TYPE 'T'? (Robo M12) */
SELECT Typelist_Name, Vectus_TypeCode, GW_TypeCode, [Household/Motor/Both]
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE LTRIM(RTRIM(Typelist_Name)) = 'PaymentMethod'
ORDER BY Vectus_TypeCode;

/* Q36. After running proc 01: master rows whose CostType is NULL or not claimcost / aoexpense (NULL = dissection code not in the lookup; any other text = a typo in the lookup) */
SELECT CostType, COUNT(*) AS MasterRows, MIN(TranID) AS ExampleTranID
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
WHERE ISNULL(CostType, '') NOT IN ('claimcost', 'aoexpense')
GROUP BY CostType;

/* Q37. (N-5 / Robo "claim level by code") How many payments with the codes Robo wants at claim level (debits EXG, GOO; credits ISR, OLR, PHR, PRC, REE, RTI, RTR, SRS, ASR, PXS, SPH, WPR)
        sit on a CASE (AD / TP / PA) and how many on the claim itself. The code lists are Robo's (Confluence) and are NOT confirmed.
        Run in the IS layer (needs IS_CLAIM_MASTER). */
SELECT UPPER(LTRIM(RTRIM(PT.DEBIT_CREDIT))) AS DC
     , UPPER(LTRIM(RTRIM(D.CODE)))          AS DissCode
     , CASE WHEN PT.CASEID = PT.GW_HDR_CASEID THEN 'HDR'
            WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD A WHERE A.ID = PT.CASEID AND A.GW_HDR_CASEID = PT.GW_HDR_CASEID) THEN 'AD'
            WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_TP T WHERE T.ID = PT.CASEID AND T.GW_HDR_CASEID = PT.GW_HDR_CASEID) THEN 'TP'
            WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_PA_ANCILLARY P WHERE P.ID = PT.CASEID AND P.GW_HDR_CASEID = PT.GW_HDR_CASEID) THEN 'PA'
            ELSE 'UNKNOWN' END AS CaseType
     , COUNT(*) AS Dissections, MIN(PT.ID) AS ExampleTranID
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS  D  ON D.GW_PAY_TRAN_ID = PT.ID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
  AND ( (UPPER(LTRIM(RTRIM(PT.DEBIT_CREDIT))) = 'D' AND UPPER(LTRIM(RTRIM(D.CODE))) IN ('EXG', 'GOO'))
     OR (UPPER(LTRIM(RTRIM(PT.DEBIT_CREDIT))) = 'C' AND UPPER(LTRIM(RTRIM(D.CODE))) IN ('ISR','OLR','PHR','PRC','REE','RTI','RTR','SRS','ASR','PXS','SPH','WPR')) )
GROUP BY UPPER(LTRIM(RTRIM(PT.DEBIT_CREDIT))), UPPER(LTRIM(RTRIM(D.CODE)))
       , CASE WHEN PT.CASEID = PT.GW_HDR_CASEID THEN 'HDR'
              WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD A WHERE A.ID = PT.CASEID AND A.GW_HDR_CASEID = PT.GW_HDR_CASEID) THEN 'AD'
              WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_TP T WHERE T.ID = PT.CASEID AND T.GW_HDR_CASEID = PT.GW_HDR_CASEID) THEN 'TP'
              WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_PA_ANCILLARY P WHERE P.ID = PT.CASEID AND P.GW_HDR_CASEID = PT.GW_HDR_CASEID) THEN 'PA'
              ELSE 'UNKNOWN' END
ORDER BY 1, 2, 3;

/* Q38. Can the same id be a row of two different case tables? (proc 01 S2 tests AD first, then TP, then PA; if an id exists in two of them, the first test wins and I did not decide that on purpose).
        0 rows = no id is shared, the order of the tests does not matter. */
SELECT 'AD & TP' AS Shared, COUNT(*) AS Ids FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD A JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP T ON T.ID = A.ID
UNION ALL
SELECT 'AD & PA', COUNT(*) FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD A JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY P ON P.ID = A.ID
UNION ALL
SELECT 'TP & PA', COUNT(*) FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_TP T JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY P ON P.ID = T.ID;

/* Q38b. Can a CASE id be equal to its own CLAIM KEY? (proc 01 S2 tests "CASEID = CLAIM KEY" first = claim level). 0 = no. */
SELECT 'AD' AS Kind, COUNT(*) AS Ids FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD WHERE ID = GW_HDR_CASEID
UNION ALL SELECT 'TP', COUNT(*) FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_TP WHERE ID = GW_HDR_CASEID
UNION ALL SELECT 'PA', COUNT(*) FROM SourceStaging.VECCASRN.VEC_PA_ANCILLARY WHERE ID = GW_HDR_CASEID;

/* Q39. Data type of the link columns in VEC_GW_PAY_TRANS (proc 01 S1 and S10 no longer convert the link ids because they are numbers; this query only confirms it. If PAYEE_LINKID or ADD_LINKID shows a text type, tell me) */
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM SourceStaging.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'VECCASRN' AND TABLE_NAME = 'VEC_GW_PAY_TRANS'
  AND COLUMN_NAME IN ('PAYEE_LINKID', 'ADD_LINKID', 'AMOUNT', 'CASH_MOVE_NO', 'GW_PAY_GATEID', 'CASEID', 'GW_HDR_CASEID');


/* Q40. Dissection rows whose CODE is empty (NULL / blank / 'NULL' / '<NULL>'). Proc 01 S3 gives them DissCode NULL and S4 matches lookup row 4 (<NULL>) = claimcost.
   Also shows duplicate dissection IDs (must be 0 rows: the ID is used as the line item PublicID). */
SELECT 'empty code' AS Check1, COUNT(*) AS Rows1
FROM SourceStaging.VECCASRN.VEC_GW_PAY_DISS
WHERE CODE IS NULL OR UPPER(LTRIM(RTRIM(CODE))) IN ('', 'NULL', '<NULL>')
UNION ALL
SELECT 'duplicate ID', COUNT(*) FROM (SELECT ID FROM SourceStaging.VECCASRN.VEC_GW_PAY_DISS GROUP BY ID HAVING COUNT(*) > 1) X;


/* Q41. CREDITS (recoveries) whose dissection code is one of the 12 Hire & Mobility codes (uses #PT of the top of this file).
   Proc 01 S4 gives every credit CostType claimcost and IsHire = 0, so a credit is NEVER sent to the hire exposure (the hire exposure has no recovery reserve line).
   0 rows = nothing to discuss. Rows = BA question N-13 (b). */
SELECT P.CaseType, D.CODE, COUNT(*) AS DissRows, COUNT(DISTINCT P.TranID) AS Payments, SUM(D.AMOUNT) AS Amount
FROM #PT P INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D ON D.GW_PAY_TRAN_ID = P.TranID
WHERE P.DC = 'C' AND D.CODE IN ('ABA','ABH','ABP','CDW','FSC','OUH','PLH','PLP','RVM','SUB','TEM','TPH')
GROUP BY P.CaseType, D.CODE
ORDER BY 1, 2;

/* TEST ONLY (reads ExceptionCode). Q42. After the first run: master rows of a TP debit with a hire code but no hire exposure (new exception NO_HIRE_EXPOSURE). Expected 0 rows,
   because the exposure proc creates TP_HIRE whenever a TP payment has one of the 12 codes. */
SELECT TOP 50 TranID, MasterSuffix, GW_HDR_CASEID, CaseID, CostType, MasterAmount
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
WHERE ExceptionCode = 'NO_HIRE_EXPOSURE';


/* Q43. Evidence for the S4 "who wins" ordering (proc 01 S4, ROW_NUMBER in CTE M). Run in SourceStaging / the database that holds Lkp_Transaction_Typelist.
   The ordering only matters if ONE dissection code has TWO lookup rows that both fit the SAME kind of CASE:
   for a TP CASE the fitting rows are V2_CASE 'All' and 'GW_MOTOR_TP'; for any other CASE they are 'All' and 'All cases apart from GW_MOTOR_TP'.
   0 rows in BOTH parts = the ordering never changes a result today (it only protects against future lookup rows). */
SELECT 'TP CASE' AS ForCase, UPPER(LTRIM(RTRIM(DISSECTION_CODE))) AS Code, COUNT(*) AS FittingRows
FROM SourceStaging.dbo.Lkp_Transaction_Typelist
WHERE LOWER(LTRIM(RTRIM(LOB))) = 'motor' AND UPPER(LTRIM(RTRIM(DEBIT_CREDIT))) = 'D'
  AND (UPPER(REPLACE(LTRIM(RTRIM(V2_CASE)), ' ', '_')) = 'GW_MOTOR_TP' OR UPPER(LTRIM(RTRIM(V2_CASE))) = 'ALL')
GROUP BY UPPER(LTRIM(RTRIM(DISSECTION_CODE))) HAVING COUNT(*) > 1
UNION ALL
SELECT 'NON-TP CASE', UPPER(LTRIM(RTRIM(DISSECTION_CODE))), COUNT(*)
FROM SourceStaging.dbo.Lkp_Transaction_Typelist
WHERE LOWER(LTRIM(RTRIM(LOB))) = 'motor' AND UPPER(LTRIM(RTRIM(DEBIT_CREDIT))) = 'D'
  AND (UPPER(REPLACE(LTRIM(RTRIM(V2_CASE)), ' ', '_')) LIKE 'ALL_CASES_APART%' OR UPPER(LTRIM(RTRIM(V2_CASE))) = 'ALL')
GROUP BY UPPER(LTRIM(RTRIM(DISSECTION_CODE))) HAVING COUNT(*) > 1;


/* Q44. After the first run: debit master rows that got a dummy payee, by reason (Oct 13). Expect the two new reasons to be small. */
SELECT PayeeResolution, COUNT(*) AS MasterRows, COUNT(DISTINCT TranID) AS Payments
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
WHERE DebitCredit = 'D' AND IsDummyPayee = 1
GROUP BY PayeeResolution;


/* Q45. Claim-level CREDITS (recoveries whose CASEID = the CLAIM KEY GW_HDR_CASEID). Run in the IS layer, no proc needed.
   Why: the reserve proc creates claim-level lines only for claim cost and expense (RESERVE) and only if the claim has a claim-level DEBIT.
   It creates no claim-level RECOVERY line. A claim-level credit therefore has no recovery reserve line to land on (exception NO_RECOVERY_RESERVE_LINE).
   Columns: ClaimsWithHdrCredit = claims with at least one claim-level credit; AlsoHaveHdrDebit = of those, claims that also have a claim-level debit
   (only these claims get the claim-level claim cost / expense reserve lines today). */
SELECT COUNT(*) AS ClaimsWithHdrCredit
     , SUM(CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS D
                             WHERE D.GW_HDR_CASEID = X.GW_HDR_CASEID AND D.CASEID = D.GW_HDR_CASEID AND LTRIM(RTRIM(D.DEBIT_CREDIT)) = 'D') THEN 1 ELSE 0 END) AS AlsoHaveHdrDebit
     , SUM(Trans) AS HdrCreditTransactions, SUM(Amount) AS HdrCreditAmount
FROM (SELECT PT.GW_HDR_CASEID, COUNT(*) AS Trans, SUM(CONVERT(DECIMAL(18,2), PT.AMOUNT)) AS Amount
      FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
      INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = PT.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
      WHERE PT.CASEID = PT.GW_HDR_CASEID AND LTRIM(RTRIM(PT.DEBIT_CREDIT)) = 'C'
      GROUP BY PT.GW_HDR_CASEID) X;
/* examples (first 20 claims) */
SELECT TOP (20) PT.GW_HDR_CASEID, CLM.CLAIM_REF, PT.ID AS TranID, PT.AMOUNT
FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = PT.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
WHERE PT.CASEID = PT.GW_HDR_CASEID AND LTRIM(RTRIM(PT.DEBIT_CREDIT)) = 'C'
ORDER BY PT.GW_HDR_CASEID, PT.ID;
/* TEST ONLY (reads ExceptionCode). After the first run: what proc 01 did with them */
SELECT ExceptionCode, COUNT(*) AS MasterRows
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
WHERE CaseType = 'HDR' AND DebitCredit = 'C'
GROUP BY ExceptionCode;


/* Q46. After the first run: dummy payees by reason (report), and debits without a claim contact (must be 0 rows). */
SELECT M.PayeeResolution, COUNT(*) AS MasterRows, MIN(M.TranID) AS ExampleTranID, MIN(M.CLAIM_REF) AS ExampleClaim
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.DebitCredit = 'D' AND M.IsDummyPayee = 1
GROUP BY M.PayeeResolution ORDER BY MasterRows DESC;

SELECT M.TranID, M.MasterSuffix, M.GW_HDR_CASEID AS ClaimKey, M.CLAIM_REF, M.PayeeResolution
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.DebitCredit = 'D' AND M.Loadable = 1
  AND (M.PayeeClaimContactID IS NULL
       OR NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC WHERE CC.PublicID = M.PayeeClaimContactID)
          AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR D WHERE D.PublicID = M.PayeeClaimContactID));


/* ################################ PART 2: VALIDATION (V1 - V9c, V2e) ################################ */
/* V1. Duplicate PublicIDs (one query per table) */
SELECT 'TRANSACTION' AS Tbl, PublicID, COUNT(*) AS Cnt FROM dbo.IS_TRANSACTION_PAY_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'LINEITEM', PublicID, COUNT(*) FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'SET',      PublicID, COUNT(*) FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR      GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'CHECK',    PublicID, COUNT(*) FROM dbo.IS_CHECK_MOTOR                   GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'CHECKPAYEE', PublicID, COUNT(*) FROM dbo.IS_CHECKPAYEE_MOTOR            GROUP BY PublicID HAVING COUNT(*) > 1;

/* V2. Foreign keys that point nowhere (expected load errors, see the header of this file) */
SELECT 'TX -> CLAIM' AS Fk, T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIM_MASTER C WHERE C.PUBLICID = T.ClaimID)
UNION ALL SELECT 'TX -> RESERVELINE', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_RESERVELINE_MOTOR R WHERE R.PublicID = T.ReserveLineID)
UNION ALL SELECT 'TX -> EXPOSURE', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE T.ExposureID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IS_EXPOSURE_MOTOR E WHERE E.Exposure_Motor_PublicID = T.ExposureID)
UNION ALL SELECT 'TX -> RECOVERYCODING', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE T.Subtype = 'Recovery' AND NOT EXISTS (SELECT 1 FROM dbo.IS_RECOVERYCODING_MOTOR RC WHERE RC.PublicID = T.RecoveryCodingID)
UNION ALL SELECT 'TX -> SET', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR S WHERE S.PublicID = T.TransactionSetID)
UNION ALL SELECT 'TX -> CHECK', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE T.Subtype = 'Payment' AND NOT EXISTS (SELECT 1 FROM dbo.IS_CHECK_MOTOR C WHERE C.PublicID = T.CheckID)
UNION ALL SELECT 'LINEITEM -> TX', L.PublicID FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR L
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_TRANSACTION_PAY_MOTOR T WHERE T.PublicID = L.TransactionID)
UNION ALL SELECT 'CHECK -> SET', C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR S WHERE S.PublicID = C.CheckSetID)
UNION ALL SELECT 'CHECKPAYEE -> CHECK', P.PublicID FROM dbo.IS_CHECKPAYEE_MOTOR P
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CHECK_MOTOR C WHERE C.PublicID = P.CheckID)
/* check pay contact foreign keys: real claim contact (IS_CLAIMCONTACT) or dummy claim contact (IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR) */
UNION ALL SELECT 'CHECK -> CLAIMCONTACT', C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIMCONTACT CC WHERE CC.PublicID = C.ClaimContactID)
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR D WHERE D.PublicID = C.ClaimContactID)
UNION ALL SELECT 'CHECKPAYEE -> CLAIMCONTACT', P.PublicID FROM dbo.IS_CHECKPAYEE_MOTOR P
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIMCONTACT CC WHERE CC.PublicID = P.ClaimContactID)
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR D WHERE D.PublicID = P.ClaimContactID)
UNION ALL SELECT 'CHECK.InCareOf_Adm -> CONTACT', C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE C.InCareOf_Adm IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.CONTACT_MASTER_MOTOR M WHERE M.PublicID = C.InCareOf_Adm)
UNION ALL SELECT 'CHECK.MailingAddressID -> ADDRESS', C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE C.MailingAddressID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IS_ADDRESS_CONTACT A WHERE A.CONTACT_ADDRESS_PUBLICID = C.MailingAddressID)
UNION ALL SELECT 'DUMMY CLAIMCONTACT -> DUMMY CONTACT', D.PublicID FROM dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR D
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_DUMMY_PAYEE_CONTACT_MOTOR C WHERE C.PublicID = D.ContactID)
UNION ALL SELECT 'DUMMY CONTACT -> DUMMY ADDRESS', C.PublicID FROM dbo.IS_DUMMY_PAYEE_CONTACT_MOTOR C
WHERE C.PrimaryAddressID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IS_DUMMY_PAYEE_ADDRESS_MOTOR A WHERE A.PublicID = C.PrimaryAddressID)
UNION ALL SELECT 'DUMMY CLAIMCONTACT -> CLAIM', D.PublicID FROM dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR D
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIM_MASTER C WHERE C.PUBLICID = D.ClaimID);

/* V2b. Dummy payee: duplicate PublicIDs, and every dummy claim contact used by a check must exist (checked above) */
SELECT 'DUP DUMMY CONTACT' AS Chk, PublicID, COUNT(*) AS Cnt FROM dbo.IS_DUMMY_PAYEE_CONTACT_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'DUP DUMMY CLAIMCONTACT', PublicID, COUNT(*) FROM dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'DUP DUMMY ADDRESS', PublicID, COUNT(*) FROM dbo.IS_DUMMY_PAYEE_ADDRESS_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1;
/* dummy rows that no loaded check uses (should be 0) */
SELECT 'DUMMY CLAIMCONTACT NOT USED' AS Chk, D.PublicID FROM dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR D
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CHECK_MOTOR C WHERE C.ClaimContactID = D.PublicID);
/* a loaded check on a dummy payee but the dummy contact was not built (run proc 01b after proc 01) - should be 0 */
SELECT 'CHECK ON DUMMY WITHOUT DUMMY ROWS' AS Chk, M.TranID, M.MasterSuffix FROM dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.Loadable = 1 AND M.DebitCredit = 'D' AND M.IsDummyPayee = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR D WHERE D.PublicID = M.PayeeClaimContactID);

/* V2c. Pay contact rules on the check (report rows, not necessarily errors) */
/* MailTo must be filled exactly when InCareOf_Adm is filled, and the in-care-of contact normally has an address */
SELECT 'MAILTO RULE BROKEN' AS Chk, C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE (C.InCareOf_Adm IS NULL AND (C.MailTo IS NOT NULL OR C.MailingAddressID IS NOT NULL));
SELECT 'INCAREOF WITHOUT MAILINGADDRESS (report)' AS Chk, C.PublicID, C.InCareOf_Adm FROM dbo.IS_CHECK_MOTOR C
WHERE C.InCareOf_Adm IS NOT NULL AND C.MailingAddressID IS NULL;
SELECT 'INCAREOF WITHOUT MAILTO TEXT (report)' AS Chk, C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE C.InCareOf_Adm IS NOT NULL AND C.MailTo IS NULL;
SELECT 'PAYTO EMPTY (report; company payees, BA question 27)' AS Chk, COUNT(*) AS Cnt FROM dbo.IS_CHECK_MOTOR WHERE PayTo IS NULL;
/* the check claim contact must belong to the same claim as the check */
SELECT 'CHECK CLAIMCONTACT ON OTHER CLAIM' AS Chk, C.PublicID FROM dbo.IS_CHECK_MOTOR C
INNER JOIN dbo.IS_CLAIMCONTACT CC ON CC.PublicID = C.ClaimContactID
WHERE CC.ClaimID <> C.ClaimID;
/* check payee must be the same claim contact as the check */
SELECT 'CHECKPAYEE <> CHECK CLAIMCONTACT' AS Chk, P.PublicID FROM dbo.IS_CHECKPAYEE_MOTOR P
INNER JOIN dbo.IS_CHECK_MOTOR C ON C.PublicID = P.CheckID WHERE ISNULL(P.ClaimContactID,'') <> ISNULL(C.ClaimContactID,'');

/* V2d. Check payee ROLE rows: Role = 'checkpayee' in IS_CLAIMCONTACTROLE (inserted by usp_Load_IS_CLAIMCONTACTROLE v7, step 5B). Run AFTER that proc. All should return 0 rows. */
SELECT 'DUP CHECKPAYEE ROLE PUBLICID' AS Chk, PublicID, COUNT(*) AS Cnt FROM dbo.IS_CLAIMCONTACTROLE GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'CHECKPAYEE ROLE PUBLICID LONGER THAN 64', PublicID, LEN(PublicID) FROM dbo.IS_CLAIMCONTACTROLE WHERE Role = 'checkpayee' AND LEN(PublicID) > 64
UNION ALL SELECT 'CHECKPAYEE ROLE -> CLAIMCONTACT MISSING', R.PublicID, NULL FROM dbo.IS_CLAIMCONTACTROLE R
WHERE R.Role = 'checkpayee'
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIMCONTACT C WHERE C.PublicID = R.ClaimContactID)
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR D WHERE D.PublicID = R.ClaimContactID)
UNION ALL SELECT 'CHECKPAYEE ROLE -> EXPOSURE MISSING', R.PublicID, NULL FROM dbo.IS_CLAIMCONTACTROLE R
WHERE R.Role = 'checkpayee' AND R.ExposureID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IS_EXPOSURE_MOTOR E WHERE E.Exposure_Motor_PublicID = R.ExposureID)
UNION ALL SELECT 'CHECK PAYEE WITHOUT CHECKPAYEE ROLE', P.PublicID, NULL FROM dbo.IS_CHECKPAYEE_MOTOR P
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIMCONTACTROLE R WHERE R.Role = 'checkpayee' AND R.ClaimContactID = P.ClaimContactID);

/* V3. Cardinality rules */
/* every transaction has at least one line item */
SELECT 'TX WITHOUT LINEITEM' AS Chk, T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR L WHERE L.TransactionID = T.PublicID);
/* exactly one check payee per check */
SELECT 'CHECK PAYEE COUNT <> 1' AS Chk, C.PublicID, COUNT(P.PublicID) AS Payees
FROM dbo.IS_CHECK_MOTOR C LEFT JOIN dbo.IS_CHECKPAYEE_MOTOR P ON P.CheckID = C.PublicID
GROUP BY C.PublicID HAVING COUNT(P.PublicID) <> 1;
/* a transaction set belongs to exactly one transaction */
SELECT 'SET TRANSACTION COUNT <> 1' AS Chk, S.PublicID, COUNT(T.PublicID) AS Tx
FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR S LEFT JOIN dbo.IS_TRANSACTION_PAY_MOTOR T ON T.TransactionSetID = S.PublicID
GROUP BY S.PublicID HAVING COUNT(T.PublicID) <> 1;
/* a check belongs to exactly one payment transaction */
SELECT 'CHECK TRANSACTION COUNT <> 1' AS Chk, C.PublicID, COUNT(T.PublicID) AS Tx
FROM dbo.IS_CHECK_MOTOR C LEFT JOIN dbo.IS_TRANSACTION_PAY_MOTOR T ON T.CheckID = C.PublicID
GROUP BY C.PublicID HAVING COUNT(T.PublicID) <> 1;
/* a payment never has a recovery coding, a recovery never has a check */
SELECT 'WRONG SUBTYPE FIELDS' AS Chk, PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR
WHERE (Subtype = 'Payment' AND (CheckID IS NULL OR RecoveryCodingID IS NOT NULL))
   OR (Subtype = 'Recovery' AND (CheckID IS NOT NULL OR RecoveryCodingID IS NULL));

/* V4. Cost type and exposure of the transaction must equal those of its reserve line */
SELECT 'COSTTYPE/EXPOSURE DIFFERS FROM RESERVE LINE' AS Chk, T.PublicID
FROM dbo.IS_TRANSACTION_PAY_MOTOR T
INNER JOIN dbo.IS_RESERVELINE_MOTOR R ON R.PublicID = T.ReserveLineID
WHERE ISNULL(R.CostType, '') <> ISNULL(T.CostType, '')
   OR ISNULL(R.CostCategory, '') <> ISNULL(T.CostCategory, '')
   OR ISNULL(R.ExposureID, '') <> ISNULL(T.ExposureID, '')
   OR ISNULL(R.ClaimID, '') <> ISNULL(T.ClaimID, '');

/* V5. Money: loaded line items must equal the V2 dissections of the loaded master rows (report: difference per case type) */
SELECT U.CaseType, U.DebitCredit
     , SUM(U.MasterAmount) AS MasterAmountLoadable
FROM dbo.IS_PAYMENT_MASTER_MOTOR U
WHERE U.Loadable = 1
GROUP BY U.CaseType, U.DebitCredit;
SELECT 'LINEITEM TOTAL' AS Chk, SUM(TransactionAmount) AS Amount FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR;
/* line items vs master-row amount, master row by master row */
SELECT 'MASTER AMOUNT <> LINE SUM' AS Chk, U.TranID, U.MasterSuffix, U.MasterAmount, SUM(L.Amount) AS LineSum
FROM dbo.IS_PAYMENT_MASTER_MOTOR U
INNER JOIN dbo.IS_PAYMENT_MASTER_LINE_MOTOR L ON L.TranID = U.TranID AND L.MasterSuffix = U.MasterSuffix
WHERE U.Loadable = 1
GROUP BY U.TranID, U.MasterSuffix, U.MasterAmount
HAVING ABS(U.MasterAmount - SUM(L.Amount)) > 0.005;

/* V6. Coverage: every V2 transaction of a Motor claim is either loaded, or listed as an exception (report) */
SELECT 'V2 TRANSACTIONS' AS Chk, COUNT(*) AS Cnt
FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
WHERE EXISTS (SELECT 1 FROM dbo.IS_CLAIM_MASTER C WHERE C.GW_HDR_CASEID = PT.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR');
SELECT 'V2 TRANSACTIONS WITH AT LEAST ONE LOADED MASTER ROW' AS Chk, COUNT(DISTINCT TranID) AS Cnt FROM dbo.IS_PAYMENT_MASTER_MOTOR WHERE Loadable = 1;
SELECT 'V2 TRANSACTIONS WITH NO COPIED MASTER ROW (only PA recoveries, field-mapping row 136 (cc_transaction.ExposureID))' AS Chk, COUNT(*) AS Cnt
FROM (SELECT TranID FROM dbo.IS_PAYMENT_MASTER_MOTOR GROUP BY TranID HAVING MAX(CONVERT(INT, Loadable)) = 0) X;
/* a V2 transaction that appears in no master row at all (should be 0) */
SELECT 'V2 TRANSACTION MISSING FROM MASTER ROWS' AS Chk, PT.ID
FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
WHERE EXISTS (SELECT 1 FROM dbo.IS_CLAIM_MASTER C WHERE C.GW_HDR_CASEID = PT.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR')
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_PAYMENT_MASTER_MOTOR U WHERE U.TranID = PT.ID);

/* V7. Where the money went (report) */
SELECT U.CaseType, U.SourceOrigin_Adm, U.DebitCredit, U.CostType, COUNT(*) AS MasterRows, SUM(U.MasterAmount) AS Amount
FROM dbo.IS_PAYMENT_MASTER_MOTOR U
WHERE U.Loadable = 1
GROUP BY U.CaseType, U.SourceOrigin_Adm, U.DebitCredit, U.CostType
ORDER BY U.CaseType, U.SourceOrigin_Adm, U.DebitCredit, U.CostType;

/* TEST ONLY (needs IS_PAYMENT_EXCEPTION_MOTOR). V8. Exceptions (report) */
SELECT Severity, ExceptionCode, CaseType, DebitCredit, COUNT(*) AS MasterRows, SUM(MasterAmount) AS Amount
FROM dbo.IS_PAYMENT_EXCEPTION_MOTOR
GROUP BY Severity, ExceptionCode, CaseType, DebitCredit
ORDER BY Severity, COUNT(*) DESC;


/* V9. Typecodes: every fixed code the procs write must exist in the typelist (file 14 part B lists the typelist rows) */
;WITH F (TL_Name, GWCode) AS
(
    SELECT * FROM (VALUES
          ('CheckBatching','apdefault'),('CheckBatching','bulkcheck'),('CheckType','primary')
        , ('RecoveryCategory','subro'),('Currency','gbp'),('PaymentType','partial'),('CreatedVia','manual')
        , ('Transaction','Payment'),('Transaction','Recovery'),('TransactionSet','CheckSet'),('TransactionSet','RecoverySet')
        , ('CostType','claimcost'),('CostType','aoexpense')) V (TL_Name, GWCode)
)
SELECT 'TYPECODE NOT IN TYPELIST' AS Chk, F.TL_Name, F.GWCode
FROM F
WHERE NOT EXISTS (SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING T
                  WHERE LTRIM(RTRIM(T.Typelist_Name)) = F.TL_Name AND LTRIM(RTRIM(T.GW_TypeCode)) = F.GWCode
                    AND (T.[Household/Motor/Both] IS NULL OR T.[Household/Motor/Both] IN ('Motor only','Both')));

/* V9b. Lines of copied master rows without a LineCategory typecode (since Oct 13 the code is the lookup LineItem text, no typelist join; expected 0) */
SELECT 'LINE WITHOUT LINECATEGORY CODE' AS Chk, COUNT(*) AS Cnt
FROM dbo.IS_PAYMENT_MASTER_LINE_MOTOR L
JOIN dbo.IS_PAYMENT_MASTER_MOTOR U ON U.TranID = L.TranID AND U.MasterSuffix = L.MasterSuffix AND U.Loadable = 1
WHERE L.LineCategoryCode IS NULL;

/* V9c. Copied master rows whose status / lifecycle / approval / payment method code is empty (report: expected load errors) */
SELECT 'EMPTY TYPECODE' AS Chk
     , SUM(CASE WHEN Status IS NULL THEN 1 ELSE 0 END) AS NoStatus
     , SUM(CASE WHEN LifeCycleState IS NULL THEN 1 ELSE 0 END) AS NoLifeCycle
     , SUM(CASE WHEN ApprovalStatus IS NULL THEN 1 ELSE 0 END) AS NoApproval
     , SUM(CASE WHEN DebitCredit = 'D' AND PaymentMethod IS NULL THEN 1 ELSE 0 END) AS DebitNoPaymentMethod
FROM dbo.IS_PAYMENT_MASTER_MOTOR WHERE Loadable = 1;

/* V2e (Oct 13). Dummy payees that are in the IS_DUMMY_PAYEE_*_MOTOR tables but missing from the final IS tables (run AFTER usp_Load_SS_to_IS_ADDRESS_DUMMY_PAYEE_MOTOR and usp_Load_SS_to_IS_CONTACT_DUMMY_PAYEE_MOTOR). All should return 0 rows. */
SELECT 'contact missing in IS_CONTACT' AS Problem, P.PublicID FROM IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CONTACT_MOTOR P
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_CONTACT C WHERE C.PublicID = P.PublicID)
UNION ALL
SELECT 'claim contact missing in IS_CLAIMCONTACT', P.PublicID FROM IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR P
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT C WHERE C.PublicID = P.PublicID)
UNION ALL
SELECT 'address missing in IS_ADDRESS', P.PublicID FROM IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_ADDRESS_MOTOR P
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_ADDRESS A WHERE A.PublicID = P.PublicID);

/* V10 (Oct 13). AFTER the five main procs (usp_Load_SS_to_IS_TRANSACTION, _TRANSACTIONSET, _TRANSACTIONLINEITEM, _CHECK, _CHECKPAYEE) with the file 15 blocks.
   Rows of my intermediate tables that are NOT in the main IS table (by PublicID). Expected 0 rows. */
SELECT 'transaction' AS MainTable, M.PublicID FROM IntermediateStaging_DEV.dbo.IS_TRANSACTION_PAY_MOTOR M
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_TRANSACTION T WHERE T.PublicID = M.PublicID)
UNION ALL
SELECT 'transactionset', M.PublicID FROM IntermediateStaging_DEV.dbo.IS_TRANSACTIONSET_PAY_MOTOR M
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_TRANSACTIONSET T WHERE T.PublicID = M.PublicID)
UNION ALL
SELECT 'transactionlineitem', M.PublicID FROM IntermediateStaging_DEV.dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR M
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_TRANSACTIONLINEITEM T WHERE T.PublicID = M.PublicID)
UNION ALL
SELECT 'check', M.PublicID FROM IntermediateStaging_DEV.dbo.IS_CHECK_MOTOR M
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_CHECK T WHERE T.PublicID = M.PublicID)
UNION ALL
SELECT 'checkpayee', M.PublicID FROM IntermediateStaging_DEV.dbo.IS_CHECKPAYEE_MOTOR M
WHERE NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_CHECKPAYEE T WHERE T.PublicID = M.PublicID);

/* V10b. PublicIDs that appear more than once in a main table. Expected 0 rows. */
SELECT 'IS_TRANSACTION' AS MainTable, PublicID, COUNT(*) AS N FROM IntermediateStaging_DEV.dbo.IS_TRANSACTION GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'IS_TRANSACTIONSET', PublicID, COUNT(*) FROM IntermediateStaging_DEV.dbo.IS_TRANSACTIONSET GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'IS_TRANSACTIONLINEITEM', PublicID, COUNT(*) FROM IntermediateStaging_DEV.dbo.IS_TRANSACTIONLINEITEM GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'IS_CHECK', PublicID, COUNT(*) FROM IntermediateStaging_DEV.dbo.IS_CHECK GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'IS_CHECKPAYEE', PublicID, COUNT(*) FROM IntermediateStaging_DEV.dbo.IS_CHECKPAYEE GROUP BY PublicID HAVING COUNT(*) > 1;

/* =====================================================================================================
   AD1 to AD7 (Oct 15). AD payments (D) AND AD recoveries (C) of claims WITHOUT AD exposure, moved to claim level (BA confirmed).
   Run AFTER usp_Load_IS_PAYMENT_MASTER_MOTOR (PROD or TEST) and after usp_Load_SS_to_IS_RESERVELINE_MOTOR and usp_Load_SS_to_IS_RECOVERYCODING_MOTOR.
   Master rows moved to claim level: CaseType = 'AD' (source case is an AD case) and SourceOrigin_Adm = 'HDR' (target is the CLAIM KEY).
   The move is the same for D and C. The reserve side (file 25) must provide: debit -> claim-level reserve line, credit -> claim-level recovery line '_rec' + recovery coding.
   ===================================================================================================== */
/* AD1. How many master rows were moved, debit / credit, claims, amount (report). */
SELECT M.DebitCredit, COUNT(*) AS MasterRows, COUNT(DISTINCT M.GW_HDR_CASEID) AS Claims, SUM(M.MasterAmount) AS Amount
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.CaseType = 'AD' AND M.SourceOrigin_Adm = 'HDR'
GROUP BY M.DebitCredit;

/* AD2. Moved DEBITS without a reserve line (ReserveLineID NULL or not in IS_RESERVELINE_MOTOR). Needs reserve proc block B7 to include
   AD payments moved to claim level. Rows here = the reserve gap (BA / reserve proc owner). */
SELECT M.GW_HDR_CASEID AS ClaimKey, M.CLAIM_REF, M.TranID, M.MasterSuffix, M.MasterAmount, M.ReserveLineID
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.CaseType = 'AD' AND M.SourceOrigin_Adm = 'HDR' AND M.DebitCredit = 'D'
  AND (M.ReserveLineID IS NULL
       OR NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_RESERVELINE_MOTOR R WHERE R.PublicID = M.ReserveLineID));

/* AD3. Moved CREDITS (recoveries) without ReserveLineID or RecoveryCodingID. Expected 0 rows AFTER file 25 (PART 2 and PART 3) is applied.
   Before file 25: every moved credit is listed here (no claim-level recovery line exists yet). */
SELECT M.GW_HDR_CASEID AS ClaimKey, M.CLAIM_REF, M.TranID, M.MasterAmount, M.ReserveLineID, M.RecoveryCodingID
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.CaseType = 'AD' AND M.SourceOrigin_Adm = 'HDR' AND M.DebitCredit = 'C'
  AND (M.RecoveryCodingID IS NULL OR M.ReserveLineID IS NULL);

/* AD4. Check the rule: a claim in AD1 must have NO AD exposure. Expected 0 rows. */
SELECT DISTINCT M.GW_HDR_CASEID AS ClaimKey, M.CLAIM_REF
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.CaseType = 'AD' AND M.SourceOrigin_Adm = 'HDR'
  AND EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
              WHERE E.GW_HDR_CASEID = M.GW_HDR_CASEID AND E.SourceOrigin_Adm = 'AD');

/* AD5. TEST ONLY (reads WarnList): the warning 'AD_NO_EXPOSURE_TO_CLAIM_LEVEL;' count must equal AD1 total. */
SELECT COUNT(*) AS RowsWithWarning FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR WHERE WarnList LIKE '%AD_NO_EXPOSURE_TO_CLAIM_LEVEL;%';

/* AD6. Moved CREDITS whose ReserveLineID is not a '_rec' line of origin 'HDR' in IS_RESERVELINE_MOTOR. Expected 0 rows after file 25. */
SELECT M.GW_HDR_CASEID AS ClaimKey, M.CLAIM_REF, M.TranID, M.MasterSuffix, M.ReserveLineID
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.CaseType = 'AD' AND M.SourceOrigin_Adm = 'HDR' AND M.DebitCredit = 'C'
  AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_RESERVELINE_MOTOR R
                  WHERE R.PublicID = M.ReserveLineID AND R.SourceOrigin_Adm = 'HDR' AND RIGHT(R.PublicID, 4) = '_rec');

/* AD7. Moved CREDITS whose RecoveryCodingID is not in IS_RECOVERYCODING_MOTOR (PublicID NULL there = token 'HDR' missing, file 25 PART 3). Expected 0 rows after file 25. */
SELECT M.GW_HDR_CASEID AS ClaimKey, M.CLAIM_REF, M.TranID, M.MasterSuffix, M.RecoveryCodingID
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.CaseType = 'AD' AND M.SourceOrigin_Adm = 'HDR' AND M.DebitCredit = 'C'
  AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_RECOVERYCODING_MOTOR RC WHERE RC.PublicID = M.RecoveryCodingID);

/* =====================================================================================================
   PT1 to PT2. PayTo / PayToDenorm of the checks. Run AFTER usp_Load_IS_CHECK_MOTOR.
   ===================================================================================================== */
/* PT1. Contact subtype of the real payees of the checks and how many checks have PayTo NULL (report). */
SELECT CM.Subtype, COUNT(*) AS Checks, SUM(CASE WHEN K.PayTo IS NULL THEN 1 ELSE 0 END) AS PayToNull
FROM IntermediateStaging_DEV.dbo.IS_CHECK_MOTOR K
INNER JOIN IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR X ON 'mig:motorchk_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix = K.PublicID
LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.PublicID = X.PayeeContactID AND X.IsDummyPayee = 0
GROUP BY CM.Subtype ORDER BY Checks DESC;

/* PT2. Checks with PayTo NULL: first rows. Expected 0 rows. */
SELECT TOP (50) K.PublicID, K.ClaimContactID, X.IsDummyPayee, X.PayeeResolution, CM.Subtype, CM.Name, CM.FirstName, CM.LastName
FROM IntermediateStaging_DEV.dbo.IS_CHECK_MOTOR K
INNER JOIN IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR X ON 'mig:motorchk_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix = K.PublicID
LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.PublicID = X.PayeeContactID AND X.IsDummyPayee = 0
WHERE K.PayTo IS NULL;
