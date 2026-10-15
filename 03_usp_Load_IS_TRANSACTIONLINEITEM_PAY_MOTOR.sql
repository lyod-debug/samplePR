/* =====================================================================================
   03_usp_Load_IS_TRANSACTIONLINEITEM_PAY_MOTOR
   One cc_transactionlineitem per dissection of every loadable master row.
   PublicID: 'mig:motorpli_' + LineKey. LineCategory is hard coded in proc 01 (mapping row 180).
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_IS_TRANSACTIONLINEITEM_PAY_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR WITH (TABLOCK)
    (
        GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, PublicID, LUWID, CreateTime /*, LegacyCreateTime_Adm*/, CreateUserID
      , TransactionAmount, ReservingForExAmount, ReportingForExAmount, ReportingAmount
      , ClaimForExAmount, ClaimAmount, ReservingAmount, LineCategory, TransactionID
    )
    SELECT
        U.GW_HDR_CASEID
      , U.CLAIM_REF
      , U.VectusCaseID_Adm
      , U.SourceOrigin_Adm
      , U.CASE_STATUS
      , 'mig:motorpli_' + L.LineKey
      , U.CLAIM_REF
        /* first status record (mapping row 182) */
      , U.CreateTime /*, U.CreateTime AS LegacyCreateTime_Adm*/
        /* migration user type code (mapping row 181) */
      , 'migration user'
      , L.Amount
      , 0.00
      , 0.00
      , L.Amount
      , 0.00
      , L.Amount
      , L.Amount
      , L.LineCategoryCode
      , 'mig:motorpay_' + CONVERT(VARCHAR(20), L.TranID) + L.MasterSuffix
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_LINE_MOTOR L
    INNER JOIN IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
            ON U.TranID = L.TranID AND U.MasterSuffix = L.MasterSuffix
    WHERE U.Loadable = 1;
END;
GO
