/* =====================================================================================================
   15  FINAL INSERT BLOCKS   Motor payments: from the intermediate tables into the MAIN IS tables
   Each block is pasted at the END of YOUR existing proc of the main table (after your existing SELECT-INSERT, before the final END).
   Nothing else in your procs changes. No GO, no ALTER. Not executed on SQL Server.

   Block                                   paste into your proc                        reads (my intermediate table)
   1  IS_TRANSACTION                       usp_Load_SS_to_IS_TRANSACTION               IS_TRANSACTION_PAY_MOTOR
   2  IS_TRANSACTIONSET                    usp_Load_SS_to_IS_TRANSACTIONSET            IS_TRANSACTIONSET_PAY_MOTOR
   3  IS_TRANSACTIONLINEITEM               usp_Load_SS_to_IS_TRANSACTIONLINEITEM       IS_TRANSACTIONLINEITEM_PAY_MOTOR
   4  IS_CHECK                             usp_Load_SS_to_IS_CHECK                     IS_CHECK_MOTOR
   5  IS_CHECKPAYEE                        usp_Load_SS_to_IS_CHECKPAYEE                IS_CHECKPAYEE_MOTOR
   (The names of YOUR procs are what I expect from your naming rule; use your real names.)

   RUN ORDER: my intermediate payment procs (usp_Load_IS_PAYMENT_MASTER_MOTOR ... usp_Load_IS_CHECKPAYEE_MOTOR) must have run BEFORE these five
   main procs, because the blocks read my intermediate tables. See 00_RUN_ORDER_with_EXEC_commands.sql.

   CreateTime is copied (mapping logic). LegacyCreateTime_Adm is commented out until the column exists. [NOT CONFIRMED] the main IS tables have the columns CreateTime and CreateUserID: use the query below.
   COLUMNS: only columns that exist in the main IS table are copied. The debug columns of my intermediate tables
   (GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS) are NOT copied, as for the three transaction tables.
   [NOT CONFIRMED] for IS_CHECK and IS_CHECKPAYEE: I have not seen the real column lists of the main IS_CHECK and IS_CHECKPAYEE.
   Run this and send me the result if a block fails with "invalid column name":
     SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
     FROM IntermediateStaging_DEV.INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_NAME IN ('IS_TRANSACTION','IS_TRANSACTIONSET','IS_TRANSACTIONLINEITEM','IS_CHECK','IS_CHECKPAYEE') ORDER BY TABLE_NAME, ORDINAL_POSITION;
   ===================================================================================================== */


/* ---------- BLOCK 1: paste at the end of usp_Load_SS_to_IS_TRANSACTION ---------- */
/* MOTOR PAYMENTS AND RECOVERIES */
INSERT INTO [IntermediateStaging_DEV].dbo.IS_TRANSACTION
(
      PublicID
    , LUWID
    , BookingDate
    , CreateTime /*, LegacyCreateTime_Adm*/
    , CreateUserID
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
    , CreateTime /*, LegacyCreateTime_Adm*/
    , CreateUserID
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
FROM [IntermediateStaging_DEV].dbo.IS_TRANSACTION_PAY_MOTOR;


/* ---------- BLOCK 2: paste at the end of usp_Load_SS_to_IS_TRANSACTIONSET ---------- */
/* MOTOR PAYMENTS AND RECOVERIES */
INSERT INTO [IntermediateStaging_DEV].dbo.IS_TRANSACTIONSET
(
      PublicID
    , LUWID
    , ApprovalDate
    , ApprovalStatus
    , ClaimID
    , CreatedVia
    , CreateTime /*, LegacyCreateTime_Adm*/
    , CreateUserID
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
    , CreateTime /*, LegacyCreateTime_Adm*/
    , CreateUserID
    , RequestingUserID
    , Subtype
    , CashMoveNo_Adm
FROM [IntermediateStaging_DEV].dbo.IS_TRANSACTIONSET_PAY_MOTOR;


/* ---------- BLOCK 3: paste at the end of usp_Load_SS_to_IS_TRANSACTIONLINEITEM ---------- */
/* MOTOR PAYMENTS AND RECOVERIES. Not copied (not in IS_TRANSACTIONLINEITEM): ReservingForExAmount, ReportingForExAmount, ClaimForExAmount */
INSERT INTO [IntermediateStaging_DEV].dbo.IS_TRANSACTIONLINEITEM
(
      PublicID
    , LUWID
    , CreateTime /*, LegacyCreateTime_Adm*/
    , CreateUserID
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
    , CreateTime /*, LegacyCreateTime_Adm*/
    , CreateUserID
    , TransactionAmount
    , ReportingAmount
    , ClaimAmount
    , ReservingAmount
    , LineCategory
    , TransactionID
FROM [IntermediateStaging_DEV].dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR;


/* ---------- BLOCK 4: paste at the end of usp_Load_SS_to_IS_CHECK ---------- */
/* MOTOR PAYMENTS. [NOT CONFIRMED] column list of the main IS_CHECK, see the header. */
INSERT INTO [IntermediateStaging_DEV].dbo.IS_CHECK
(
      LUWID
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
    , PayToDenorm
    , Status
    , CreateTime /*, LegacyCreateTime_Adm*/
    , CreateUserID
    , VoidStopUserID
)
SELECT
      LUWID
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
    , PayToDenorm
    , Status
    , CreateTime /*, LegacyCreateTime_Adm*/
    , CreateUserID
    , VoidStopUserID
FROM [IntermediateStaging_DEV].dbo.IS_CHECK_MOTOR;


/* ---------- BLOCK 5: paste at the end of usp_Load_SS_to_IS_CHECKPAYEE ---------- */
/* MOTOR PAYMENTS. [NOT CONFIRMED] column list of the main IS_CHECKPAYEE. Not copied: IsDummyPayee (information column of my table). */
INSERT INTO [IntermediateStaging_DEV].dbo.IS_CHECKPAYEE
(
      LUWID
    , PublicID
    , CheckID
    , ClaimContactID
    , PayeeType
)
SELECT
      LUWID
    , PublicID
    , CheckID
    , ClaimContactID
    , PayeeType
FROM [IntermediateStaging_DEV].dbo.IS_CHECKPAYEE_MOTOR;
