/* =====================================================================================
   06b_usp_Load_SS_to_IS_CLAIMCONTACTROLE_CHECKPAYEE_MOTOR            (NEW, Oct 13)
   Creates the claim contact role 'checkpayee' (cc_claimcontactrole) for every payee of a Motor payment.
   Source: BA transcript lines 82-83 ("the check pay role is a mandatory transaction related role and it should be assigned
           to every contact from the V2 side that is related to a payment"; for a dummy contact "a record in the claim
           contact role table so that you can assign your dummy contact the check payroll").
   Mapping: Payee_Contact sheet rows 123 (Active = 0), 126 (ClaimContactID), 132 (ExposureID = exposure of the payment),
            148 (Role = 'checkpayee'). Row 123 (Active = 0) sits in the dummy-payee sheet, so it is used for the dummy payee only.
            Real payees get Active = 1 as every other role of usp_Load_IS_CLAIMCONTACTROLE (user decision, Oct 13: only the dummy check payee gets 0).
   Run order: 01, 01b, then this proc (it reads IS_PAYMENT_MASTER_MOTOR only). It does NOT touch IS_CLAIMCONTACTROLE
              (usp_Load_IS_CLAIMCONTACTROLE v6 truncates that table on every run and stays unchanged).
   One row per (payee claim contact, exposure of the payment). Claim-level payments have no exposure (ExposureID NULL).
   PublicID: real payee   'mig:motorccr' + HDR_ID + '_checkpayee' [+ '_' + exposure without 'mig:motor_']   (same pattern as the claimant role)
             dummy payee  'mig:motorccr_payee' + TranID + '_checkpayee' [+ '_' + exposure without 'mig:motor_']
   Rows are only built for master rows copied to the transaction tables (Loadable = 1) that have a payee claim contact.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_CLAIMCONTACTROLE_CHECKPAYEE_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYEE_CLAIMCONTACTROLE_PAY_MOTOR;

    ;WITH D AS
    (
        SELECT
                M.GW_HDR_CASEID
              , M.CLAIM_REF
              , M.PayeeClaimContactID                     AS ClaimContactID
              , M.ExposureID                              AS ExposureID
              , M.IsDummyPayee                            AS IsDummy
              , MIN(M.PayeeHdrID)                         AS PayeeHdrID
              , MIN(M.TranID)                             AS TranID
        FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
        WHERE M.DebitCredit = 'D'
          AND M.Loadable = 1
          AND M.PayeeClaimContactID IS NOT NULL
        GROUP BY M.GW_HDR_CASEID, M.CLAIM_REF, M.PayeeClaimContactID, M.ExposureID, M.IsDummyPayee
    )
    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYEE_CLAIMCONTACTROLE_PAY_MOTOR
        (PublicID, GW_HDR_CASEID, CLAIM_REF, LUWID, Active, ClaimContactID, ExposureID, IncidentID, PolicyID, Role, IsDummy)
    SELECT
            CASE WHEN D.IsDummy = 1
                 THEN 'mig:motorccr_payee' + CONVERT(VARCHAR(20), D.TranID)
                 ELSE 'mig:motorccr' + CONVERT(VARCHAR(20), D.PayeeHdrID) END
            + '_checkpayee'
            + CASE WHEN D.ExposureID IS NOT NULL THEN '_' + REPLACE(D.ExposureID, 'mig:motor_', '') ELSE '' END AS PublicID
          , D.GW_HDR_CASEID
          , D.CLAIM_REF
          , D.CLAIM_REF AS LUWID
          , CASE WHEN D.IsDummy = 1 THEN 0 ELSE 1 END AS Active   /* dummy: Payee_Contact row 123 = FALSE. Real payee: 1 like every other role in usp_Load_IS_CLAIMCONTACTROLE (NOT CONFIRMED by the BA) */
          , D.ClaimContactID
          , D.ExposureID
          , NULL AS IncidentID
          , NULL AS PolicyID
          , 'checkpayee' AS Role
          , D.IsDummy
    FROM D;
END;
GO
