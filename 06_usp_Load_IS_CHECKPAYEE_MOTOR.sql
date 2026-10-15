/* =====================================================================================
   06_usp_Load_IS_CHECKPAYEE_MOTOR
   Exactly one cc_checkpayee per check (loadable payment master rows).
   PublicID: 'mig:motorchp_' + TranID + MasterSuffix. PayeeType = 'checkpayee' (mapping row 86).
   The checkpayee ROLE row is created in usp_Load_IS_CLAIMCONTACTROLE (step 5B).
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_IS_CHECKPAYEE_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_CHECKPAYEE_MOTOR;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_CHECKPAYEE_MOTOR WITH (TABLOCK)
    (
        GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, PublicID, LUWID
      , CheckID, ClaimContactID, PayeeType, IsDummyPayee
    )
    SELECT
        X.GW_HDR_CASEID
      , X.CLAIM_REF
      , X.VectusCaseID_Adm
      , X.SourceOrigin_Adm
      , X.CASE_STATUS
      , 'mig:motorchp_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix
      , X.CLAIM_REF
      , 'mig:motorchk_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix
      , X.PayeeClaimContactID
      , 'checkpayee'
      , X.IsDummyPayee
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR X
    WHERE X.DebitCredit = 'D'
      AND X.Loadable = 1;
END;
GO
