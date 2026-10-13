/* =====================================================================================
   06_usp_Load_SS_to_IS_CHECKPAYEE_MOTOR
   Exactly one cc_checkpayee per check.
   PublicID: 'mig:motorchp_' + V2 transaction id + MasterSuffix
   PayeeType = 'checkpayee' (mapping row 86, column of this table, not nullable).
   The claim contact ROLE row (cc_claimcontactrole) is NOT created here: it is done later in the claim contact role proc.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_CHECKPAYEE_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_CHECKPAYEE_MOTOR;

    ;WITH X AS
    (
        SELECT U.*
        FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
        WHERE U.DebitCredit = 'D'
    )
    INSERT INTO IntermediateStaging_DEV.dbo.IS_CHECKPAYEE_MOTOR
    (
          GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, PublicID, LUWID
        , CheckID, ClaimContactID, PayeeType, IsDummyPayee
    )
    SELECT
            X.GW_HDR_CASEID AS GW_HDR_CASEID
          , X.CLAIM_REF AS CLAIM_REF
          , X.VectusCaseID_Adm AS VectusCaseID_Adm
          , X.SourceOrigin_Adm AS SourceOrigin_Adm
          , X.CASE_STATUS AS CASE_STATUS
          , 'mig:motorchp_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix AS PublicID
          , X.CLAIM_REF AS LUWID
          , 'mig:motorchk_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix AS CheckID
            /* ClaimContactID - claim contact of PAYEE_LINKID, or the dummy claim contact */
          , X.PayeeClaimContactID AS ClaimContactID
            /* PayeeDenormID is NOT loaded: ClaimCenter fills it when CCST is loaded into CC (BA, transcript line 82) */
            /* PayeeType - mapping row 86: DB type is a TYPE KEY of ContactRole (no FK) and not nullable; the code is 'checkpayee' */
          , 'checkpayee' AS PayeeType
          , X.IsDummyPayee AS IsDummyPayee
    FROM X;
END;
GO
