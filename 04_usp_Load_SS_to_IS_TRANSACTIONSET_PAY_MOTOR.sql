/* =====================================================================================
   04_usp_Load_SS_to_IS_TRANSACTIONSET_PAY_MOTOR
   One cc_transactionset per master row (all except PA recoveries) (BA: a transaction set relates to ONE transaction; a split V2 transaction gets two sets).
   Subtype : CheckSet for payments, RecoverySet for recoveries.
   PublicID: 'mig:motorpts_' + V2 transaction id + MasterSuffix  (same value the transaction and the check point to)
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_TRANSACTIONSET_PAY_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_TRANSACTIONSET_PAY_MOTOR;

    ;WITH X AS
    (
        SELECT U.*
        FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
        WHERE U.Loadable = 1
    )
    INSERT INTO IntermediateStaging_DEV.dbo.IS_TRANSACTIONSET_PAY_MOTOR
    (
          GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, PublicID, LUWID
        , ApprovalDate, ApprovalStatus, ClaimID, CreatedVia, LegacyCreateTime_Adm, RequestingUserID, Subtype, CashMoveNo_Adm
    )
    SELECT
            X.GW_HDR_CASEID AS GW_HDR_CASEID
          , X.CLAIM_REF AS CLAIM_REF
          , X.VectusCaseID_Adm AS VectusCaseID_Adm
          , X.SourceOrigin_Adm AS SourceOrigin_Adm
          , X.CASE_STATUS AS CASE_STATUS
          , 'mig:motorpts_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix AS PublicID
          , X.CLAIM_REF AS LUWID
            /* ApprovalDate - recoveries: first status record; payments: latest AUTH / GRP_AUTH record, else first record */
          , X.ApprovalDate AS ApprovalDate
            /* ApprovalStatus - typelist ApprovalStatus, based on cc_transaction.Status */
          , X.ApprovalStatus AS ApprovalStatus
          , X.ClaimPublicID AS ClaimID
            /* CreatedVia - User Entry */
          , 'manual' AS CreatedVia
            /* CreateTime logic goes to LegacyCreateTime_Adm (user decision) */
          , X.CreateTime AS LegacyCreateTime_Adm
            /* RequestingUserID - migration user, pending the real PublicID */
          , NULL AS RequestingUserID
          , CASE WHEN X.DebitCredit = 'D' THEN 'CheckSet' ELSE 'RecoverySet' END AS Subtype
            /* CashMoveNo_Adm - AS IS */
          , X.CashMoveNo AS CashMoveNo_Adm
    FROM X;
END;
GO
