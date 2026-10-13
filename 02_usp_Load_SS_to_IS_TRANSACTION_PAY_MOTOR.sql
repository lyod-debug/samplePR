/* =====================================================================================
   02_usp_Load_SS_to_IS_TRANSACTION_PAY_MOTOR
   One cc_transaction row (Subtype Payment or Recovery) per master row (all of them; only PA recoveries are left out, field-mapping row 136 (cc_transaction.ExposureID)).
   Reads only IS_PAYMENT_MASTER_MOTOR (run 01 first).
   PublicID   : 'mig:motorpay_' + V2 transaction id + MasterSuffix      (MasterSuffix is always set: _cost _exp _x.. (_hirecost = Hire & Mobility claim cost; _hx.. only for a hire lookup typo) for payments, _rec for recoveries)
   Set / check: every ClaimCenter transaction has its OWN transaction set and (payments) its OWN check (BA: a set relates to a single transaction).
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_TRANSACTION_PAY_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_TRANSACTION_PAY_MOTOR;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_TRANSACTION_PAY_MOTOR
    (
          GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS
        , PublicID, LUWID, BookingDate, LegacyCreateTime_Adm, ClaimID, CostCategory, CostType, Currency, ExposureID
        , LifeCycleState, RecoveryCategory, RecoveryCodingID, ReserveLineID, ReservingCurrency, Status
        , Subtype, TransactionSetID, PaymentType, DoesNotErodeReserves, CloseExposure, CloseClaim, CheckID
        , DenormCashMoveNo_Adm, ChequeNumber_Adm, InternalCCPayRecoCurrency_Adm, InternalCCPayRecoCat_Adm
    )
    SELECT
            /* GW_HDR_CASEID */
            U.GW_HDR_CASEID AS GW_HDR_CASEID
            /* CLAIM_REF */
          , U.CLAIM_REF AS CLAIM_REF
            /* VectusCaseID_Adm - the case of the reserve line the money is booked on */
          , U.VectusCaseID_Adm AS VectusCaseID_Adm
            /* SourceOrigin_Adm */
          , U.SourceOrigin_Adm AS SourceOrigin_Adm
            /* CASE_STATUS */
          , U.CASE_STATUS AS CASE_STATUS
            /* PublicID */
          , 'mig:motorpay_' + CONVERT(VARCHAR(20), U.TranID) + U.MasterSuffix AS PublicID
            /* LUWID - claim number, carried for debugging */
          , U.CLAIM_REF AS LUWID
            /* BookingDate - same as CreateTime (first VEC_GW_PAY_STATUS record) */
          , U.CreateTime AS BookingDate
            /* CreateTime logic goes to LegacyCreateTime_Adm (user decision): first VEC_GW_PAY_STATUS record (MIN id) */
          , U.CreateTime AS LegacyCreateTime_Adm
            /* ClaimID */
          , U.ClaimPublicID AS ClaimID
            /* CostCategory - AS IS from the main reserve line */
          , U.CostCategory AS CostCategory
            /* CostType - claimcost / aoexpense from Lkp_Transaction_Typelist; credits always claimcost */
          , U.CostType AS CostType
            /* Currency */
          , 'gbp' AS Currency
            /* ExposureID - exposure of the reserve line; NULL on claim-level (HDR) lines */
          , U.ExposureID AS ExposureID
            /* LifeCycleState - typelist TransactionLifeCycleState, based on cc_transaction.Status */
          , U.LifeCycleState AS LifeCycleState
            /* RecoveryCategory - RECOVERIES ONLY, Subrogation (code subro) */
          , CASE WHEN U.DebitCredit = 'C' THEN 'subro' END AS RecoveryCategory
            /* RecoveryCodingID - RECOVERIES ONLY, the coding record of the recovery reserve line */
          , CASE WHEN U.DebitCredit = 'C' THEN U.RecoveryCodingID END AS RecoveryCodingID
            /* ReserveLineID - main reserve line (payments) / recovery reserve line (recoveries) */
          , U.ReserveLineID AS ReserveLineID
            /* ReservingCurrency */
          , 'gbp' AS ReservingCurrency
            /* Status - typelist TransactionStatus on the GCURRENT = 'X' status record */
          , U.Status AS Status
            /* Subtype - Payment / Recovery */
          , U.Subtype AS Subtype
            /* TransactionSetID - 1..1, one set per ClaimCenter transaction */
          , 'mig:motorpts_' + CONVERT(VARCHAR(20), U.TranID) + U.MasterSuffix AS TransactionSetID
            /* PaymentType - partial for every migrated payment */
          , CASE WHEN U.DebitCredit = 'D' THEN 'partial' END AS PaymentType
            /* DoesNotErodeReserves - mapping says TRUE (default column says FALSE) */
          , CASE WHEN U.DebitCredit = 'D' THEN 1 END AS DoesNotErodeReserves
            /* CloseExposure / CloseClaim - DB default FALSE */
          , CASE WHEN U.DebitCredit = 'D' THEN 0 END AS CloseExposure
          , CASE WHEN U.DebitCredit = 'D' THEN 0 END AS CloseClaim
            /* CheckID - PAYMENTS ONLY, 1..1 */
          , CASE WHEN U.DebitCredit = 'D' THEN 'mig:motorchk_' + CONVERT(VARCHAR(20), U.TranID) + U.MasterSuffix END AS CheckID
            /* DenormCashMoveNo_Adm - RECOVERIES ONLY (payments carry it on the check) */
          , CASE WHEN U.DebitCredit = 'C' THEN U.CashMoveNo END AS DenormCashMoveNo_Adm
            /* ChequeNumber_Adm - RECOVERIES ONLY */
          , CASE WHEN U.DebitCredit = 'C' THEN U.ChequeNumber END AS ChequeNumber_Adm
            /* InternalCCPayRecoCurrency_Adm - TRANSFER PAYMENTS ONLY (PAY_TYPE = T, debit) */
          , CASE WHEN U.IsTransfer = 1 THEN 'gbp' END AS InternalCCPayRecoCurrency_Adm
            /* InternalCCPayRecoCat_Adm - TRANSFER on the TARGET claim: PAY_TYPE = T and CREDIT (BA transcript + mapping comment;
               the mapping sheet lists it under Payment - discrepancy, BA to confirm) */
          , CASE WHEN U.PayType = 'T' AND U.DebitCredit = 'C' THEN 'subro' END AS InternalCCPayRecoCat_Adm
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
    WHERE U.Loadable = 1;
END;
GO
