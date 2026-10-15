/* =====================================================================================
   02_usp_Load_IS_TRANSACTION_PAY_MOTOR
   One cc_transaction (Payment or Recovery) per master row; PA recoveries are not loaded (Loadable = 0, mapping row 136).
   PublicID: 'mig:motorpay_' + TranID + MasterSuffix. Reads IS_PAYMENT_MASTER_MOTOR (run proc 01 first).
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_IS_TRANSACTION_PAY_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_TRANSACTION_PAY_MOTOR;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_TRANSACTION_PAY_MOTOR WITH (TABLOCK)
    (
        GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS
      , PublicID, LUWID, BookingDate, CreateTime /*, LegacyCreateTime_Adm*/, CreateUserID, ClaimID, CostCategory, CostType, Currency, ExposureID
      , LifeCycleState, RecoveryCategory, RecoveryCodingID, ReserveLineID, ReservingCurrency, Status
      , Subtype, TransactionSetID, PaymentType, DoesNotErodeReserves, CloseExposure, CloseClaim, CheckID
      , DenormCashMoveNo_Adm, ChequeNumber_Adm, InternalCCPayRecoCurrency_Adm, InternalCCPayRecoCat_Adm
    )
    SELECT
        U.GW_HDR_CASEID
      , U.CLAIM_REF
      , U.VectusCaseID_Adm
      , U.SourceOrigin_Adm
      , U.CASE_STATUS
      , 'mig:motorpay_' + CONVERT(VARCHAR(20), U.TranID) + U.MasterSuffix
      , U.CLAIM_REF
        /* BookingDate and CreateTime = first status record (mapping rows 150, 132) */
      , U.CreateTime
      , U.CreateTime /*, U.CreateTime AS LegacyCreateTime_Adm*/
        /* migration user type code (mapping row 131) */
      , 'migration user'
      , U.ClaimPublicID
      , U.CostCategory
      , U.CostType
      , 'gbp'
      , U.ExposureID
      , U.LifeCycleState
      , CASE WHEN U.DebitCredit = 'C' THEN 'subro' END
      , CASE WHEN U.DebitCredit = 'C' THEN U.RecoveryCodingID END
      , U.ReserveLineID
      , 'gbp'
      , U.Status
      , U.Subtype
      , 'mig:motorpts_' + CONVERT(VARCHAR(20), U.TranID) + U.MasterSuffix
      , CASE WHEN U.DebitCredit = 'D' THEN 'partial' END
      , CASE WHEN U.DebitCredit = 'D' THEN 1 END
      , CASE WHEN U.DebitCredit = 'D' THEN 0 END
      , CASE WHEN U.DebitCredit = 'D' THEN 0 END
      , CASE WHEN U.DebitCredit = 'D' THEN 'mig:motorchk_' + CONVERT(VARCHAR(20), U.TranID) + U.MasterSuffix END
        /* recoveries only (payments carry cash move number and cheque number on the check) */
      , CASE WHEN U.DebitCredit = 'C' THEN U.CashMoveNo END
      , CASE WHEN U.DebitCredit = 'C' THEN U.ChequeNumber END
        /* transfer on the TARGET claim = PAY_TYPE T and credit (changed: credit side, BA); mapping rows 134 and 135 */
      , CASE WHEN U.PayType = 'T' AND U.DebitCredit = 'C' THEN 'gbp' END
      , CASE WHEN U.PayType = 'T' AND U.DebitCredit = 'C' THEN 'subro' END
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
    WHERE U.Loadable = 1;
END;
GO
