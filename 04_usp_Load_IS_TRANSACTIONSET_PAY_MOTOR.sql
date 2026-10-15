/* =====================================================================================
   04_usp_Load_IS_TRANSACTIONSET_PAY_MOTOR
   One cc_transactionset per loadable master row: CheckSet for payments, RecoverySet for recoveries.
   PublicID: 'mig:motorpts_' + TranID + MasterSuffix.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_IS_TRANSACTIONSET_PAY_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_TRANSACTIONSET_PAY_MOTOR;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_TRANSACTIONSET_PAY_MOTOR WITH (TABLOCK)
    (
        GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, PublicID, LUWID
      , ApprovalDate, ApprovalStatus, ClaimID, CreatedVia, CreateTime /*, LegacyCreateTime_Adm*/, CreateUserID, RequestingUserID, Subtype, CashMoveNo_Adm
    )
    SELECT
        X.GW_HDR_CASEID
      , X.CLAIM_REF
      , X.VectusCaseID_Adm
      , X.SourceOrigin_Adm
      , X.CASE_STATUS
      , 'mig:motorpts_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix
      , X.CLAIM_REF
        /* recoveries: first status record; payments: latest AUTH / GRP_AUTH record, else first record (calculated in proc 01) */
      , X.ApprovalDate
      , X.ApprovalStatus
      , X.ClaimPublicID
      , 'manual'
        /* same as transaction CreateTime (mapping row 202) */
      , X.CreateTime /*, X.CreateTime AS LegacyCreateTime_Adm*/
        /* migration user type code (mapping rows 201, 200) */
      , 'migration user'
      , 'migration user'
      , CASE WHEN X.DebitCredit = 'D' THEN 'CheckSet' ELSE 'RecoverySet' END
      , X.CashMoveNo
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR X
    WHERE X.Loadable = 1;
END;
GO
