/* =====================================================================================
   01_usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR
   The BASE proc of the MOTOR payments / recoveries load. Every other payment proc only reads
   what this one writes.

   What it decides, per V2 transaction (VEC_GW_PAY_TRANS):
     1. which CASE the money belongs to  : HDR (claim level) / AD / TP / PA          (CaseType)
     2. cost type of every dissection     : claimcost / aoexpense / Hire & Mobility   (Lkp_Transaction_Typelist)
     3. how many ClaimCenter transactions: one per (exposure, cost type)              (MasterSuffix)
     4. which reserve line each one hits  : the "main" line of the exposure           (IS_RESERVELINE_MOTOR)
     5. status / dates / payee            : VEC_GW_PAY_STATUS, typelists, contact master
     6. whether the master row can be loaded    : ExceptionCode (blocking) / WarnList (information)

   RUN ORDER: contacts / claim contacts, exposure, reserve line, the senior's reserve TRANSACTION proc, then the
   senior's recovery coding proc (it is built from the reserve transactions, Subtype = RecoveryReserve) FIRST.
   NOTHING IS HELD BACK. Every V2 transaction of a Motor claim becomes master row(s) and is copied to the
   transaction tables, even when a link is missing (reserve line, recovery coding, payee, status ...): the
   missing value stays NULL and ClaimCenter reports it as a load error, which is analysed later with the BA.
   ExceptionCode / WarnList are only a LIST of what looks wrong (information); they never stop a row and the
   procs never fail the run. The ONE exclusion is the one the mapping states itself (row 136): recoveries on PA
   (ancillary) cases are not migrated. @ExcludePaCredits below switches that on (1) or off (0).
   Loadable = 1 means "copied to the transaction tables"; it is 0 only for those PA recoveries.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR
AS
BEGIN
    SET NOCOUNT ON;

    /* 1 = recoveries on PA (ancillary) cases are NOT copied to the transaction tables (mapping row 136: "should not be migrated").
       0 = they are copied like every other recovery. They always stay in IS_PAYMENT_MASTER_MOTOR. */
    DECLARE @ExcludePaCredits BIT = 1;

    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_LINE_MOTOR;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR;

    /* ==================================================================================
       S1. Transactions of Motor claims.
           Claims only come from IS_CLAIM_MASTER (join on GW_HDR_CASEID, PRODUCT = MOTOR).
       ================================================================================== */
    IF OBJECT_ID('tempdb..#TX0') IS NOT NULL DROP TABLE #TX0;
    SELECT
            PT.ID                                              AS TranID
          , PT.CASEID                                          AS CaseID
          , CLM.GW_HDR_CASEID                                  AS GW_HDR_CASEID
          , CLM.CLAIM_REF                                      AS CLAIM_REF
          , CLM.PUBLICID                                       AS ClaimPublicID
          , UPPER(LTRIM(RTRIM(PT.DEBIT_CREDIT)))               AS DC
          /* mapping: VEC_GW_PAY_DISS.AMOUNT is DOUBLE; money is kept as DECIMAL(18,2), rounded to pennies */
          , CONVERT(DECIMAL(18,2), ROUND(CONVERT(FLOAT, PT.AMOUNT), 2)) AS HdrAmount
          , LTRIM(RTRIM(PT.PAY_TYPE))                          AS PayType
          , PT.PAYEE_NAME                                      AS PayeeName
          , PT.ACCOUNT_NUMBER                                  AS AccountNumber
          , PT.SORT_CODE                                       AS SortCode
          , PT.CASH_MOVE_NO                                    AS CashMoveNo
          , LTRIM(RTRIM(PT.GROUPED))                           AS Grouped
          , PT.CHEQUE_NUMBER                                   AS ChequeNumber
          , NULLIF(TRY_CONVERT(BIGINT, PT.PAYEE_LINKID), 0)    AS PayeeLinkKey
          , NULLIF(TRY_CONVERT(BIGINT, PT.ADD_LINKID), 0)      AS AddLinkKey
          , PT.POST_CODE                                       AS PostCode
          , PT.ADDRESS_LINE1                                   AS AddressLine1
          , PT.ADDRESS_LINE2                                   AS AddressLine2
          , PT.ADDRESS_LINE3                                   AS AddressLine3
          , PT.GW_PAY_GATEID                                   AS GatewayID
    INTO #TX0
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
            ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
    WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR';
    CREATE UNIQUE CLUSTERED INDEX IX_TX0 ON #TX0 (TranID);

    /* ==================================================================================
       S2. Case type of PAY_TRANS.CASEID
           HDR = the payment sits on the claim itself (CASEID = GW_HDR_CASEID)
           AD / TP / PA = the case id is a row of VEC_GW_MOTOR_AD / VEC_GW_MOTOR_TP / VEC_PA_ANCILLARY
           The case must belong to the same claim, so an id can never match another claim's case.
       ================================================================================== */
    IF OBJECT_ID('tempdb..#TX') IS NOT NULL DROP TABLE #TX;
    SELECT
            T.*
          , CASE
                WHEN T.CaseID = T.GW_HDR_CASEID THEN 'HDR'
                WHEN AD.ID IS NOT NULL          THEN 'AD'
                WHEN TP.ID IS NOT NULL          THEN 'TP'
                WHEN PA.ID IS NOT NULL          THEN 'PA'
                ELSE 'UNKNOWN'
            END AS CaseType
    INTO #TX
    FROM #TX0 T
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD
           ON AD.ID = T.CaseID AND AD.GW_HDR_CASEID = T.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP
           ON TP.ID = T.CaseID AND TP.GW_HDR_CASEID = T.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY PA
           ON PA.ID = T.CaseID AND PA.GW_HDR_CASEID = T.GW_HDR_CASEID;
    CREATE UNIQUE CLUSTERED INDEX IX_TX ON #TX (TranID);
    DROP TABLE #TX0;

    /* live case status of the case the money sits on (information only, same source as the reserve procs) */
    IF OBJECT_ID('tempdb..#CS') IS NOT NULL DROP TABLE #CS;
    SELECT
            C.CaseID                              AS CaseID
          , MAX(LTRIM(RTRIM(CS.STATUS)))          AS CASE_STATUS
    INTO #CS
    FROM (SELECT DISTINCT CaseID FROM #TX) C
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS
           ON CS.CASEID = C.CaseID AND CS.GCURRENT = 'X'
    GROUP BY C.CaseID;
    CREATE UNIQUE CLUSTERED INDEX IX_CS ON #CS (CaseID);

    /* ==================================================================================
       S3. Dissections. One row per dissection = one line item.
           A transaction without any dissection row keeps one line with the header AMOUNT.
           CodeKey: NULL / blank / 'NULL' / '<NULL>' all mean "no code" and match the lookup NULL row.
       ================================================================================== */
    IF OBJECT_ID('tempdb..#LINE0') IS NOT NULL DROP TABLE #LINE0;
    SELECT
            T.TranID                                                         AS TranID
          , ROW_NUMBER() OVER (PARTITION BY T.TranID ORDER BY D.CODE, D.AMOUNT) AS LineSeq
          , T.CaseType                                                       AS CaseType
          , T.DC                                                             AS DC
          , CASE WHEN D.CODE IS NULL OR UPPER(LTRIM(RTRIM(D.CODE))) IN ('', 'NULL', '<NULL>')
                 THEN NULL ELSE UPPER(LTRIM(RTRIM(D.CODE))) END              AS DissCode
          , CASE WHEN D.CODE IS NULL OR UPPER(LTRIM(RTRIM(D.CODE))) IN ('', 'NULL', '<NULL>')
                 THEN '~NULL~' ELSE UPPER(LTRIM(RTRIM(D.CODE))) END          AS CodeKey
          , CASE WHEN D.GW_PAY_TRAN_ID IS NULL THEN T.HdrAmount ELSE CONVERT(DECIMAL(18,2), ROUND(CONVERT(FLOAT, D.AMOUNT), 2)) END AS Amount
    INTO #LINE0
    FROM #TX T
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D
           ON D.GW_PAY_TRAN_ID = T.TranID;
    CREATE UNIQUE CLUSTERED INDEX IX_LINE0 ON #LINE0 (TranID, LineSeq);

    /* ==================================================================================
       S4. Cost type per dissection.
           DEBIT  : Lkp_Transaction_Typelist (motor rows, D). Specific row beats general row:
                      TP case  : V2_CASE 'GW_MOTOR_TP'  (Hire & Mobility codes)  >  'All'
                      other    : 'All cases apart from GW_MOTOR_TP'               >  'All'
           CREDIT : every credit is Recovery / claimcost / Migrated Recovery / Subrogation
                    (lookup row "ALL dissection codes", general note 2). The credit rows of the
                    lookup are NOT read, so deleting them (senior's remark) changes nothing.
       ================================================================================== */
    IF OBJECT_ID('tempdb..#LKP') IS NOT NULL DROP TABLE #LKP;
    SELECT
            CASE WHEN K.DISSECTION_CODE IS NULL OR UPPER(LTRIM(RTRIM(K.DISSECTION_CODE))) IN ('', 'NULL', '<NULL>')
                 THEN '~NULL~' ELSE UPPER(LTRIM(RTRIM(K.DISSECTION_CODE))) END AS CodeKey
          , CASE
                WHEN UPPER(REPLACE(LTRIM(RTRIM(K.V2_CASE)), ' ', '_')) = 'GW_MOTOR_TP'             THEN 'TP'
                WHEN UPPER(REPLACE(LTRIM(RTRIM(K.V2_CASE)), ' ', '_')) LIKE 'ALL_CASES_APART%'      THEN 'NONTP'
                ELSE 'ALL'
            END AS VScope
          , LOWER(LTRIM(RTRIM(K.CostTypeCode)))                                   AS CostTypeCode
          , CASE WHEN UPPER(LTRIM(RTRIM(K.Exposure))) LIKE 'HIRE%' THEN 1 ELSE 0 END AS IsHire
          , LTRIM(RTRIM(K.LineItem))                                              AS LineItem
    INTO #LKP
    FROM SourceStaging.dbo.Lkp_Transaction_Typelist K
    WHERE LOWER(LTRIM(RTRIM(K.LOB))) = 'motor'
      AND UPPER(LTRIM(RTRIM(K.DEBIT_CREDIT))) = 'D';
    CREATE CLUSTERED INDEX IX_LKP ON #LKP (CodeKey);

    IF OBJECT_ID('tempdb..#LINE') IS NOT NULL DROP TABLE #LINE;
    ;WITH M AS
    (
        SELECT
                L.TranID AS TranID
              , L.LineSeq AS LineSeq
              , K.CostTypeCode AS CostTypeCode
              , K.IsHire AS IsHire
              , K.LineItem AS LineItem
              , ROW_NUMBER() OVER (PARTITION BY L.TranID, L.LineSeq
                                   ORDER BY CASE K.VScope WHEN 'TP' THEN 1 WHEN 'NONTP' THEN 1 ELSE 2 END, K.CostTypeCode) AS RN
        FROM #LINE0 L
        INNER JOIN #LKP K
                ON K.CodeKey = L.CodeKey
               AND (   K.VScope = 'ALL'
                    OR (K.VScope = 'TP'    AND L.CaseType  = 'TP')
                    OR (K.VScope = 'NONTP' AND L.CaseType <> 'TP'))
        WHERE L.DC = 'D'
    )
    SELECT
            L.TranID AS TranID
          , L.LineSeq AS LineSeq
          , L.DissCode AS DissCode
          , L.Amount AS Amount
          , CASE WHEN L.DC = 'C' THEN 'claimcost' ELSE M.CostTypeCode END AS CostType
          , CASE WHEN L.DC = 'C' THEN CONVERT(BIT, 0) ELSE CONVERT(BIT, ISNULL(M.IsHire, 0)) END AS IsHire
          , CASE WHEN L.DC = 'C' THEN 'Migrated Recovery' ELSE M.LineItem END AS LineItem
    INTO #LINE
    FROM #LINE0 L
    LEFT JOIN M ON M.TranID = L.TranID AND M.LineSeq = L.LineSeq AND M.RN = 1;
    /* a DEBIT_CREDIT value other than D / C is not filtered out: it keeps CostType NULL and is listed as BAD_DEBIT_CREDIT */
    CREATE UNIQUE CLUSTERED INDEX IX_LINE ON #LINE (TranID, LineSeq);
    DROP TABLE #LINE0;
    DROP TABLE #LKP;

    /* sum of all dissections per V2 transaction, to compare with the header AMOUNT */
    IF OBJECT_ID('tempdb..#TXSUM') IS NOT NULL DROP TABLE #TXSUM;
    SELECT TranID, SUM(Amount) AS DissSum
    INTO #TXSUM
    FROM #LINE
    GROUP BY TranID;
    CREATE UNIQUE CLUSTERED INDEX IX_TXSUM ON #TXSUM (TranID);

    /* ==================================================================================
       S5. Master rows = one ClaimCenter transaction per (V2 transaction, exposure kind, cost type).
           The suffix keeps PublicIDs stable and unique:  '' when there is one master row,
           else _cc / _ex  (+ h for Hire & Mobility).
       ================================================================================== */
    IF OBJECT_ID('tempdb..#MASTER0') IS NOT NULL DROP TABLE #MASTER0;
    SELECT
            L.TranID AS TranID
          , L.CostType AS CostType
          , L.IsHire AS IsHire
          , SUM(L.Amount) AS MasterAmount
          , COUNT(*) OVER (PARTITION BY L.TranID) AS MasterCountInTran
    INTO #MASTER0
    FROM #LINE L
    GROUP BY L.TranID, L.CostType, L.IsHire;
    /* COUNT(*) OVER on a grouped query counts the groups of the transaction */
    CREATE UNIQUE CLUSTERED INDEX IX_MASTER0 ON #MASTER0 (TranID, IsHire, CostType);

    /* ==================================================================================
       S6. Exposure facts (from IS_EXPOSURE_MOTOR, built by the exposure proc)
       ================================================================================== */
    /* TP elements that exist per TP case */
    IF OBJECT_ID('tempdb..#TPFLAG') IS NOT NULL DROP TABLE #TPFLAG;
    SELECT
            E.GW_HDR_CASEID AS GW_HDR_CASEID
          , E.VectusCaseID_Adm AS VectusCaseID_Adm
          , MAX(CASE WHEN E.SourceOrigin_Adm = 'TP_VEH'  THEN 1 ELSE 0 END) AS HasVeh
          , MAX(CASE WHEN E.SourceOrigin_Adm = 'TP_PRO'  THEN 1 ELSE 0 END) AS HasPro
          , MAX(CASE WHEN E.SourceOrigin_Adm = 'TP_INJ'  THEN 1 ELSE 0 END) AS HasInj
          , MAX(CASE WHEN E.SourceOrigin_Adm = 'TP_HIRE' THEN 1 ELSE 0 END) AS HasHire
    INTO #TPFLAG
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
    WHERE E.SourceOrigin_Adm IN ('TP_VEH', 'TP_PRO', 'TP_INJ', 'TP_HIRE')
    GROUP BY E.GW_HDR_CASEID, E.VectusCaseID_Adm;
    CREATE UNIQUE CLUSTERED INDEX IX_TPFLAG ON #TPFLAG (GW_HDR_CASEID, VectusCaseID_Adm);

    /* AD exposures per claim (a claim can have several AD cases, only the surviving one has an exposure) */
    IF OBJECT_ID('tempdb..#ADEXP') IS NOT NULL DROP TABLE #ADEXP;
    SELECT DISTINCT E.GW_HDR_CASEID AS GW_HDR_CASEID, E.VectusCaseID_Adm AS VectusCaseID_Adm
    INTO #ADEXP
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
    WHERE E.SourceOrigin_Adm = 'AD';
    CREATE UNIQUE CLUSTERED INDEX IX_ADEXP ON #ADEXP (GW_HDR_CASEID, VectusCaseID_Adm);

    IF OBJECT_ID('tempdb..#ADCNT') IS NOT NULL DROP TABLE #ADCNT;
    SELECT GW_HDR_CASEID, COUNT(*) AS AdCnt, MIN(VectusCaseID_Adm) AS AdOnly
    INTO #ADCNT
    FROM #ADEXP
    GROUP BY GW_HDR_CASEID;
    CREATE UNIQUE CLUSTERED INDEX IX_ADCNT ON #ADCNT (GW_HDR_CASEID);

    /* ==================================================================================
       S7. Reserve lines (built by the senior's reserve line proc) - candidates per target
       ================================================================================== */
    IF OBJECT_ID('tempdb..#CLAIMS') IS NOT NULL DROP TABLE #CLAIMS;
    SELECT DISTINCT GW_HDR_CASEID INTO #CLAIMS FROM #TX;
    CREATE UNIQUE CLUSTERED INDEX IX_CLAIMS ON #CLAIMS (GW_HDR_CASEID);

    IF OBJECT_ID('tempdb..#RLC') IS NOT NULL DROP TABLE #RLC;
    SELECT
            R.GW_HDR_CASEID                                        AS GW_HDR_CASEID
          , R.SourceOrigin_Adm                                     AS SourceOrigin_Adm
          , R.VectusCaseID_Adm                                     AS VectusCaseID_Adm
          , R.CostType                                             AS CostType
          , CASE WHEN RIGHT(R.PublicID, 4) = '_rec' THEN 1 ELSE 0 END AS IsRec
          , R.PublicID                                             AS ReserveLinePublicID
          , R.ExposureID                                           AS ExposureID
          , R.CostCategory                                         AS CostCategory
            /* TP injury has many lines of the same cost type. The "main" ones are:
               claim cost -> pm_injury_adm  (reserve mapping: "all claimcost transactions will be mapped to this reserve line")
               expense    -> pm_third_party_costs_adm (Third Party Solicitors Costs) - NOT stated by the BA, see exception NO_MAIN_INJ_LINE */
          , CASE
                WHEN R.SourceOrigin_Adm = 'TP_INJ' AND RIGHT(R.PublicID, 4) <> '_rec'
                     AND ( (R.CostType = 'claimcost' AND R.CostCategory = 'pm_injury_adm')
                        OR (R.CostType = 'aoexpense' AND R.CostCategory = 'pm_third_party_costs_adm') ) THEN 0
                WHEN R.SourceOrigin_Adm = 'TP_INJ' AND RIGHT(R.PublicID, 4) <> '_rec'                  THEN 1
                ELSE 0
            END AS Pref
    INTO #RLC
    FROM IntermediateStaging_DEV.dbo.IS_RESERVELINE_MOTOR R
    WHERE EXISTS (SELECT 1 FROM #CLAIMS CL WHERE CL.GW_HDR_CASEID = R.GW_HDR_CASEID);
    CREATE CLUSTERED INDEX IX_RLC ON #RLC (GW_HDR_CASEID, SourceOrigin_Adm, VectusCaseID_Adm, CostType, IsRec);

    IF OBJECT_ID('tempdb..#RLSEL') IS NOT NULL DROP TABLE #RLSEL;
    ;WITH X AS
    (
        SELECT
                C.*
              , ROW_NUMBER() OVER (PARTITION BY C.GW_HDR_CASEID, C.SourceOrigin_Adm, C.VectusCaseID_Adm, C.CostType, C.IsRec
                                   ORDER BY C.Pref, C.ReserveLinePublicID) AS RN
              , COUNT(*)     OVER (PARTITION BY C.GW_HDR_CASEID, C.SourceOrigin_Adm, C.VectusCaseID_Adm, C.CostType, C.IsRec, C.Pref) AS CntInClass
        FROM #RLC C
    )
    SELECT GW_HDR_CASEID, SourceOrigin_Adm, VectusCaseID_Adm, CostType, IsRec
         , ReserveLinePublicID, ExposureID, CostCategory, Pref, CntInClass
    INTO #RLSEL
    FROM X
    WHERE RN = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_RLSEL ON #RLSEL (GW_HDR_CASEID, SourceOrigin_Adm, VectusCaseID_Adm, CostType, IsRec);

    /* the recovery reserve line of a TP case: it sits on ONE exposure, vehicle first (reserve line proc B3 / RecoveryHere) */
    IF OBJECT_ID('tempdb..#RLREC') IS NOT NULL DROP TABLE #RLREC;
    ;WITH Y AS
    (
        SELECT
                S.GW_HDR_CASEID, S.SourceOrigin_Adm, S.VectusCaseID_Adm
              , ROW_NUMBER() OVER (PARTITION BY S.GW_HDR_CASEID, S.VectusCaseID_Adm
                                   ORDER BY CASE S.SourceOrigin_Adm WHEN 'TP_VEH' THEN 1 WHEN 'TP_PRO' THEN 2 ELSE 3 END) AS RN
        FROM #RLSEL S
        WHERE S.IsRec = 1 AND S.CostType = 'claimcost'
          AND S.SourceOrigin_Adm IN ('TP_VEH', 'TP_PRO', 'TP_INJ')   /* never on Hire & Mobility (reserve line proc) */
    )
    SELECT GW_HDR_CASEID, VectusCaseID_Adm, SourceOrigin_Adm
    INTO #RLREC
    FROM Y
    WHERE RN = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_RLREC ON #RLREC (GW_HDR_CASEID, VectusCaseID_Adm);

    /* ==================================================================================
       S8. Pay status history
       ================================================================================== */
    IF OBJECT_ID('tempdb..#STAT') IS NOT NULL DROP TABLE #STAT;
    SELECT
            S.GW_PAY_TRAN_ID                                          AS TranID
          , S.ID                                                      AS StatusID
          , UPPER(LTRIM(RTRIM(S.STATUS_TYPE)))                        AS StatusType
          , LTRIM(RTRIM(S.REASON))                                    AS Reason
          , S.GCURRENT                                                AS GCurrent
          /* a NULL date or time must stay NULL: CONVERT of a blank string would silently give 1900-01-01 */
          , CASE WHEN S.RECORD_DATE IS NULL OR S.RECORD_TIME IS NULL THEN NULL
                 ELSE TRY_CONVERT(DATETIME2(7), CONCAT(S.RECORD_DATE, ' ', S.RECORD_TIME)) END AS Dt
    INTO #STAT
    FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S
    INNER JOIN #TX T ON T.TranID = S.GW_PAY_TRAN_ID;
    CREATE CLUSTERED INDEX IX_STAT ON #STAT (TranID, StatusID);

    IF OBJECT_ID('tempdb..#STD') IS NOT NULL DROP TABLE #STD;
    ;WITH R AS
    (
        SELECT
                S.*
              , ROW_NUMBER() OVER (PARTITION BY S.TranID ORDER BY S.StatusID ASC)  AS RnFirst
              , CASE WHEN S.GCurrent = 'X'
                     THEN ROW_NUMBER() OVER (PARTITION BY S.TranID, CASE WHEN S.GCurrent = 'X' THEN 1 ELSE 0 END ORDER BY S.StatusID DESC) END AS RnCur
              , CASE WHEN S.StatusType IN ('AUTH', 'GRP_AUTH')
                     THEN ROW_NUMBER() OVER (PARTITION BY S.TranID, CASE WHEN S.StatusType IN ('AUTH', 'GRP_AUTH') THEN 1 ELSE 0 END ORDER BY S.StatusID DESC) END AS RnAuth
              , CASE WHEN S.StatusType = 'PRESENTED'
                     THEN ROW_NUMBER() OVER (PARTITION BY S.TranID, CASE WHEN S.StatusType = 'PRESENTED' THEN 1 ELSE 0 END ORDER BY S.StatusID DESC) END AS RnPres
              , CASE WHEN S.StatusType = 'PAID'
                     THEN ROW_NUMBER() OVER (PARTITION BY S.TranID, CASE WHEN S.StatusType = 'PAID' THEN 1 ELSE 0 END ORDER BY S.StatusID DESC) END AS RnPaid
              , CASE WHEN S.StatusType = 'CANX'
                     THEN ROW_NUMBER() OVER (PARTITION BY S.TranID, CASE WHEN S.StatusType = 'CANX' THEN 1 ELSE 0 END ORDER BY S.StatusID DESC) END AS RnCanx
        FROM #STAT S
    )
    SELECT
            R.TranID AS TranID
          , MAX(CASE WHEN R.RnFirst = 1 THEN R.Dt END)         AS FirstDt
          , MAX(CASE WHEN R.RnCur   = 1 THEN R.StatusType END) AS CurrentStatusType
          , MAX(CASE WHEN R.RnAuth  = 1 THEN R.Dt END)         AS AuthDt
          , MAX(CASE WHEN R.RnPres  = 1 THEN R.Dt END)         AS PresentedDt
          , MAX(CASE WHEN R.RnPaid  = 1 THEN R.Dt END)         AS PaidDt
          , MAX(CASE WHEN R.RnCanx  = 1 THEN R.Dt END)         AS CanxDt
          , MAX(CASE WHEN R.RnCanx  = 1 THEN R.Reason END)     AS CanxReason
    INTO #STD
    FROM R
    GROUP BY R.TranID;
    CREATE UNIQUE CLUSTERED INDEX IX_STD ON #STD (TranID);
    DROP TABLE #STAT;

    /* ==================================================================================
       S9. Typelists (SourceStaging.dbo.TYPELIST_TABLE_MAPPING).
           Columns: Vectus_TypeCode (the V2 value), Typelist_Name, GW_TypeCode (the ClaimCenter typecode we load),
                    Name, [Household/Motor/Both].
           [Household/Motor/Both] is 'Motor only', 'Household only', 'Both' or NULL. In the real data the PaymentMethod and
           ReasonToStopCheque_Adm rows have NULL here, so NULL rows are accepted (they are not marked Household only).
           'Household only' rows are never used. If one V2 value has several rows, Motor only beats Both beats NULL.
           The status typelists are keyed by the V2 status (AUTH, GRP_AUTH, PAID ...), confirmed by the sample rows.
       ================================================================================== */
    IF OBJECT_ID('tempdb..#TL') IS NOT NULL DROP TABLE #TL;
    ;WITH Z AS
    (
        SELECT
                LTRIM(RTRIM(TL.Typelist_Name))   AS TL_Name
              , LTRIM(RTRIM(TL.Vectus_TypeCode)) AS VCode
              , LTRIM(RTRIM(TL.GW_TypeCode))     AS GWCode
              , ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(TL.Typelist_Name)), LTRIM(RTRIM(TL.Vectus_TypeCode))
                                   ORDER BY CASE TL.[Household/Motor/Both] WHEN 'Motor only' THEN 0 WHEN 'Both' THEN 1 ELSE 2 END) AS RN
        FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
        WHERE LTRIM(RTRIM(TL.Typelist_Name)) IN ('TransactionStatus', 'TransactionLifeCycleState', 'ApprovalStatus',
                                                  'PaymentMethod', 'ReasonToStopCheque_Adm')
          AND TL.Vectus_TypeCode IS NOT NULL
          AND (TL.[Household/Motor/Both] IS NULL OR TL.[Household/Motor/Both] IN ('Motor only', 'Both'))
    )
    SELECT TL_Name, VCode, GWCode
    INTO #TL
    FROM Z
    WHERE RN = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_TL ON #TL (TL_Name, VCode);

    /* ----------------------------------------------------------------------------------
       S9b. Typelists whose typecode is fixed by the mapping (primary, gbp, partial ...).
            In the typelist table these rows have no Vectus code: the table is the list of valid ClaimCenter codes.
            #TLV holds that list (Motor / Both / NULL rows). Every code the procs 02-06 write is checked against it
            here, and the LineCategory typecode of each line is taken from it. A missing code is reported with a
            warning message (severity 10, the run continues) - see also query V9 in file 08.
       ---------------------------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#TLV') IS NOT NULL DROP TABLE #TLV;
    SELECT DISTINCT
            LTRIM(RTRIM(TL.Typelist_Name)) AS TL_Name
          , LTRIM(RTRIM(TL.GW_TypeCode))   AS GWCode
          , LTRIM(RTRIM(TL.Name))          AS TLName
    INTO #TLV
    FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
    WHERE LTRIM(RTRIM(TL.Typelist_Name)) IN ('CheckBatching', 'CheckType', 'RecoveryCategory', 'Currency',
                                             'PaymentType', 'CreatedVia', 'Transaction', 'TransactionSet', 'CostType', 'LineCategory')
      AND (TL.[Household/Motor/Both] IS NULL OR TL.[Household/Motor/Both] IN ('Motor only', 'Both'));
    CREATE CLUSTERED INDEX IX_TLV ON #TLV (TL_Name, GWCode);

    DECLARE @FxMissing NVARCHAR(2000) = N'';
    ;WITH F (TL_Name, GWCode) AS
    (
        SELECT * FROM (VALUES
              ('CheckBatching', 'apdefault'), ('CheckBatching', 'bulkcheck')
            , ('CheckType', 'primary')
            , ('RecoveryCategory', 'subro')
            , ('Currency', 'gbp')
            , ('PaymentType', 'partial')
            , ('CreatedVia', 'manual')
            , ('Transaction', 'Payment'), ('Transaction', 'Recovery')
            , ('TransactionSet', 'CheckSet'), ('TransactionSet', 'RecoverySet')
            , ('CostType', 'claimcost'), ('CostType', 'aoexpense')
        ) V (TL_Name, GWCode)
    )
    SELECT @FxMissing = @FxMissing + F.TL_Name + '=' + F.GWCode + '; '
    FROM F
    WHERE NOT EXISTS (SELECT 1 FROM #TLV V WHERE V.TL_Name = F.TL_Name AND V.GWCode = F.GWCode);
    IF @FxMissing <> N''
        RAISERROR('WARNING usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR: these typecodes are NOT in TYPELIST_TABLE_MAPPING: %s', 10, 1, @FxMissing) WITH NOWAIT;
    IF NOT EXISTS (SELECT 1 FROM #TLV WHERE TL_Name = 'LineCategory' AND (GWCode = 'Migrated Payment' OR TLName = 'Migrated Payment'))
       OR NOT EXISTS (SELECT 1 FROM #TLV WHERE TL_Name = 'LineCategory' AND (GWCode = 'Migrated Recovery' OR TLName = 'Migrated Recovery'))
        RAISERROR('WARNING usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR: LineCategory typelist has no row for Migrated Payment and/or Migrated Recovery (code or Name). LineCategory will be NULL.', 10, 1) WITH NOWAIT;

    /* ==================================================================================
       S10. Payee and in-care-of person.
            WHY THE CONTACT RECORD (and not LINK_ID) IS USED:
              VEC_GW_PAY_TRANS.PAYEE_LINKID / ADD_LINKID hold a LINK id (VEC_GW_CF_LINK.ID).
              CONTACT_MASTER_MOTOR keeps only ONE link per contact record (the MAX LINK_ID), so the
              older link of a payment is usually NOT in the contact master. But every link of the same
              person has the same CONTACT RECORD id: VEC_GW_CF_LINK.GWCF_HDRID = VEC_GW_CF_HDR.ID = HDR_ID.
              Route:  PAYEE_LINKID -> VEC_GW_CF_LINK.ID -> GWCF_HDRID (= HDR_ID)
                      -> CONTACT_MASTER_MOTOR (HDR_ID, same claim) -> IS_CLAIMCONTACT (ContactID, ClaimID).
            Resolution of the payee (PayeeResolution, debits only):
              NO_PAYEE_LINK              PAYEE_LINKID is NULL / 0 / not a number            -> dummy payee (BA)
              LINK_NOT_IN_CF_LINK        PAYEE_LINKID is not in VEC_GW_CF_LINK              -> dummy payee (BA)
              LINK_NO_HDR                link found, but GWCF_HDRID is empty                -> ERROR (BA decision open)
              HDR_NOT_IN_CONTACT_MASTER  the contact record has no row in CONTACT_MASTER_MOTOR -> ERROR (BA decision open)
              CONTACT_ON_OTHER_CLAIM     the contact record exists only on another claim    -> ERROR (BA decision open)
              NO_CLAIMCONTACT            contact found, but no IS_CLAIMCONTACT row for this claim -> ERROR (load-order defect)
              OK                         payee contact and claim contact found
            Dummy payees are built by usp_Load_SS_to_IS_PAYEE_DUMMY_MOTOR (PublicIDs below are the contract):
              contact 'mig:motorpayee_'+TranID, claim contact 'mig:motorpayeecc_'+TranID, address 'mig:motorpayeeadr_'+TranID.
       ================================================================================== */
    IF OBJECT_ID('tempdb..#PAYLINK') IS NOT NULL DROP TABLE #PAYLINK;
    SELECT DISTINCT K.GW_HDR_CASEID, K.LinkKey
    INTO #PAYLINK
    FROM (SELECT GW_HDR_CASEID, PayeeLinkKey AS LinkKey FROM #TX WHERE DC = 'D' AND PayeeLinkKey IS NOT NULL
          UNION
          SELECT GW_HDR_CASEID, AddLinkKey   AS LinkKey FROM #TX WHERE DC = 'D' AND AddLinkKey   IS NOT NULL) K;

    /* link -> contact record (HDR_ID) */
    IF OBJECT_ID('tempdb..#PAYHDR') IS NOT NULL DROP TABLE #PAYHDR;
    SELECT
            P.GW_HDR_CASEID AS GW_HDR_CASEID
          , P.LinkKey       AS LinkKey
          , CASE WHEN MAX(L.ID) IS NULL THEN 0 ELSE 1 END AS LinkFound
          , MAX(TRY_CONVERT(BIGINT, L.GWCF_HDRID)) AS HdrID
    INTO #PAYHDR
    FROM #PAYLINK P
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK L ON L.ID = P.LinkKey
    GROUP BY P.GW_HDR_CASEID, P.LinkKey;
    CREATE UNIQUE CLUSTERED INDEX IX_PAYHDR ON #PAYHDR (GW_HDR_CASEID, LinkKey);

    /* contact record -> contact master row of the SAME claim (CONTACT_MASTER_MOTOR has one row per HDR_ID) */
    IF OBJECT_ID('tempdb..#PAYCON') IS NOT NULL DROP TABLE #PAYCON;
    SELECT
            H.GW_HDR_CASEID AS GW_HDR_CASEID
          , H.LinkKey       AS LinkKey
          , H.LinkFound     AS LinkFound
          , H.HdrID         AS HdrID
          , COUNT(CM.PublicID) AS AnyCmRows
          , MIN(CASE WHEN CM.GW_HDR_CASEID = H.GW_HDR_CASEID THEN CM.PublicID END) AS ContactPublicID
          , COUNT(DISTINCT CASE WHEN CM.GW_HDR_CASEID = H.GW_HDR_CASEID THEN CM.PublicID END) AS ContactCnt
    INTO #PAYCON
    FROM #PAYHDR H
    LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.HDR_ID = H.HdrID
    GROUP BY H.GW_HDR_CASEID, H.LinkKey, H.LinkFound, H.HdrID;
    CREATE UNIQUE CLUSTERED INDEX IX_PAYCON ON #PAYCON (GW_HDR_CASEID, LinkKey);

    /* contact -> claim contact of this claim */
    IF OBJECT_ID('tempdb..#PAYCC') IS NOT NULL DROP TABLE #PAYCC;
    SELECT
            C0.GW_HDR_CASEID AS GW_HDR_CASEID
          , C0.LinkKey AS LinkKey
          , C0.LinkFound AS LinkFound
          , C0.HdrID AS HdrID
          , C0.AnyCmRows AS AnyCmRows
          , C0.ContactPublicID AS ContactPublicID
          , C0.ContactCnt AS ContactCnt
          , MIN(CC.PublicID) AS ClaimContactPublicID
    INTO #PAYCC
    FROM #PAYCON C0
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
           ON CLM.GW_HDR_CASEID = C0.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC
           ON CC.ContactID = C0.ContactPublicID AND CC.ClaimID = CLM.PUBLICID
    GROUP BY C0.GW_HDR_CASEID, C0.LinkKey, C0.LinkFound, C0.HdrID, C0.AnyCmRows, C0.ContactPublicID, C0.ContactCnt;
    CREATE UNIQUE CLUSTERED INDEX IX_PAYCC ON #PAYCC (GW_HDR_CASEID, LinkKey);

    /* ==================================================================================
       S11. Final master rows + exception logic
       ================================================================================== */
    IF OBJECT_ID('tempdb..#U') IS NOT NULL DROP TABLE #U;
    ;WITH B AS
    (
        SELECT
                T.TranID AS TranID
              , U.CostType AS CostType
              , U.IsHire AS IsHire
              , U.MasterAmount AS MasterAmount
              , U.MasterCountInTran AS MasterCountInTran
              , CASE WHEN U.MasterCountInTran = 1 THEN ''
                     ELSE '_' + CASE U.CostType WHEN 'claimcost' THEN 'cc' WHEN 'aoexpense' THEN 'ex' ELSE 'xx' END
                              + CASE WHEN U.IsHire = 1 THEN 'h' ELSE '' END END AS MasterSuffix
              , T.GW_HDR_CASEID AS GW_HDR_CASEID
              , T.CLAIM_REF AS CLAIM_REF
              , T.ClaimPublicID AS ClaimPublicID
              , T.CaseID AS CaseID
              , T.CaseType AS CaseType
              , CS.CASE_STATUS AS CASE_STATUS
              , T.DC AS DC
              , T.PayType AS PayType
              , T.HdrAmount AS HdrAmount
              , SM.DissSum AS DissSum
              , T.PayeeName, T.AccountNumber, T.SortCode, T.CashMoveNo, T.Grouped, T.ChequeNumber
              , T.PostCode, T.AddressLine1, T.AddressLine2, T.AddressLine3
              , T.PayeeLinkKey, T.AddLinkKey
              /* ---- target case / origin ---- */
              , CASE
                    WHEN T.CaseType = 'HDR' THEN CONVERT(VARCHAR(64), T.GW_HDR_CASEID)
                    WHEN T.CaseType = 'AD'  THEN CASE WHEN AX.VectusCaseID_Adm IS NOT NULL THEN CONVERT(VARCHAR(64), T.CaseID) WHEN AC.AdCnt = 1 THEN AC.AdOnly END
                    ELSE CONVERT(VARCHAR(64), T.CaseID)
                END AS TargetCase
              , CASE WHEN T.CaseType = 'AD' AND AX.VectusCaseID_Adm IS NULL AND AC.AdCnt = 1 THEN 1 ELSE 0 END AS AdRemapped
              , CASE WHEN T.CaseType = 'AD' AND AX.VectusCaseID_Adm IS NULL AND ISNULL(AC.AdCnt, 0) > 1 THEN 1 ELSE 0 END AS AdAmbiguous
              , CASE
                    WHEN T.CaseType = 'HDR' THEN 'HDR'
                    WHEN T.CaseType = 'AD'  THEN 'AD'
                    WHEN T.CaseType = 'PA'  THEN 'PA'
                    WHEN T.CaseType = 'TP' AND T.DC = 'D' AND U.IsHire = 1 THEN CASE WHEN TF.HasHire = 1 THEN 'TP_HIRE' END
                    WHEN T.CaseType = 'TP' AND T.DC = 'D'
                         THEN CASE WHEN TF.HasVeh = 1 THEN 'TP_VEH' WHEN TF.HasPro = 1 THEN 'TP_PRO' WHEN TF.HasInj = 1 THEN 'TP_INJ' END
                    WHEN T.CaseType = 'TP' AND T.DC = 'C' THEN RR.SourceOrigin_Adm
                END AS TargetOrigin
              , CASE WHEN T.CaseType = 'TP' AND T.DC = 'D' AND U.IsHire = 0 AND TF.HasVeh = 1 AND TF.HasPro = 1 AND TF.HasInj = 1 THEN 1 ELSE 0 END AS TpAllThree
              /* ---- status ---- */
              , SD.CurrentStatusType AS CurrentStatusType
              , SD.FirstDt AS FirstDt
              , SD.AuthDt AS AuthDt
              , SD.PresentedDt AS PresentedDt
              , SD.PaidDt AS PaidDt
              , SD.CanxDt AS CanxDt
              , SD.CanxReason AS CanxReason
              /* ---- payee ---- */
              , PY.ContactPublicID AS PayeeContactPublicID
              , PY.ClaimContactPublicID AS PayeeClaimContactPublicID
              , PY.HdrID AS PayeeHdrID
              , IC.ContactPublicID AS InCareOfPublicID
              , IC.HdrID AS InCareOfHdrID
              , CASE WHEN T.DC <> 'D'                                   THEN NULL
                     WHEN T.PayeeLinkKey IS NULL                        THEN 'NO_PAYEE_LINK'
                     WHEN ISNULL(PY.LinkFound, 0) = 0                   THEN 'LINK_NOT_IN_CF_LINK'
                     WHEN PY.HdrID IS NULL                              THEN 'LINK_NO_HDR'
                     WHEN PY.AnyCmRows = 0                              THEN 'HDR_NOT_IN_CONTACT_MASTER'
                     WHEN PY.ContactPublicID IS NULL                    THEN 'CONTACT_ON_OTHER_CLAIM'
                     WHEN PY.ClaimContactPublicID IS NULL               THEN 'NO_CLAIMCONTACT'
                     ELSE 'OK' END AS PayeeResolution
              /* TRANS_REF is CHAR(16): trailing blanks are trimmed (user decision) */
              , LTRIM(RTRIM(G.TRANS_REF)) AS GatewayRef
        FROM #MASTER0 U
        INNER JOIN #TX T        ON T.TranID = U.TranID
        LEFT  JOIN #TXSUM SM    ON SM.TranID = U.TranID
        LEFT  JOIN #CS CS       ON CS.CaseID = T.CaseID
        LEFT  JOIN #ADEXP AX    ON AX.GW_HDR_CASEID = T.GW_HDR_CASEID AND AX.VectusCaseID_Adm = CONVERT(VARCHAR(64), T.CaseID) AND T.CaseType = 'AD'
        LEFT  JOIN #ADCNT AC    ON AC.GW_HDR_CASEID = T.GW_HDR_CASEID AND T.CaseType = 'AD'
        LEFT  JOIN #TPFLAG TF   ON TF.GW_HDR_CASEID = T.GW_HDR_CASEID AND TF.VectusCaseID_Adm = CONVERT(VARCHAR(64), T.CaseID) AND T.CaseType = 'TP'
        LEFT  JOIN #RLREC RR    ON RR.GW_HDR_CASEID = T.GW_HDR_CASEID AND RR.VectusCaseID_Adm = CONVERT(VARCHAR(64), T.CaseID) AND T.CaseType = 'TP' AND T.DC = 'C'
        LEFT  JOIN #STD SD      ON SD.TranID = T.TranID
        LEFT  JOIN #PAYCC PY    ON PY.GW_HDR_CASEID = T.GW_HDR_CASEID AND PY.LinkKey = T.PayeeLinkKey AND T.DC = 'D'
        LEFT  JOIN #PAYCC IC    ON IC.GW_HDR_CASEID = T.GW_HDR_CASEID AND IC.LinkKey = T.AddLinkKey   AND T.DC = 'D'
        LEFT  JOIN SourceStaging.VECCASRN.VEC_GW_PAY_GATEWAY G ON G.ID = T.GatewayID
    ),
    C AS
    (
        SELECT
                B.*
                /* TP injury debit: if the "main" injury line does not exist, no other line is guessed: ReserveLineID stays NULL (flag NO_MAIN_INJ_LINE) */
              , CASE WHEN B.TargetOrigin = 'TP_INJ' AND B.DC = 'D' AND RS.Pref <> 0 THEN NULL ELSE RS.ReserveLinePublicID END AS ReserveLineID
              , RS.ExposureID AS ExposureID
              , CASE WHEN B.TargetOrigin = 'TP_INJ' AND B.DC = 'D' AND RS.Pref <> 0 THEN NULL ELSE RS.CostCategory END AS CostCategory
              , RS.Pref AS RlPref
              , RS.CntInClass AS RlCnt
              , RS.ReserveLinePublicID AS RlFound
              , RC.PublicID AS RecoveryCodingID
              , CASE WHEN B.PayeeResolution IN ('NO_PAYEE_LINK', 'LINK_NOT_IN_CF_LINK') THEN 1 ELSE 0 END AS IsDummy
              /* typelist results */
              , ST.GWCode AS StatusCode
              , LC2.GWCode AS LifeCycleCode
              , AP2.GWCode AS ApprovalCode
              , PM.GWCode AS PaymentMethodCode
              , RZ.GWCode AS StopReasonCode
        FROM B
        LEFT JOIN #RLSEL RS
               ON RS.GW_HDR_CASEID    = B.GW_HDR_CASEID
              AND RS.SourceOrigin_Adm = B.TargetOrigin
              AND RS.VectusCaseID_Adm = B.TargetCase
              AND RS.CostType         = B.CostType
              AND RS.IsRec            = CASE WHEN B.DC = 'C' THEN 1 ELSE 0 END
        LEFT JOIN IntermediateStaging_DEV.dbo.IS_RECOVERYCODING_MOTOR RC
               ON RC.ReserveLineID = RS.ReserveLinePublicID AND B.DC = 'C'
        LEFT JOIN #TL ST  ON ST.TL_Name  = 'TransactionStatus'        AND ST.VCode  = B.CurrentStatusType
        LEFT JOIN #TL LC2 ON LC2.TL_Name = 'TransactionLifeCycleState' AND LC2.VCode = B.CurrentStatusType
        LEFT JOIN #TL AP2 ON AP2.TL_Name = 'ApprovalStatus'            AND AP2.VCode = B.CurrentStatusType
        LEFT JOIN #TL PM  ON PM.TL_Name  = 'PaymentMethod'             AND PM.VCode  = B.PayType
        LEFT JOIN #TL RZ  ON RZ.TL_Name  = 'ReasonToStopCheque_Adm'    AND RZ.VCode  = LTRIM(RTRIM(B.CanxReason))
    )
    SELECT
            C.*
          , CASE
                WHEN C.DC <> 'D' AND C.DC <> 'C'                              THEN 'BAD_DEBIT_CREDIT'
                WHEN C.ClaimPublicID IS NULL                                  THEN 'NO_CLAIM_PUBLICID'
                WHEN C.CaseType = 'UNKNOWN'                                   THEN 'CASETYPE_UNKNOWN'
                WHEN C.CaseType = 'PA' AND C.DC = 'C' AND @ExcludePaCredits = 1 THEN 'PA_CREDIT_NOT_MIGRATED'
                WHEN C.CostType IS NULL                                       THEN 'UNMAPPED_DISS_CODE'
                WHEN C.CurrentStatusType IS NULL                              THEN 'NO_CURRENT_STATUS'
                WHEN C.StatusCode IS NULL                                     THEN 'UNMAPPED_STATUS'
                WHEN C.LifeCycleCode IS NULL                                  THEN 'UNMAPPED_LIFECYCLE'
                WHEN C.ApprovalCode IS NULL                                   THEN 'UNMAPPED_APPROVAL_STATUS'
                WHEN C.CaseType = 'AD' AND C.AdAmbiguous = 1                  THEN 'AD_EXPOSURE_AMBIGUOUS'
                WHEN C.TargetCase IS NULL OR C.TargetOrigin IS NULL           THEN CASE WHEN C.DC = 'C' THEN 'NO_RECOVERY_RESERVE_LINE' ELSE 'NO_EXPOSURE_FOR_CASE' END
                WHEN C.RlFound IS NULL                                        THEN CASE WHEN C.DC = 'C' THEN 'NO_RECOVERY_RESERVE_LINE' ELSE 'NO_RESERVE_LINE' END
                WHEN C.TargetOrigin = 'TP_INJ' AND C.DC = 'D' AND C.RlPref <> 0 THEN 'NO_MAIN_INJ_LINE'
                WHEN C.DC = 'C' AND C.RecoveryCodingID IS NULL                THEN 'NO_RECOVERY_CODING'
                WHEN C.DC = 'D' AND C.IsDummy = 1 AND NULLIF(LTRIM(RTRIM(C.PayeeName)), '') IS NULL THEN 'DUMMY_PAYEE_NO_NAME'
                WHEN C.DC = 'D' AND C.PayeeResolution = 'LINK_NO_HDR'                THEN 'PAYEE_LINK_HAS_NO_HDR'
                WHEN C.DC = 'D' AND C.PayeeResolution = 'HDR_NOT_IN_CONTACT_MASTER'  THEN 'PAYEE_NOT_IN_CONTACT_MASTER'
                WHEN C.DC = 'D' AND C.PayeeResolution = 'CONTACT_ON_OTHER_CLAIM'     THEN 'PAYEE_CONTACT_OTHER_CLAIM'
                WHEN C.DC = 'D' AND C.PayeeResolution = 'NO_CLAIMCONTACT'            THEN 'PAYEE_NO_CLAIMCONTACT'
                WHEN C.CurrentStatusType IS NOT NULL AND C.FirstDt IS NULL    THEN 'NO_STATUS_DATE'
            END AS ExceptionCode
          , CONCAT(
                CASE WHEN ABS(ISNULL(C.DissSum, 0) - ISNULL(C.HdrAmount, 0)) > 0.005 THEN 'DISS_SUM_MISMATCH;' END
              , CASE WHEN C.AdRemapped = 1 THEN 'AD_REMAPPED_TO_SURVIVING_CASE;' END
              , CASE WHEN C.TpAllThree = 1 THEN 'TP_VEH_INJ_PRO_RULE_ASSUMED;' END
              , CASE WHEN C.RlFound IS NOT NULL AND C.RlCnt > 1 THEN 'MULTIPLE_RESERVE_LINES;' END
              , CASE WHEN C.DC = 'D' AND C.IsDummy = 1 THEN 'DUMMY_PAYEE;' END
              , CASE WHEN C.DC = 'D' AND C.AddLinkKey IS NOT NULL AND C.InCareOfPublicID IS NULL THEN 'INCAREOF_NOT_FOUND;' END
              , CASE WHEN C.DC = 'D' AND UPPER(ISNULL(C.Grouped, '')) NOT IN ('Y', 'N') THEN 'GROUPED_NOT_Y_OR_N;' END
              , CASE WHEN C.DC = 'D' AND C.PaymentMethodCode IS NULL THEN 'UNMAPPED_PAYMENT_METHOD;' END
              /* CASH_MOVE_NO is VARCHAR in V2 but the ClaimCenter fields are long integers: blank = NULL, text that is not a number = NULL + this warning */
              , CASE WHEN NULLIF(LTRIM(RTRIM(C.CashMoveNo)), '') IS NOT NULL AND TRY_CONVERT(BIGINT, NULLIF(LTRIM(RTRIM(C.CashMoveNo)), '')) IS NULL THEN 'CASHMOVE_NOT_NUMERIC;' END
            ) AS WarnList
    INTO #U
    FROM C;

    /* ==================================================================================
       S12. Write master rows and lines
       ================================================================================== */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR
    (
          TranID, MasterSuffix, GW_HDR_CASEID, CLAIM_REF, ClaimPublicID, CaseID, CaseType, CASE_STATUS
        , VectusCaseID_Adm, SourceOrigin_Adm, DebitCredit, Subtype, CostType, CostCategory, IsHire
        , ExposureID, ReserveLineID, RecoveryCodingID, PayType, IsTransfer
        , CurrentStatusType, Status, LifeCycleState, ApprovalStatus
        , CreateTime, ApprovalDate, PresentedDate, PaidDate, CanxDate, ChequeStopReason
        , CashMoveNo, ChequeNumber, PayeeName, AccountNumber, SortCode, Grouped, PostCode
        , AddressLine1, AddressLine2, AddressLine3, PayeeLinkID, AddLinkID
        , PayeeContactID, PayeeClaimContactID, InCareOfContactID, PayeeHdrID, InCareOfHdrID, PayeeResolution, IsDummyPayee, GatewayRef, PaymentMethod
        , HdrAmount, DissSum, MasterAmount, MasterCountInTran, ExceptionCode, WarnList, Loadable
    )
    SELECT
          U.TranID
        , U.MasterSuffix
        , U.GW_HDR_CASEID
        , U.CLAIM_REF
        , U.ClaimPublicID
        , U.CaseID
        , U.CaseType
        , U.CASE_STATUS
        , U.TargetCase
        , U.TargetOrigin
        , LEFT(U.DC, 1)
        , CASE U.DC WHEN 'D' THEN 'Payment' WHEN 'C' THEN 'Recovery' END
        , U.CostType
        , U.CostCategory
        , U.IsHire
        , U.ExposureID
        , U.ReserveLineID
        , U.RecoveryCodingID
        , U.PayType
        , CASE WHEN U.PayType = 'T' AND U.DC = 'D' THEN 1 ELSE 0 END
        , U.CurrentStatusType
        , U.StatusCode
        , U.LifeCycleCode
        , U.ApprovalCode
          /* CreateTime = BookingDate = first status record */
        , U.FirstDt
          /* ApprovalDate: credits = first record; debits = latest AUTH / GRP_AUTH, else first record */
        , CASE WHEN U.DC = 'C' THEN U.FirstDt ELSE ISNULL(U.AuthDt, U.FirstDt) END
        , U.PresentedDt
        , U.PaidDt
        , U.CanxDt
          /* cheque stop reason only where a CANX record exists; V2 value not in the typelist -> issued_in_error */
        , CASE WHEN U.CanxDt IS NOT NULL THEN ISNULL(U.StopReasonCode, 'issued_in_error') END
        , TRY_CONVERT(BIGINT, NULLIF(LTRIM(RTRIM(U.CashMoveNo)), ''))
        , U.ChequeNumber
        , U.PayeeName
        , U.AccountNumber
        , U.SortCode
        , U.Grouped
        , U.PostCode
        , U.AddressLine1
        , U.AddressLine2
        , U.AddressLine3
        , U.PayeeLinkKey
        , U.AddLinkKey
          /* real payee contact, or the dummy contact of this V2 transaction */
        , CASE WHEN U.DC = 'D' THEN CASE WHEN U.IsDummy = 1 THEN 'mig:motorpayee_' + CONVERT(VARCHAR(20), U.TranID) ELSE U.PayeeContactPublicID END END
          /* real payee claim contact, or the dummy claim contact (BA: payment without a usable payee link) */
        , CASE WHEN U.DC = 'D' THEN CASE WHEN U.IsDummy = 1 THEN 'mig:motorpayeecc_' + CONVERT(VARCHAR(20), U.TranID) ELSE U.PayeeClaimContactPublicID END END
        , U.InCareOfPublicID
        , U.PayeeHdrID
        , U.InCareOfHdrID
        , U.PayeeResolution
        , CASE WHEN U.DC = 'D' AND U.IsDummy = 1 THEN 1 ELSE 0 END
        , U.GatewayRef
        , U.PaymentMethodCode
        , U.HdrAmount
        , U.DissSum
        , U.MasterAmount
        , U.MasterCountInTran
        , U.ExceptionCode
        , U.WarnList
        , CASE WHEN U.ExceptionCode = 'PA_CREDIT_NOT_MIGRATED' THEN 0 ELSE 1 END   /* the only master rows not copied on: PA recoveries (mapping row 136) */
    FROM #U U;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_LINE_MOTOR (TranID, MasterSuffix, LineSeq, DissCode, Amount, LineItem, LineCategoryCode)
    SELECT
          L.TranID
        , U.MasterSuffix
        , L.LineSeq
        , L.DissCode
        , L.Amount
        , L.LineItem
          /* LineCategory typecode from the typelist: lookup text matches GW_TypeCode or Name */
        , LC.GWCode
    FROM #LINE L
    INNER JOIN #U U
            ON U.TranID = L.TranID AND U.IsHire = L.IsHire AND U.CostType = L.CostType
    OUTER APPLY (SELECT TOP (1) V.GWCode FROM #TLV V WHERE V.TL_Name = 'LineCategory' AND (V.GWCode = L.LineItem OR V.TLName = L.LineItem) ORDER BY CASE WHEN V.GWCode = L.LineItem THEN 0 ELSE 1 END) LC;

    /* lines whose cost type could not be resolved (CostType NULL) do not match "=" above - add them separately */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_LINE_MOTOR (TranID, MasterSuffix, LineSeq, DissCode, Amount, LineItem, LineCategoryCode)
    SELECT L.TranID, U.MasterSuffix, L.LineSeq, L.DissCode, L.Amount, L.LineItem, LC.GWCode
    FROM #LINE L
    INNER JOIN #U U
            ON U.TranID = L.TranID AND U.CostType IS NULL
    OUTER APPLY (SELECT TOP (1) V.GWCode FROM #TLV V WHERE V.TL_Name = 'LineCategory' AND (V.GWCode = L.LineItem OR V.TLName = L.LineItem) ORDER BY CASE WHEN V.GWCode = L.LineItem THEN 0 ELSE 1 END) LC
    WHERE L.CostType IS NULL;

    DROP TABLE #TX; DROP TABLE #CS; DROP TABLE #LINE; DROP TABLE #TXSUM; DROP TABLE #MASTER0;
    DROP TABLE #CLAIMS; DROP TABLE #TPFLAG; DROP TABLE #ADEXP; DROP TABLE #ADCNT; DROP TABLE #RLC; DROP TABLE #RLSEL; DROP TABLE #RLREC;
    DROP TABLE #STD; DROP TABLE #TL; DROP TABLE #TLV; DROP TABLE #PAYLINK; DROP TABLE #PAYHDR; DROP TABLE #PAYCON; DROP TABLE #PAYCC; DROP TABLE #U;
END;
GO
