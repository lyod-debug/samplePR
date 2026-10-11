/* =====================================================================================
   09_data_check_queries_payments_motor.sql
   READ-ONLY queries. Run them one by one and send the result (first 20 rows is enough).
   Each query says WHY it is needed and WHICH BA / senior question it supports.
   Claims are always taken from IS_CLAIM_MASTER (PRODUCT = MOTOR) on GW_HDR_CASEID.
   The case type of a payment is worked out exactly like proc 01 does (CASEID against the claim / AD / TP / PA case).
   ===================================================================================== */

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

/* Q11. Credits (recoveries) per case type, and how many have a recovery reserve line available -> BA question 1 / senior question 3 */
SELECT P.CaseType, COUNT(*) AS Credits, SUM(P.AMOUNT) AS Amount, MIN(P.TranID) AS ExampleTranID
FROM #PT P WHERE P.DC = 'C' GROUP BY P.CaseType;

/* Q11b. AD credits whose AD case (or the surviving AD case) has no recovery reserve line '_rec' */
SELECT P.TranID, P.CLAIM_REF, P.CASEID
FROM #PT P
WHERE P.DC = 'C' AND P.CaseType = 'AD'
  AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.IS_RESERVELINE_MOTOR R
                  WHERE R.GW_HDR_CASEID = P.GW_HDR_CASEID AND R.SourceOrigin_Adm = 'AD' AND RIGHT(R.PublicID,4) = '_rec');

/* Q11c. Header-level credits (CASEID = claim): claims that would need the claim-level 'pm_other_adm' recovery line (lookup row 4) */
SELECT P.GW_HDR_CASEID, P.CLAIM_REF, COUNT(*) AS Credits, SUM(P.AMOUNT) AS Amount, MIN(P.TranID) AS ExampleTranID
FROM #PT P WHERE P.DC = 'C' AND P.CaseType = 'HDR'
GROUP BY P.GW_HDR_CASEID, P.CLAIM_REF ORDER BY COUNT(*) DESC;

/* Q12. Injury: debit expense payments that land on a TP injury exposure which has no 'Third Party Solicitors Costs' line  -> BA question 3
        (run AFTER proc 01: this is the NO_MAIN_INJ_LINE list) */
SELECT TOP 50 TranID, MasterSuffix, GW_HDR_CASEID, CLAIM_REF, CaseID, CostType, MasterAmount, CASE_STATUS
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
WHERE ExceptionCode = 'NO_MAIN_INJ_LINE';

/* Q13. Statuses: V2 STATUS_TYPE values in use, and whether the typelist knows them */
SELECT S.STATUS_TYPE, S.GCURRENT, COUNT(*) AS Rws
FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S
INNER JOIN #PT P ON P.TranID = S.GW_PAY_TRAN_ID
GROUP BY S.STATUS_TYPE, S.GCURRENT ORDER BY S.GCURRENT DESC, COUNT(*) DESC;

/* Q13b. The 5 typelists I read, exactly as stored  -> senior question 1 (how were LifeCycleState / ApprovalStatus keyed?) */
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
        Supports BA question 11 (what to do with categories 3, 4, 5) and senior items about contact master / claim contact.
        Categories 1 and 2 = dummy payee (BA rule). 3, 4, 5, 6 = blocking exceptions in proc 01 until the BA decides. */
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
         (this is a contact / address proc question for the senior) */
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

/* Q21. After running proc 01: master rows by first problem found (ExceptionCode NULL = nothing found). All rows are copied except PA recoveries. */
SELECT ExceptionCode, CaseType, DebitCredit, COUNT(*) AS MasterRows, SUM(MasterAmount) AS Amount, MIN(TranID) AS ExampleTranID
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
GROUP BY ExceptionCode, CaseType, DebitCredit ORDER BY CASE WHEN ExceptionCode IS NULL THEN 1 ELSE 0 END, COUNT(*) DESC;

/* Q22. After running proc 01: V2 transactions split into several master rows where only SOME of them have a problem
         (e.g. the claim-cost part has a reserve line, the expense part has none). All rows are still copied; ClaimCenter will reject only the
         bad part. Show these to the BA (question 16). */
SELECT TranID, COUNT(*) AS MasterRows, SUM(CASE WHEN ExceptionCode IS NULL THEN 1 ELSE 0 END) AS RowsWithoutIssue, MIN(CLAIM_REF) AS CLAIM_REF
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
GROUP BY TranID HAVING SUM(CASE WHEN ExceptionCode IS NULL THEN 1 ELSE 0 END) BETWEEN 1 AND COUNT(*) - 1;


/* Q23. TRANS_REF is CHAR(16): how many references carry trailing blanks (BA question 23) */
SELECT COUNT(*) AS Rows_With_Padding, MIN(TRANS_REF) AS ExampleRef
FROM SourceStaging.dbo.VEC_GW_PAY_GATEWAY
WHERE DATALENGTH(TRANS_REF) <> DATALENGTH(RTRIM(TRANS_REF)) OR LEN(TRANS_REF) < DATALENGTH(TRANS_REF);

/* Q24. CASH_MOVE_NO must become a number (ClaimCenter longint): values that are not numeric */
SELECT CASH_MOVE_NO, COUNT(*) AS Rows_
FROM SourceStaging.dbo.VEC_GW_PAY_TRANS
WHERE NULLIF(LTRIM(RTRIM(CASH_MOVE_NO)), '') IS NOT NULL AND TRY_CONVERT(BIGINT, LTRIM(RTRIM(CASH_MOVE_NO))) IS NULL
GROUP BY CASH_MOVE_NO ORDER BY COUNT(*) DESC;

/* Q25. DISS AMOUNT is DOUBLE: amounts with more than 2 decimals (they are rounded to pennies) */
SELECT TOP (100) D.*
FROM SourceStaging.dbo.VEC_GW_PAY_DISS D
WHERE ABS(CONVERT(FLOAT, D.AMOUNT) * 100 - ROUND(CONVERT(FLOAT, D.AMOUNT) * 100, 0)) > 0.0001;
