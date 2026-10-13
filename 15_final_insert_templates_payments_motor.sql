/* =====================================================================================
   15_final_insert_templates_payments_motor.sql
   LATER STEP (not run now): copy the Motor payment records into the common IS tables.
   Only columns that exist in the real IS table are copied; debug columns stay in the working tables.
   The columns that are NOT copied are listed after each statement (e.g. the three ForEx amounts of the line item,
   which the mapping lists but IS_TRANSACTIONLINEITEM does not have).
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO

INSERT INTO dbo.IS_TRANSACTION (
      PublicID
    , LUWID
    , BookingDate
    , LegacyCreateTime_Adm
    , ClaimID
    , CostCategory
    , CostType
    , Currency
    , ExposureID
    , LifeCycleState
    , RecoveryCategory
    , RecoveryCodingID
    , ReserveLineID
    , ReservingCurrency
    , Status
    , Subtype
    , TransactionSetID
    , PaymentType
    , DoesNotErodeReserves
    , CloseExposure
    , CloseClaim
    , CheckID
    , DenormCashMoveNo_Adm
    , ChequeNumber_Adm
    , InternalCCPayRecoCurrency_Adm
    , InternalCCPayRecoCat_Adm
)
SELECT
      PublicID
    , LUWID
    , BookingDate
    , LegacyCreateTime_Adm
    , ClaimID
    , CostCategory
    , CostType
    , Currency
    , ExposureID
    , LifeCycleState
    , RecoveryCategory
    , RecoveryCodingID
    , ReserveLineID
    , ReservingCurrency
    , Status
    , Subtype
    , TransactionSetID
    , PaymentType
    , DoesNotErodeReserves
    , CloseExposure
    , CloseClaim
    , CheckID
    , DenormCashMoveNo_Adm
    , ChequeNumber_Adm
    , InternalCCPayRecoCurrency_Adm
    , InternalCCPayRecoCat_Adm
FROM dbo.IS_TRANSACTION_PAY_MOTOR;
/* not copied (not in IS_TRANSACTION): GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS */
GO

INSERT INTO dbo.IS_TRANSACTIONSET (
      PublicID
    , LUWID
    , ApprovalDate
    , ApprovalStatus
    , ClaimID
    , CreatedVia
    , LegacyCreateTime_Adm
    , RequestingUserID
    , Subtype
    , CashMoveNo_Adm
)
SELECT
      PublicID
    , LUWID
    , ApprovalDate
    , ApprovalStatus
    , ClaimID
    , CreatedVia
    , LegacyCreateTime_Adm
    , RequestingUserID
    , Subtype
    , CashMoveNo_Adm
FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR;
/* not copied (not in IS_TRANSACTIONSET): GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS */
GO

INSERT INTO dbo.IS_TRANSACTIONLINEITEM (
      PublicID
    , LUWID
    , LegacyCreateTime_Adm
    , TransactionAmount
    , ReportingAmount
    , ClaimAmount
    , ReservingAmount
    , LineCategory
    , TransactionID
)
SELECT
      PublicID
    , LUWID
    , LegacyCreateTime_Adm
    , TransactionAmount
    , ReportingAmount
    , ClaimAmount
    , ReservingAmount
    , LineCategory
    , TransactionID
FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR;
/* not copied (not in IS_TRANSACTIONLINEITEM): GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, ReservingForExAmount, ReportingForExAmount, ClaimForExAmount */
GO

INSERT INTO dbo.IS_CHECK (
      GW_HDR_CASEID
    , CLAIM_REF
    , VectusCaseID_Adm
    , SourceOrigin_Adm
    , CASE_STATUS
    , LUWID
    , PublicID
    , Retired
    , AccountName
    , BankAccountNumber
    , BankSortCodeStr_Adm
    , CheckBatching
    , CheckNumber
    , CheckSetID
    , CheckType
    , ChequeNumber_Adm
    , ChequePresentedDate_Adm
    , ChequeStopReason_Adm
    , ClaimContactID
    , ClaimID
    , DenormCashMoveNo_Adm
    , DenormPostalCode_Adm
    , EnteredTime
    , InCareOf_Adm
    , InternalCCPayClaimNumber_Adm
    , IssueDate
    , MailingAddressID
    , MailTo
    , PaymentMethod
    , PayTo
    , Status
    , LegacyCreateTime_Adm
    , VoidStopUserID
)
SELECT
      GW_HDR_CASEID
    , CLAIM_REF
    , VectusCaseID_Adm
    , SourceOrigin_Adm
    , CASE_STATUS
    , LUWID
    , PublicID
    , Retired
    , AccountName
    , BankAccountNumber
    , BankSortCodeStr_Adm
    , CheckBatching
    , CheckNumber
    , CheckSetID
    , CheckType
    , ChequeNumber_Adm
    , ChequePresentedDate_Adm
    , ChequeStopReason_Adm
    , ClaimContactID
    , ClaimID
    , DenormCashMoveNo_Adm
    , DenormPostalCode_Adm
    , EnteredTime
    , InCareOf_Adm
    , InternalCCPayClaimNumber_Adm
    , IssueDate
    , MailingAddressID
    , MailTo
    , PaymentMethod
    , PayTo
    , Status
    , LegacyCreateTime_Adm
    , VoidStopUserID
FROM dbo.IS_CHECK_MOTOR;
/* not copied: none */
GO

INSERT INTO dbo.IS_CHECKPAYEE (
      GW_HDR_CASEID
    , CLAIM_REF
    , VectusCaseID_Adm
    , SourceOrigin_Adm
    , CASE_STATUS
    , LUWID
    , PublicID
    , CheckID
    , ClaimContactID
    , PayeeType
)
SELECT
      GW_HDR_CASEID
    , CLAIM_REF
    , VectusCaseID_Adm
    , SourceOrigin_Adm
    , CASE_STATUS
    , LUWID
    , PublicID
    , CheckID
    , ClaimContactID
    , PayeeType
FROM dbo.IS_CHECKPAYEE_MOTOR;
/* not copied: IsDummyPayee */
GO
