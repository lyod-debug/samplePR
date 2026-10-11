/* =====================================================================================
   03_usp_Load_SS_to_IS_TRANSACTIONLINEITEM_PAY_MOTOR
   One cc_transactionlineitem per V2 dissection (VEC_GW_PAY_DISS row) of every master row that is copied (all except PA recoveries).
   All four amounts equal the dissection amount, the three "ForEx" amounts are 0.
   PublicID : 'mig:motorpli_' + V2 transaction id + MasterSuffix + '_' + line number
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_TRANSACTIONLINEITEM_PAY_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR
    (
          GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, PublicID, LUWID, LegacyCreateTime_Adm
        , TransactionAmount, ReservingForExAmount, ReportingForExAmount, ReportingAmount
        , ClaimForExAmount, ClaimAmount, ReservingAmount, LineCategory, TransactionID
    )
    SELECT
            U.GW_HDR_CASEID AS GW_HDR_CASEID
          , U.CLAIM_REF AS CLAIM_REF
          , U.VectusCaseID_Adm AS VectusCaseID_Adm
          , U.SourceOrigin_Adm AS SourceOrigin_Adm
          , U.CASE_STATUS AS CASE_STATUS
            /* PublicID */
          , 'mig:motorpli_' + CONVERT(VARCHAR(20), L.TranID) + L.MasterSuffix + '_' + CONVERT(VARCHAR(10), L.LineSeq) AS PublicID
          , U.CLAIM_REF AS LUWID
            /* CreateTime logic goes to LegacyCreateTime_Adm (user decision): first status record, the same for every line of the transaction */
          , U.CreateTime AS LegacyCreateTime_Adm
            /* TransactionAmount - VEC_GW_PAY_DISS.AMOUNT AS IS */
          , L.Amount AS TransactionAmount
            /* ForEx amounts - mapping: 0. Kept here although IS_TRANSACTIONLINEITEM has no such columns (see file 15) */
          , 0.00 AS ReservingForExAmount
          , 0.00 AS ReportingForExAmount
          , L.Amount AS ReportingAmount
          , 0.00 AS ClaimForExAmount
          , L.Amount AS ClaimAmount
          , L.Amount AS ReservingAmount
            /* LineCategory - typecode of typelist LineCategory (Migrated Payment / Migrated Recovery), resolved in proc 01 */
          , L.LineCategoryCode AS LineCategory
            /* TransactionID */
          , 'mig:motorpay_' + CONVERT(VARCHAR(20), L.TranID) + L.MasterSuffix AS TransactionID
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_LINE_MOTOR L
    INNER JOIN IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
            ON U.TranID = L.TranID AND U.MasterSuffix = L.MasterSuffix
    WHERE U.Loadable = 1;
END;
GO
