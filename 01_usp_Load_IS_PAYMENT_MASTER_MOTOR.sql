/* =====================================================================================
   01_usp_Load_IS_PAYMENT_MASTER_MOTOR
   Motor payments and recoveries: base proc. One master row per ClaimCenter transaction (TranID + MasterSuffix).
   All other payment procs only read IS_PAYMENT_MASTER_MOTOR and IS_PAYMENT_MASTER_LINE_MOTOR.
   Loadable = 0 only for PA recoveries (mapping row 136). Nothing else is held back; a missing link stays NULL.
   PROD version: no exception logic and no exception columns. ExceptionCode, WarnList, DissSum and MasterCountInTran are not in the PROD table and are not written.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_IS_PAYMENT_MASTER_MOTOR
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ExcludePaCredits BIT = 1;      /* 1 = PA recoveries are not loaded (mapping row 136) */
    DECLARE @AdNoExposureToClaim BIT = 1;   /* 1 = AD payment and AD recovery of a claim without AD exposure go to claim level (BA) */

    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_LINE_MOTOR;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR;

    /* S1. Transactions of Motor claims + case type (HDR = claim level, AD, TP, PA)   [changed: S1 and S2 in one step, text columns are read at the end] */
    SELECT
        PT.ID AS TranID
      , PT.CASEID AS CaseID
      , CLM.GW_HDR_CASEID AS GW_HDR_CASEID
      , CLM.CLAIM_REF AS CLAIM_REF
      , CLM.PUBLICID AS ClaimPublicID
      , UPPER(LTRIM(RTRIM(PT.DEBIT_CREDIT))) AS DC
      , CONVERT(DECIMAL(18,2), ROUND(CONVERT(FLOAT, PT.AMOUNT), 2)) AS HdrAmount
      , LTRIM(RTRIM(PT.PAY_TYPE)) AS PayType
      , NULLIF(PT.PAYEE_LINKID, 0) AS PayeeLinkKey
      , NULLIF(PT.ADD_LINKID, 0) AS AddLinkKey
      , PT.GW_PAY_GATEID AS GatewayID
      , CASE
            WHEN PT.CASEID = CLM.GW_HDR_CASEID THEN 'HDR'
            WHEN AD.ID IS NOT NULL THEN 'AD'
            WHEN TP.ID IS NOT NULL THEN 'TP'
            WHEN PA.ID IS NOT NULL THEN 'PA'
            ELSE 'UNKNOWN'
        END AS CaseType
    INTO #TX
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
            ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD
           ON AD.ID = PT.CASEID AND AD.GW_HDR_CASEID = PT.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP
           ON TP.ID = PT.CASEID AND TP.GW_HDR_CASEID = PT.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY PA
           ON PA.ID = PT.CASEID AND PA.GW_HDR_CASEID = PT.GW_HDR_CASEID
    WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR';
    CREATE UNIQUE CLUSTERED INDEX IX_TX ON #TX (TranID);

    /* live case status of the case (information only) */
    SELECT C.CaseID AS CaseID, MAX(LTRIM(RTRIM(CS.STATUS))) AS CASE_STATUS
    INTO #CS
    FROM (SELECT DISTINCT CaseID FROM #TX) C
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS
           ON CS.CASEID = C.CaseID AND CS.GCURRENT = 'X'
    GROUP BY C.CaseID;
    CREATE UNIQUE CLUSTERED INDEX IX_CS ON #CS (CaseID);

    /* S3. One row per dissection = one line item. No dissection row: one line with the header amount, LineKey = 't' + TranID.
           DissCode NULL / blank / 'NULL' / '<NULL>' = no code. */
    SELECT
        T.TranID AS TranID
      , CASE WHEN D.ID IS NULL THEN 't' + CONVERT(VARCHAR(20), T.TranID) ELSE CONVERT(VARCHAR(20), D.ID) END AS LineKey
      , T.CaseType AS CaseType
      , T.DC AS DC
      , CASE WHEN D.CODE IS NULL OR UPPER(LTRIM(RTRIM(D.CODE))) IN ('', 'NULL', '<NULL>')
             THEN NULL ELSE UPPER(LTRIM(RTRIM(D.CODE))) END AS DissCode
      , CASE WHEN D.GW_PAY_TRAN_ID IS NULL THEN T.HdrAmount
             ELSE CONVERT(DECIMAL(18,2), ROUND(CONVERT(FLOAT, D.AMOUNT), 2)) END AS Amount
    INTO #LINE0
    FROM #TX T
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS D
           ON D.GW_PAY_TRAN_ID = T.TranID;
    CREATE UNIQUE CLUSTERED INDEX IX_LINE0 ON #LINE0 (TranID, LineKey);

    /* S4. Cost type per dissection from Lkp_Transaction_Typelist (motor, D). Credits: always claimcost.
           Rank 1 = TP row on a TP case, or a non-TP row; 2 = 'All'; 3 = TP-only row on a non-TP case (IsHire forced to 0). */
    SELECT
        CASE WHEN K.DISSECTION_CODE IS NULL OR UPPER(LTRIM(RTRIM(K.DISSECTION_CODE))) IN ('', 'NULL', '<NULL>')
             THEN '~NULL~' ELSE UPPER(LTRIM(RTRIM(K.DISSECTION_CODE))) END AS CodeKey
      , CASE
            WHEN UPPER(REPLACE(LTRIM(RTRIM(K.V2_CASE)), ' ', '_')) = 'GW_MOTOR_TP' THEN 'TP'
            WHEN UPPER(REPLACE(LTRIM(RTRIM(K.V2_CASE)), ' ', '_')) LIKE 'ALL_CASES_APART%' THEN 'NONTP'
            ELSE 'ALL'
        END AS VScope
      , LOWER(LTRIM(RTRIM(K.CostTypeCode))) AS CostTypeCode
      , CASE WHEN UPPER(LTRIM(RTRIM(K.Exposure))) LIKE 'HIRE%' THEN 1 ELSE 0 END AS IsHire
    INTO #LKP
    FROM SourceStaging.dbo.Lkp_Transaction_Typelist K
    WHERE LOWER(LTRIM(RTRIM(K.LOB))) = 'motor'
      AND UPPER(LTRIM(RTRIM(K.DEBIT_CREDIT))) = 'D';

    ;WITH CAND AS
    (
     SELECT
        F.IsTPCase AS IsTPCase
      , K.CodeKey AS CodeKey
      , K.CostTypeCode AS CostTypeCode
      , CASE WHEN K.VScope = 'TP' AND F.IsTPCase = 0 THEN 0 ELSE K.IsHire END AS IsHire
      , ROW_NUMBER() OVER (PARTITION BY F.IsTPCase, K.CodeKey
                           ORDER BY CASE WHEN K.VScope = 'TP' AND F.IsTPCase = 1 THEN 1
                                         WHEN K.VScope = 'NONTP' THEN 1
                                         WHEN K.VScope = 'ALL' THEN 2
                                         ELSE 3 END
                                  , K.CostTypeCode) AS RN
     FROM #LKP K
     CROSS JOIN (VALUES (0), (1)) F (IsTPCase)
     WHERE K.VScope = 'ALL'
        OR K.VScope = 'TP'
        OR (K.VScope = 'NONTP' AND F.IsTPCase = 0)
    )
    SELECT IsTPCase, CodeKey, CostTypeCode, IsHire
    INTO #LKPSEL
    FROM CAND
    WHERE RN = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_LKPSEL ON #LKPSEL (IsTPCase, CodeKey);
    DROP TABLE #LKP;

    /* S5. Lines with their master suffix and line category.
           MasterSuffix: _rec (credit), _cost / _exp, _hirecost (Hire and Mobility), otherwise _x / _hx + first 6 letters of the cost type.
           LineCategoryCode: hard coded, mapping row 180. When the BA gives the type codes, change the two texts here only.   [changed] */
    SELECT
        Z.TranID AS TranID
      , Z.LineKey AS LineKey
      , Z.DissCode AS DissCode
      , Z.Amount AS Amount
      , Z.DC AS DC
      , Z.CostType AS CostType
      , Z.IsHire AS IsHire
      , CONVERT(VARCHAR(10),
            CASE WHEN Z.DC = 'C' THEN '_rec'
                 WHEN Z.IsHire = 1 THEN CASE Z.CostType WHEN 'claimcost' THEN '_hirecost' ELSE '_hx' + LEFT(ISNULL(Z.CostType, ''), 6) END
                 ELSE CASE Z.CostType WHEN 'claimcost' THEN '_cost' WHEN 'aoexpense' THEN '_exp' ELSE '_x' + LEFT(ISNULL(Z.CostType, ''), 6) END
            END) AS MasterSuffix
      , CASE Z.DC WHEN 'D' THEN 'Migrated Payment' WHEN 'C' THEN 'Migrated Recovery' END AS LineCategoryCode
    INTO #LINE
    FROM
    (
        SELECT
            L.TranID AS TranID
          , L.LineKey AS LineKey
          , L.DissCode AS DissCode
          , L.Amount AS Amount
          , L.DC AS DC
          , CASE WHEN L.DC = 'C' THEN 'claimcost' ELSE K.CostTypeCode END AS CostType
          , CASE WHEN L.DC = 'C' THEN CONVERT(BIT, 0) ELSE CONVERT(BIT, ISNULL(K.IsHire, 0)) END AS IsHire
        FROM #LINE0 L
        LEFT JOIN #LKPSEL K
               ON L.DC = 'D'
              AND K.IsTPCase = CASE WHEN L.CaseType = 'TP' THEN 1 ELSE 0 END
              AND K.CodeKey = COALESCE(L.DissCode, '~NULL~')
    ) Z;
    CREATE UNIQUE CLUSTERED INDEX IX_LINE ON #LINE (TranID, MasterSuffix, LineKey);
    DROP TABLE #LINE0;
    DROP TABLE #LKPSEL;

    /* Master rows = one ClaimCenter transaction per (V2 transaction, exposure kind, cost type)   [changed: suffix comes from #LINE] */
    SELECT
        L.TranID AS TranID
      , L.MasterSuffix AS MasterSuffix
      , L.CostType AS CostType
      , L.IsHire AS IsHire
      , SUM(L.Amount) AS MasterAmount
    INTO #MASTER0
    FROM #LINE L
    GROUP BY L.TranID, L.MasterSuffix, L.CostType, L.IsHire;
    CREATE UNIQUE CLUSTERED INDEX IX_MASTER0 ON #MASTER0 (TranID, MasterSuffix);

    /* S6. Exposure facts (IS_EXPOSURE_MOTOR) */
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

    /* AD exposures per claim: only the surviving AD case has an exposure */
    SELECT DISTINCT E.GW_HDR_CASEID AS GW_HDR_CASEID, E.VectusCaseID_Adm AS VectusCaseID_Adm
    INTO #ADEXP
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
    WHERE E.SourceOrigin_Adm = 'AD';
    CREATE UNIQUE CLUSTERED INDEX IX_ADEXP ON #ADEXP (GW_HDR_CASEID, VectusCaseID_Adm);

    SELECT GW_HDR_CASEID, COUNT(*) AS AdCnt, MIN(VectusCaseID_Adm) AS AdOnly
    INTO #ADCNT
    FROM #ADEXP
    GROUP BY GW_HDR_CASEID;
    CREATE UNIQUE CLUSTERED INDEX IX_ADCNT ON #ADCNT (GW_HDR_CASEID);

    /* S7. Reserve lines of the claims.  Pref = 0 is the main line (TP injury needs the rule, every other origin has one line per cost type) */
    SELECT DISTINCT GW_HDR_CASEID INTO #CLAIMS FROM #TX;
    CREATE UNIQUE CLUSTERED INDEX IX_CLAIMS ON #CLAIMS (GW_HDR_CASEID);

    SELECT
        R.GW_HDR_CASEID AS GW_HDR_CASEID
      , CONVERT(VARCHAR(20), R.SourceOrigin_Adm) AS SourceOrigin_Adm
      , CONVERT(VARCHAR(64), R.VectusCaseID_Adm) AS VectusCaseID_Adm
      , CONVERT(VARCHAR(20), R.CostType) AS CostType
      , CASE WHEN RIGHT(R.PublicID, 4) = '_rec' THEN 1 ELSE 0 END AS IsRec
      , CONVERT(VARCHAR(128), R.PublicID) AS ReserveLinePublicID
      , R.ExposureID AS ExposureID
      , R.CostCategory AS CostCategory
      , CASE
            WHEN R.SourceOrigin_Adm = 'TP_INJ' AND RIGHT(R.PublicID, 4) <> '_rec'
                 AND ( (R.CostType = 'claimcost' AND R.CostCategory = 'pm_injury_adm')
                    OR (R.CostType = 'aoexpense' AND R.CostCategory = 'pm_third_party_costs_adm') ) THEN 0
            WHEN R.SourceOrigin_Adm = 'TP_INJ' AND RIGHT(R.PublicID, 4) <> '_rec' THEN 1
            ELSE 0
        END AS Pref
    INTO #RLC
    FROM IntermediateStaging_DEV.dbo.IS_RESERVELINE_MOTOR R
    WHERE EXISTS (SELECT 1 FROM #CLAIMS CL WHERE CL.GW_HDR_CASEID = R.GW_HDR_CASEID);
    /* changed: index order = window order of #RLSEL, so no extra sort */
    CREATE CLUSTERED INDEX IX_RLC ON #RLC (GW_HDR_CASEID, SourceOrigin_Adm, VectusCaseID_Adm, CostType, IsRec, Pref, ReserveLinePublicID);

    ;WITH X AS
    (
        SELECT
            C.*
          , ROW_NUMBER() OVER (PARTITION BY C.GW_HDR_CASEID, C.SourceOrigin_Adm, C.VectusCaseID_Adm, C.CostType, C.IsRec
                               ORDER BY C.Pref, C.ReserveLinePublicID) AS RN
          , COUNT(*) OVER (PARTITION BY C.GW_HDR_CASEID, C.SourceOrigin_Adm, C.VectusCaseID_Adm, C.CostType, C.IsRec, C.Pref) AS CntInClass
        FROM #RLC C
    )
    SELECT GW_HDR_CASEID, SourceOrigin_Adm, VectusCaseID_Adm, CostType, IsRec
         , ReserveLinePublicID, ExposureID, CostCategory, Pref, CntInClass
    INTO #RLSEL
    FROM X
    WHERE RN = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_RLSEL ON #RLSEL (GW_HDR_CASEID, SourceOrigin_Adm, VectusCaseID_Adm, CostType, IsRec);
    DROP TABLE #RLC;

    /* recovery reserve line of a TP case: on ONE exposure, vehicle first */
    ;WITH Y AS
    (
        SELECT
            S.GW_HDR_CASEID, S.SourceOrigin_Adm, S.VectusCaseID_Adm
          , ROW_NUMBER() OVER (PARTITION BY S.GW_HDR_CASEID, S.VectusCaseID_Adm
                               ORDER BY CASE S.SourceOrigin_Adm WHEN 'TP_VEH' THEN 1 WHEN 'TP_PRO' THEN 2 ELSE 3 END) AS RN
        FROM #RLSEL S
        WHERE S.IsRec = 1 AND S.CostType = 'claimcost'
          AND S.SourceOrigin_Adm IN ('TP_VEH', 'TP_PRO', 'TP_INJ')
    )
    SELECT GW_HDR_CASEID, VectusCaseID_Adm, SourceOrigin_Adm
    INTO #RLREC
    FROM Y
    WHERE RN = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_RLREC ON #RLREC (GW_HDR_CASEID, VectusCaseID_Adm);

    /* recovery coding per recovery reserve line (first PublicID) */
    SELECT
        CONVERT(VARCHAR(128), RC.ReserveLineID) AS ReserveLineID
      , MIN(RC.PublicID) AS PublicID
    INTO #RCSEL
    FROM IntermediateStaging_DEV.dbo.IS_RECOVERYCODING_MOTOR RC
    WHERE RC.ReserveLineID IS NOT NULL
      AND EXISTS (SELECT 1 FROM #CLAIMS CL WHERE CL.GW_HDR_CASEID = RC.GW_HDR_CASEID)
    GROUP BY CONVERT(VARCHAR(128), RC.ReserveLineID);
    CREATE UNIQUE CLUSTERED INDEX IX_RCSEL ON #RCSEL (ReserveLineID);
    DROP TABLE #CLAIMS;

    /* S8. Pay status history */
    SELECT
        S.GW_PAY_TRAN_ID AS TranID
      , S.ID AS StatusID
      , UPPER(LTRIM(RTRIM(S.STATUS_TYPE))) AS StatusType
      , LTRIM(RTRIM(S.REASON)) AS Reason
      , S.GCURRENT AS GCurrent
      , CASE WHEN S.RECORD_DATE IS NULL OR S.RECORD_TIME IS NULL THEN NULL
             ELSE TRY_CONVERT(DATETIME2(7), CONCAT(S.RECORD_DATE, ' ', S.RECORD_TIME)) END AS Dt
    INTO #STAT
    FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S
    INNER JOIN #TX T ON T.TranID = S.GW_PAY_TRAN_ID;
    CREATE CLUSTERED INDEX IX_STAT ON #STAT (TranID, StatusID);

    /* status row id of first / current / latest AUTH, PRESENTED, PAID, CANX: one GROUP BY */
    SELECT
        S.TranID AS TranID
      , MIN(S.StatusID) AS FirstID
      , MAX(CASE WHEN S.GCurrent = 'X' THEN S.StatusID END) AS CurID
      , MAX(CASE WHEN S.StatusType IN ('AUTH', 'GRP_AUTH') THEN S.StatusID END) AS AuthID
      , MAX(CASE WHEN S.StatusType = 'PRESENTED' THEN S.StatusID END) AS PresID
      , MAX(CASE WHEN S.StatusType = 'PAID' THEN S.StatusID END) AS PaidID
      , MAX(CASE WHEN S.StatusType = 'CANX' THEN S.StatusID END) AS CanxID
    INTO #STID
    FROM #STAT S
    GROUP BY S.TranID;
    CREATE UNIQUE CLUSTERED INDEX IX_STID ON #STID (TranID);

    SELECT
        I.TranID AS TranID
      , F.Dt AS FirstDt
      , CU.StatusType AS CurrentStatusType
      , AU.Dt AS AuthDt
      , PR.Dt AS PresentedDt
      , PD.Dt AS PaidDt
      , CX.Dt AS CanxDt
      , CX.Reason AS CanxReason
    INTO #STD
    FROM #STID I
    LEFT JOIN #STAT F  ON F.TranID  = I.TranID AND F.StatusID  = I.FirstID
    LEFT JOIN #STAT CU ON CU.TranID = I.TranID AND CU.StatusID = I.CurID
    LEFT JOIN #STAT AU ON AU.TranID = I.TranID AND AU.StatusID = I.AuthID
    LEFT JOIN #STAT PR ON PR.TranID = I.TranID AND PR.StatusID = I.PresID
    LEFT JOIN #STAT PD ON PD.TranID = I.TranID AND PD.StatusID = I.PaidID
    LEFT JOIN #STAT CX ON CX.TranID = I.TranID AND CX.StatusID = I.CanxID;
    CREATE UNIQUE CLUSTERED INDEX IX_STD ON #STD (TranID);
    DROP TABLE #STID;
    DROP TABLE #STAT;

    /* S9. Typelists */
    ;WITH Z AS
    (
        SELECT
            LTRIM(RTRIM(TL.Typelist_Name)) AS TL_Name
          , LTRIM(RTRIM(TL.Vectus_TypeCode)) AS VCode
          , LTRIM(RTRIM(TL.GW_TypeCode)) AS GWCode
          , ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(TL.Typelist_Name)), LTRIM(RTRIM(TL.Vectus_TypeCode))
                               ORDER BY CASE TL.[Household/Motor/Both] WHEN 'Motor only' THEN 0 WHEN 'Both' THEN 1 ELSE 2 END) AS RN
        FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
        WHERE LTRIM(RTRIM(TL.Typelist_Name)) IN ('TransactionStatus', 'TransactionLifeCycleState', 'ApprovalStatus',
                                                  'PaymentMethod', 'ReasonToStopCheque_Adm')
          AND TL.Vectus_TypeCode IS NOT NULL
          AND (TL.[Household/Motor/Both] IS NULL OR TL.[Household/Motor/Both] IN ('Motor only', 'Both'))
    )
    SELECT CONVERT(NVARCHAR(100), TL_Name) AS TL_Name
         , CONVERT(NVARCHAR(200), VCode) AS VCode
         , CONVERT(NVARCHAR(200), GWCode) AS GWCode
    INTO #TL
    FROM Z
    WHERE RN = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_TL ON #TL (TL_Name, VCode);

    /* S10. Payee and in-care-of: PAYEE_LINKID / ADD_LINKID -> VEC_GW_CF_LINK.GWCF_HDRID (CONTACT RECORD) -> CONTACT_MASTER_MOTOR -> IS_CLAIMCONTACT.
            PayeeResolution: OK, or one of NO_PAYEE_LINK, LINK_NOT_IN_CF_LINK, LINK_NO_HDR, HDR_NOT_IN_CONTACT_MASTER (no contact master row on this claim),
            NO_CLAIMCONTACT = dummy payee. A payee is never left empty.   [changed] */
    SELECT K.GW_HDR_CASEID AS GW_HDR_CASEID, K.ClaimPublicID AS ClaimPublicID, K.LinkKey AS LinkKey
    INTO #PAYLINK
    FROM (SELECT GW_HDR_CASEID, ClaimPublicID, PayeeLinkKey AS LinkKey FROM #TX WHERE DC = 'D' AND PayeeLinkKey IS NOT NULL
          UNION
          SELECT GW_HDR_CASEID, ClaimPublicID, AddLinkKey AS LinkKey FROM #TX WHERE DC = 'D' AND AddLinkKey IS NOT NULL) K;

    SELECT
        P.GW_HDR_CASEID AS GW_HDR_CASEID
      , P.ClaimPublicID AS ClaimPublicID
      , P.LinkKey AS LinkKey
      , CASE WHEN MAX(L.ID) IS NULL THEN 0 ELSE 1 END AS LinkFound
      , MAX(L.GWCF_HDRID) AS HdrID
    INTO #PAYHDR
    FROM #PAYLINK P
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK L ON L.ID = P.LinkKey
    GROUP BY P.GW_HDR_CASEID, P.ClaimPublicID, P.LinkKey;
    CREATE UNIQUE CLUSTERED INDEX IX_PAYHDR ON #PAYHDR (GW_HDR_CASEID, LinkKey);
    DROP TABLE #PAYLINK;

    SELECT
        H.GW_HDR_CASEID AS GW_HDR_CASEID
      , H.ClaimPublicID AS ClaimPublicID
      , H.LinkKey AS LinkKey
      , H.LinkFound AS LinkFound
      , H.HdrID AS HdrID
      , MIN(CM.PublicID) AS ContactPublicID
    INTO #PAYCON
    FROM #PAYHDR H
    LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.HDR_ID = H.HdrID AND CM.GW_HDR_CASEID = H.GW_HDR_CASEID
    GROUP BY H.GW_HDR_CASEID, H.ClaimPublicID, H.LinkKey, H.LinkFound, H.HdrID;
    CREATE UNIQUE CLUSTERED INDEX IX_PAYCON ON #PAYCON (GW_HDR_CASEID, LinkKey);
    DROP TABLE #PAYHDR;

    SELECT
        C0.GW_HDR_CASEID AS GW_HDR_CASEID
      , C0.LinkKey AS LinkKey
      , C0.LinkFound AS LinkFound
      , C0.HdrID AS HdrID
      , C0.ContactPublicID AS ContactPublicID
      , MIN(CC.PublicID) AS ClaimContactPublicID
    INTO #PAYCC
    FROM #PAYCON C0
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC
           ON CC.ContactID = C0.ContactPublicID AND CC.ClaimID = C0.ClaimPublicID
    GROUP BY C0.GW_HDR_CASEID, C0.LinkKey, C0.LinkFound, C0.HdrID, C0.ContactPublicID;
    CREATE UNIQUE CLUSTERED INDEX IX_PAYCC ON #PAYCC (GW_HDR_CASEID, LinkKey);
    DROP TABLE #PAYCON;

    /* gateway reference (check number) once per gateway id */
    SELECT G.ID AS GatewayID, LTRIM(RTRIM(MIN(G.TRANS_REF))) AS TransRef
    INTO #GW
    FROM SourceStaging.VECCASRN.VEC_GW_PAY_GATEWAY G
    WHERE EXISTS (SELECT 1 FROM #TX T WHERE T.GatewayID = G.ID)
    GROUP BY G.ID;
    CREATE UNIQUE CLUSTERED INDEX IX_GW ON #GW (GatewayID);

    /* S11. Final master rows */
    ;WITH B AS
    (
     SELECT
        T.TranID AS TranID
      , U.MasterSuffix AS MasterSuffix
      , U.CostType AS CostType
      , U.IsHire AS IsHire
      , U.MasterAmount AS MasterAmount
      , T.GW_HDR_CASEID AS GW_HDR_CASEID
      , T.CLAIM_REF AS CLAIM_REF
      , T.ClaimPublicID AS ClaimPublicID
      , T.CaseID AS CaseID
      , T.CaseType AS CaseType
      , CS.CASE_STATUS AS CASE_STATUS
      , T.DC AS DC
      , T.PayType AS PayType
      , T.HdrAmount AS HdrAmount
      , T.PayeeLinkKey AS PayeeLinkKey
      , T.AddLinkKey AS AddLinkKey
      /* target case / origin; payment (D) AND recovery (C) on an AD case of a claim without any AD exposure go to claim level (HDR); same rule for D and C */
      , CASE
            WHEN T.CaseType = 'HDR' THEN CONVERT(VARCHAR(64), T.GW_HDR_CASEID)
            WHEN T.CaseType = 'AD'  THEN CASE WHEN AX.VectusCaseID_Adm IS NOT NULL THEN CONVERT(VARCHAR(64), T.CaseID)
                                              WHEN AC.AdCnt = 1 THEN AC.AdOnly
                                              WHEN AC.AdCnt IS NULL AND @AdNoExposureToClaim = 1 THEN CONVERT(VARCHAR(64), T.GW_HDR_CASEID)
                                         END
            ELSE CONVERT(VARCHAR(64), T.CaseID)
        END AS TargetCase
      , CASE
            WHEN T.CaseType = 'HDR' THEN 'HDR'
            WHEN T.CaseType = 'AD'  THEN CASE WHEN AX.VectusCaseID_Adm IS NULL AND AC.AdCnt IS NULL AND @AdNoExposureToClaim = 1 THEN 'HDR' ELSE 'AD' END
            WHEN T.CaseType = 'PA'  THEN 'PA'
            WHEN T.CaseType = 'TP' AND T.DC = 'D' AND U.IsHire = 1 THEN CASE WHEN TF.HasHire = 1 THEN 'TP_HIRE' END
            WHEN T.CaseType = 'TP' AND T.DC = 'D'
                 THEN CASE WHEN TF.HasVeh = 1 THEN 'TP_VEH' WHEN TF.HasPro = 1 THEN 'TP_PRO' WHEN TF.HasInj = 1 THEN 'TP_INJ' END
            WHEN T.CaseType = 'TP' AND T.DC = 'C' THEN RR.SourceOrigin_Adm
        END AS TargetOrigin
      , SD.CurrentStatusType AS CurrentStatusType
      , SD.FirstDt AS FirstDt
      , SD.AuthDt AS AuthDt
      , SD.PresentedDt AS PresentedDt
      , SD.PaidDt AS PaidDt
      , SD.CanxDt AS CanxDt
      , SD.CanxReason AS CanxReason
      , PY.ContactPublicID AS PayeeContactPublicID
      , PY.ClaimContactPublicID AS PayeeClaimContactPublicID
      , PY.HdrID AS PayeeHdrID
      , IC.ContactPublicID AS InCareOfPublicID
      , IC.HdrID AS InCareOfHdrID
      , CASE WHEN T.DC <> 'D' THEN NULL
             WHEN T.PayeeLinkKey IS NULL THEN 'NO_PAYEE_LINK'
             WHEN ISNULL(PY.LinkFound, 0) = 0 THEN 'LINK_NOT_IN_CF_LINK'
             WHEN PY.HdrID IS NULL THEN 'LINK_NO_HDR'
             WHEN PY.ContactPublicID IS NULL THEN 'HDR_NOT_IN_CONTACT_MASTER'
             WHEN PY.ClaimContactPublicID IS NULL THEN 'NO_CLAIMCONTACT'
             ELSE 'OK' END AS PayeeResolution
      , GW.TransRef AS GatewayRef
     FROM #MASTER0 U
     INNER JOIN #TX T ON T.TranID = U.TranID
     LEFT JOIN #CS CS ON CS.CaseID = T.CaseID
     LEFT JOIN #ADEXP AX ON AX.GW_HDR_CASEID = T.GW_HDR_CASEID AND AX.VectusCaseID_Adm = CONVERT(VARCHAR(64), T.CaseID) AND T.CaseType = 'AD'
     LEFT JOIN #ADCNT AC ON AC.GW_HDR_CASEID = T.GW_HDR_CASEID AND T.CaseType = 'AD'
     LEFT JOIN #TPFLAG TF ON TF.GW_HDR_CASEID = T.GW_HDR_CASEID AND TF.VectusCaseID_Adm = CONVERT(VARCHAR(64), T.CaseID) AND T.CaseType = 'TP'
     LEFT JOIN #RLREC RR ON RR.GW_HDR_CASEID = T.GW_HDR_CASEID AND RR.VectusCaseID_Adm = CONVERT(VARCHAR(64), T.CaseID) AND T.CaseType = 'TP' AND T.DC = 'C'
     LEFT JOIN #STD SD ON SD.TranID = T.TranID
     LEFT JOIN #PAYCC PY ON PY.GW_HDR_CASEID = T.GW_HDR_CASEID AND PY.LinkKey = T.PayeeLinkKey AND T.DC = 'D'
     LEFT JOIN #PAYCC IC ON IC.GW_HDR_CASEID = T.GW_HDR_CASEID AND IC.LinkKey = T.AddLinkKey AND T.DC = 'D'
     LEFT JOIN #GW GW ON GW.GatewayID = T.GatewayID
    ),
    C AS
    (
     SELECT
        B.*
      /* more than one reserve line in the same slot, or no main TP injury line: no line is picked, ReserveLineID stays NULL */
      , CASE WHEN B.TargetOrigin = 'TP_INJ' AND B.DC = 'D' AND RS.Pref <> 0 THEN NULL WHEN RS.CntInClass > 1 THEN NULL ELSE RS.ReserveLinePublicID END AS ReserveLineID
      , CASE WHEN RS.CntInClass > 1 THEN NULL ELSE RS.ExposureID END AS ExposureID
      , CASE WHEN B.TargetOrigin = 'TP_INJ' AND B.DC = 'D' AND RS.Pref <> 0 THEN NULL WHEN RS.CntInClass > 1 THEN NULL ELSE RS.CostCategory END AS CostCategory
      , RC.PublicID AS RecoveryCodingID
      , CASE WHEN B.PayeeResolution IN ('NO_PAYEE_LINK', 'LINK_NOT_IN_CF_LINK', 'LINK_NO_HDR', 'HDR_NOT_IN_CONTACT_MASTER', 'NO_CLAIMCONTACT') THEN 1 ELSE 0 END AS IsDummy
      , ST.GWCode AS StatusCode
      , LC2.GWCode AS LifeCycleCode
      , AP2.GWCode AS ApprovalCode
      , PM.GWCode AS PaymentMethodCode
      , RZ.GWCode AS StopReasonCode
     FROM B
     LEFT JOIN #RLSEL RS
            ON RS.GW_HDR_CASEID = B.GW_HDR_CASEID
           AND RS.SourceOrigin_Adm = B.TargetOrigin
           AND RS.VectusCaseID_Adm = B.TargetCase
           AND RS.CostType = B.CostType
           AND RS.IsRec = CASE WHEN B.DC = 'C' THEN 1 ELSE 0 END
     LEFT JOIN #RCSEL RC ON RC.ReserveLineID = RS.ReserveLinePublicID AND B.DC = 'C' AND RS.CntInClass = 1
     LEFT JOIN #TL ST  ON ST.TL_Name  = 'TransactionStatus'        AND ST.VCode  = B.CurrentStatusType
     LEFT JOIN #TL LC2 ON LC2.TL_Name = 'TransactionLifeCycleState' AND LC2.VCode = B.CurrentStatusType
     LEFT JOIN #TL AP2 ON AP2.TL_Name = 'ApprovalStatus'            AND AP2.VCode = B.CurrentStatusType
     LEFT JOIN #TL PM  ON PM.TL_Name  = 'PaymentMethod'             AND PM.VCode  = B.PayType
     LEFT JOIN #TL RZ  ON RZ.TL_Name  = 'ReasonToStopCheque_Adm'    AND RZ.VCode  = LTRIM(RTRIM(B.CanxReason))
    )
    SELECT
        C.TranID, C.MasterSuffix, C.GW_HDR_CASEID, C.CLAIM_REF, C.ClaimPublicID, C.CaseID, C.CaseType, C.CASE_STATUS
      , C.TargetCase, C.TargetOrigin, C.DC, C.CostType, C.CostCategory, C.IsHire
      , C.ExposureID, C.ReserveLineID, C.RecoveryCodingID, C.PayType
      , C.CurrentStatusType, C.StatusCode, C.LifeCycleCode, C.ApprovalCode
      , C.FirstDt, C.AuthDt, C.PresentedDt, C.PaidDt, C.CanxDt, C.StopReasonCode
      , C.PayeeLinkKey, C.AddLinkKey, C.PayeeContactPublicID, C.PayeeClaimContactPublicID
      , C.InCareOfPublicID, C.PayeeHdrID, C.InCareOfHdrID, C.PayeeResolution, C.IsDummy
      , C.GatewayRef, C.PaymentMethodCode, C.HdrAmount, C.MasterAmount
      , CONVERT(BIT, CASE WHEN C.CaseType = 'PA' AND C.DC = 'C' AND @ExcludePaCredits = 1 THEN 0 ELSE 1 END) AS Loadable
    INTO #U
    FROM C;
    CREATE UNIQUE CLUSTERED INDEX IX_U ON #U (TranID, MasterSuffix);
    DROP TABLE #TX;
    DROP TABLE #CS;
    DROP TABLE #MASTER0;
    DROP TABLE #TPFLAG;
    DROP TABLE #ADEXP;
    DROP TABLE #ADCNT;
    DROP TABLE #RLSEL;
    DROP TABLE #RLREC;
    DROP TABLE #RCSEL;
    DROP TABLE #STD;
    DROP TABLE #TL;
    DROP TABLE #PAYCC;
    DROP TABLE #GW;

    /* S12. Write master rows and lines.  Text columns are read here from VEC_GW_PAY_TRANS   [changed] */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR WITH (TABLOCK)
    (
        TranID, MasterSuffix, GW_HDR_CASEID, CLAIM_REF, ClaimPublicID, CaseID, CaseType, CASE_STATUS
      , VectusCaseID_Adm, SourceOrigin_Adm, DebitCredit, Subtype, CostType, CostCategory, IsHire
      , ExposureID, ReserveLineID, RecoveryCodingID, PayType, IsTransfer
      , CurrentStatusType, Status, LifeCycleState, ApprovalStatus
      , CreateTime, ApprovalDate, PresentedDate, PaidDate, CanxDate, ChequeStopReason
      , CashMoveNo, ChequeNumber, PayeeName, AccountNumber, SortCode, Grouped, PostCode
      , AddressLine1, AddressLine2, AddressLine3, PayeeLinkID, AddLinkID
      , PayeeContactID, PayeeClaimContactID, InCareOfContactID, PayeeHdrID, InCareOfHdrID, PayeeResolution, IsDummyPayee, GatewayRef, PaymentMethod
      , HdrAmount, MasterAmount, Loadable
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
      , U.FirstDt
        /* ApprovalDate: credits = first status record; debits = latest AUTH / GRP_AUTH, else first record; 3 decimals */
      , CONVERT(DATETIME2(3), CASE WHEN U.DC = 'C' THEN U.FirstDt ELSE ISNULL(U.AuthDt, U.FirstDt) END)
      , U.PresentedDt
      , U.PaidDt
      , U.CanxDt
        /* stop reason only where a CANX record exists; not in the typelist = issued_in_error (mapping row 19) */
      , CASE WHEN U.CanxDt IS NOT NULL THEN ISNULL(U.StopReasonCode, 'issued_in_error') END
      , TRY_CONVERT(BIGINT, NULLIF(LTRIM(RTRIM(PT.CASH_MOVE_NO)), ''))
      , PT.CHEQUE_NUMBER
      , PT.PAYEE_NAME
      , PT.ACCOUNT_NUMBER
      , PT.SORT_CODE
      , LTRIM(RTRIM(PT.GROUPED))
      , PT.POST_CODE
      , PT.ADDRESS_LINE1
      , PT.ADDRESS_LINE2
      , PT.ADDRESS_LINE3
      , U.PayeeLinkKey
      , U.AddLinkKey
      , CASE WHEN U.DC = 'D' THEN CASE WHEN U.IsDummy = 1 THEN 'mig:motorpayee_' + CONVERT(VARCHAR(20), U.TranID) ELSE U.PayeeContactPublicID END END
      , CASE WHEN U.DC = 'D' THEN CASE WHEN U.IsDummy = 1 THEN 'mig:motorpayeecc_' + CONVERT(VARCHAR(20), U.TranID) ELSE U.PayeeClaimContactPublicID END END
      , U.InCareOfPublicID
      , U.PayeeHdrID
      , U.InCareOfHdrID
      , U.PayeeResolution
      , CASE WHEN U.DC = 'D' AND U.IsDummy = 1 THEN 1 ELSE 0 END
      , U.GatewayRef
      , U.PaymentMethodCode
      , U.HdrAmount
      , U.MasterAmount
      , U.Loadable
    FROM #U U
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.ID = U.TranID;

    /* lines: every line belongs to exactly one master row   [changed: one insert, suffix and category already on the line] */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_LINE_MOTOR WITH (TABLOCK)
        (TranID, MasterSuffix, LineKey, DissCode, Amount, LineCategoryCode)
    SELECT L.TranID, L.MasterSuffix, L.LineKey, L.DissCode, L.Amount, L.LineCategoryCode
    FROM #LINE L;
    DROP TABLE #LINE;
    DROP TABLE #U;
END;
GO
