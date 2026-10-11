/* =====================================================================================
   00_DDL_payment_tables_motor.sql
   Database : IntermediateStaging_DEV
   Purpose  : Working tables + target IS tables for the MOTOR payments / recoveries load.
              The senior's reserve procs TRUNCATE IS_TRANSACTION_MOTOR, IS_TRANSACTIONSET_MOTOR,
              IS_TRANSACTIONLINEITEM_MOTOR on every run, so payments get their OWN tables (*_PAY_*).
   Safe to re-run: every table is created only if it does not exist yet.
   Types for GW_HDR_CASEID / ClaimID / PublicID follow the exposure and reserve line procs.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO

/* ------------------------------------------------------------------------------------
   W1. One row per ClaimCenter transaction (= one V2 transaction, or one part of it when
       the V2 transaction has to be split by exposure / cost type).
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_PAYMENT_MASTER_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYMENT_MASTER_MOTOR
(
    TranID                   BIGINT          NOT NULL,   /* VEC_GW_PAY_TRANS.ID                      */
    MasterSuffix               VARCHAR(10)     NOT NULL,   /* '' when the V2 transaction is not split  */
    GW_HDR_CASEID            BIGINT          NULL,
    CLAIM_REF                VARCHAR(50)     NULL,
    ClaimPublicID            VARCHAR(64)     NULL,
    CaseID                   BIGINT          NULL,       /* VEC_GW_PAY_TRANS.CASEID                  */
    CaseType                 VARCHAR(10)     NULL,       /* HDR / AD / TP / PA / UNKNOWN             */
    CASE_STATUS              VARCHAR(50)     NULL,       /* live status of CaseID (information only) */
    VectusCaseID_Adm         VARCHAR(64)     NULL,       /* case the reserve line sits on            */
    SourceOrigin_Adm         VARCHAR(50)     NULL,       /* HDR / AD / PA / TP_VEH / TP_PRO / TP_INJ / TP_HIRE */
    DebitCredit              CHAR(1)         NULL,
    Subtype                  VARCHAR(20)     NULL,       /* Payment / Recovery                       */
    CostType                 VARCHAR(20)     NULL,       /* claimcost / aoexpense                    */
    CostCategory             VARCHAR(100)    NULL,       /* AS IS from the chosen reserve line       */
    IsHire                   BIT             NULL,
    ExposureID               VARCHAR(64)     NULL,       /* NULL on claim-level (HDR) lines          */
    ReserveLineID            VARCHAR(128)    NULL,
    RecoveryCodingID         VARCHAR(128)    NULL,
    PayType                  VARCHAR(50)     NULL,
    IsTransfer               BIT             NULL,
    CurrentStatusType        VARCHAR(100)     NULL,       /* VEC_GW_PAY_STATUS.STATUS_TYPE, GCURRENT='X' */
    Status                   VARCHAR(50)     NULL,       /* cc_transaction.Status (typelist)         */
    LifeCycleState           VARCHAR(50)     NULL,
    ApprovalStatus           VARCHAR(50)     NULL,
    CreateTime               DATETIME2(7)    NULL,
    ApprovalDate             DATETIME2(7)    NULL,
    PresentedDate            DATETIME2(7)    NULL,
    PaidDate                 DATETIME2(7)    NULL,
    CanxDate                 DATETIME2(7)    NULL,
    ChequeStopReason         VARCHAR(255)    NULL,
    CashMoveNo               BIGINT          NULL,       /* CASH_MOVE_NO converted; CC field is a long integer */
    ChequeNumber             VARCHAR(255)     NULL,
    PayeeName                VARCHAR(500)    NULL,
    AccountNumber            VARCHAR(255)     NULL,
    SortCode                 VARCHAR(100)     NULL,
    Grouped                  VARCHAR(50)      NULL,
    PostCode                 VARCHAR(100)     NULL,
    AddressLine1             VARCHAR(500)    NULL,
    AddressLine2             VARCHAR(500)    NULL,
    AddressLine3             VARCHAR(500)    NULL,
    PayeeLinkID              BIGINT          NULL,
    AddLinkID                BIGINT          NULL,
    PayeeContactID           VARCHAR(64)     NULL,       /* contact PublicID                         */
    PayeeClaimContactID      VARCHAR(128)    NULL,       /* claim contact PublicID (real or dummy)   */
    InCareOfContactID        VARCHAR(64)     NULL,
    PayeeHdrID               BIGINT          NULL,       /* CONTACT RECORD (VEC_GW_CF_HDR.ID) reached through VEC_GW_CF_LINK.GWCF_HDRID of PayeeLinkID */
    InCareOfHdrID            BIGINT          NULL,       /* same, for AddLinkID                                                 */
    PayeeResolution          VARCHAR(40)     NULL,       /* OK / NO_PAYEE_LINK / LINK_NOT_IN_CF_LINK / LINK_NO_HDR / HDR_NOT_IN_CONTACT_MASTER / CONTACT_ON_OTHER_CLAIM / NO_CLAIMCONTACT */
    IsDummyPayee             BIT             NULL,
    GatewayRef               VARCHAR(255)     NULL,
    PaymentMethod            VARCHAR(50)     NULL,
    HdrAmount                DECIMAL(18,2)   NULL,       /* VEC_GW_PAY_TRANS.AMOUNT                  */
    DissSum                  DECIMAL(18,2)   NULL,       /* sum of all dissections of the V2 tran    */
    MasterAmount               DECIMAL(18,2)   NULL,       /* sum of the dissections in this master row */
    MasterCountInTran          INT             NULL,
    ExceptionCode            VARCHAR(40)     NULL,       /* first problem found (information only; the row is still copied) */
    WarnList                 VARCHAR(500)    NULL,       /* ';' separated, never blocks the load     */
    Loadable                 BIT             NOT NULL DEFAULT (1),   /* 1 = copied to the transaction tables; 0 ONLY for PA recoveries (mapping row 136) */
    CONSTRAINT PK_IS_PAYMENT_MASTER_MOTOR PRIMARY KEY CLUSTERED (TranID, MasterSuffix)
);
GO

/* ------------------------------------------------------------------------------------
   W1b. Dummy payee working tables (one row per V2 payment transaction that has no usable payee).
        Filled by usp_Load_SS_to_IS_PAYEE_DUMMY_MOTOR. Column names follow cc_contact / cc_claimcontact / cc_address.
        NOTE: if an older version of the payment working tables exists, DROP them and run this file again.
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_PAYEE_ADDRESS_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYEE_ADDRESS_PAY_MOTOR
(
    TranID          BIGINT        NOT NULL,
    GW_HDR_CASEID   BIGINT        NULL,
    CLAIM_REF       VARCHAR(50)   NULL,
    PublicID        VARCHAR(64)   NOT NULL,       /* 'mig:motorpayeeadr_'+TranID */
    AddressLine1    VARCHAR(500)  NULL,
    AddressLine2    VARCHAR(500)  NULL,
    AddressLine3    VARCHAR(500)  NULL,
    PostalCode      VARCHAR(100)   NULL,
    State           VARCHAR(50)   NULL,           /* GB_E_Adm (mapping) */
    Subtype         VARCHAR(50)   NULL,           /* Address (mapping)  */
    CONSTRAINT PK_IS_PAYEE_ADDRESS_PAY_MOTOR PRIMARY KEY CLUSTERED (TranID)
);
GO
IF OBJECT_ID('dbo.IS_PAYEE_CONTACT_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYEE_CONTACT_PAY_MOTOR
(
    TranID                  BIGINT        NOT NULL,
    GW_HDR_CASEID           BIGINT        NULL,
    CLAIM_REF               VARCHAR(50)   NULL,
    PublicID                VARCHAR(64)   NOT NULL,   /* 'mig:motorpayee_'+TranID */
    Name                    VARCHAR(500)  NULL,       /* PAYEE_NAME as it is (no cut) */
    NameLongerThan60        BIT           NULL,       /* information: the senior's contact proc cuts company names at 60 */
    Subtype                 VARCHAR(50)   NULL,       /* Company */
    AutoSync                VARCHAR(50)   NULL,       /* Disallow */
    Notes                   VARCHAR(500)  NULL,
    PreferredCurrency       VARCHAR(50)   NULL,       /* gbp */
    PreferRemitChannel_Adm  VARCHAR(50)   NULL,       /* email */
    PrimaryAddressID        VARCHAR(64)   NULL,       /* IS_PAYEE_ADDRESS_PAY_MOTOR.PublicID, NULL when no address text */
    CONSTRAINT PK_IS_PAYEE_CONTACT_PAY_MOTOR PRIMARY KEY CLUSTERED (TranID)
);
GO
IF OBJECT_ID('dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR
(
    TranID                  BIGINT        NOT NULL,
    GW_HDR_CASEID           BIGINT        NULL,
    CLAIM_REF               VARCHAR(50)   NULL,
    PublicID                VARCHAR(128)  NOT NULL,   /* 'mig:motorpayeecc_'+TranID */
    LUWID                   VARCHAR(64)   NULL,
    ClaimID                 VARCHAR(64)   NULL,
    ContactID               VARCHAR(64)   NULL,
    ClaimantFlag            BIT           NULL,       /* 0 */
    ContactNameDenorm       VARCHAR(500)  NULL,
    CONSTRAINT PK_IS_PAYEE_CLAIMCONTACT_PAY_MOTOR PRIMARY KEY CLUSTERED (TranID)
);
GO

/* ------------------------------------------------------------------------------------
   W2. One row per dissection (= one transaction line item)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_PAYMENT_MASTER_LINE_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYMENT_MASTER_LINE_MOTOR
(
    TranID        BIGINT         NOT NULL,
    MasterSuffix    VARCHAR(10)    NOT NULL,
    LineSeq       INT            NOT NULL,
    DissCode      VARCHAR(20)    NULL,        /* NULL when the transaction has no dissection row */
    Amount        DECIMAL(18,2)  NULL,
    LineItem      VARCHAR(50)    NULL,        /* Migrated Payment / Migrated Recovery (text from the lookup) */
    LineCategoryCode VARCHAR(100) NULL,       /* typecode of typelist LineCategory, found through TYPELIST_TABLE_MAPPING */
    CONSTRAINT PK_IS_PAYMENT_MASTER_LINE_MOTOR PRIMARY KEY CLUSTERED (TranID, MasterSuffix, LineSeq)
);
GO

/* ------------------------------------------------------------------------------------
   T1. Target : transaction (Payment / Recovery)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_TRANSACTION_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_TRANSACTION_PAY_MOTOR
(
    GW_HDR_CASEID                   BIGINT         NULL,
    CLAIM_REF                       VARCHAR(50)    NULL,
    VectusCaseID_Adm                VARCHAR(64)    NULL,
    SourceOrigin_Adm                VARCHAR(50)    NULL,
    CASE_STATUS                     VARCHAR(50)    NULL,
    PublicID                        VARCHAR(64)   NOT NULL,
    LUWID                           VARCHAR(64)    NULL,
    BookingDate                     DATETIME2(7)   NULL,
    LegacyCreateTime_Adm                    DATETIME2(7)   NULL,
    ClaimID                         VARCHAR(64)    NULL,
    CostCategory                    VARCHAR(50)   NULL,
    CostType                        VARCHAR(50)    NULL,
    Currency                        VARCHAR(50)    NULL,
    ExposureID                      VARCHAR(64)    NULL,
    LifeCycleState                  VARCHAR(50)    NULL,
    RecoveryCategory                VARCHAR(50)    NULL,
    RecoveryCodingID                VARCHAR(64)   NULL,
    ReserveLineID                   VARCHAR(64)   NULL,
    ReservingCurrency               VARCHAR(50)    NULL,
    Status                          VARCHAR(50)    NULL,
    Subtype                         VARCHAR(50)    NULL,
    TransactionSetID                VARCHAR(64)   NULL,
    PaymentType                     VARCHAR(50)    NULL,
    DoesNotErodeReserves            BIT            NULL,
    CloseExposure                   BIT            NULL,
    CloseClaim                      BIT            NULL,
    CheckID                         VARCHAR(64)   NULL,
    DenormCashMoveNo_Adm            BIGINT         NULL,       /* CC longint */
    ChequeNumber_Adm                VARCHAR(255)    NULL,
    InternalCCPayRecoCurrency_Adm   VARCHAR(50)    NULL,
    InternalCCPayRecoCat_Adm        VARCHAR(50)    NULL
);
GO

/* ------------------------------------------------------------------------------------
   T2. Target : transaction line item
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR
(
    GW_HDR_CASEID           BIGINT         NULL,
    CLAIM_REF               VARCHAR(50)    NULL,
    VectusCaseID_Adm        VARCHAR(64)    NULL,
    SourceOrigin_Adm        VARCHAR(50)    NULL,
    CASE_STATUS             VARCHAR(50)    NULL,
    PublicID                VARCHAR(64)   NOT NULL,
    LUWID                   VARCHAR(64)    NULL,
    LegacyCreateTime_Adm            DATETIME2(7)   NULL,
    TransactionAmount       DECIMAL(18,2)  NULL,
    ReservingForExAmount    DECIMAL(18,2)  NULL,       /* mapping: 0 (keep DB default); not a column of IS_TRANSACTIONLINEITEM */
    ReportingForExAmount    DECIMAL(18,2)  NULL,       /* mapping: 0 */
    ClaimForExAmount        DECIMAL(18,2)  NULL,       /* mapping: 0 */
    ReportingAmount         DECIMAL(18,2)  NULL,
    ClaimAmount             DECIMAL(18,2)  NULL,
    ReservingAmount         DECIMAL(18,2)  NULL,
    LineCategory            VARCHAR(50)    NULL,
    TransactionID           VARCHAR(64)   NULL
);
GO

/* ------------------------------------------------------------------------------------
   T3. Target : transaction set (one per ClaimCenter transaction; CheckSet or RecoverySet)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_TRANSACTIONSET_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_TRANSACTIONSET_PAY_MOTOR
(
    GW_HDR_CASEID      BIGINT         NULL,
    CLAIM_REF          VARCHAR(50)    NULL,
    VectusCaseID_Adm   VARCHAR(64)    NULL,
    SourceOrigin_Adm   VARCHAR(50)    NULL,
    CASE_STATUS        VARCHAR(50)    NULL,
    PublicID           VARCHAR(64)   NOT NULL,
    LUWID              VARCHAR(64)    NULL,
    ApprovalDate       DATETIME2(7)   NULL,
    ApprovalStatus     VARCHAR(50)    NULL,
    ClaimID            VARCHAR(64)    NULL,
    CreatedVia         VARCHAR(50)    NULL,
    LegacyCreateTime_Adm       DATETIME2(7)   NULL,
    RequestingUserID   VARCHAR(64)    NULL,
    Subtype            VARCHAR(50)    NULL,
    CashMoveNo_Adm     BIGINT         NULL        /* CC longint */
);
GO

/* ------------------------------------------------------------------------------------
   T4. Target : check (payments only). Columns follow ccst_check, only the ones the mapping needs
       (ids, foreign keys, NOT NULL columns, mapped columns) + debug columns.
       PayToDenorm / PayeeDenormID are NOT loaded (ClaimCenter fills denorm fields when CCST is loaded into CC).
       IS_CHECK is the common table (Motor now, the Household colleague inserts into it later);
       IS_CHECK_MOTOR is the Motor working table, same columns.
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_CHECK') IS NULL
CREATE TABLE dbo.IS_CHECK
(
    GW_HDR_CASEID                   BIGINT         NULL,       /* debug columns */
    CLAIM_REF                       VARCHAR(50)    NULL,
    VectusCaseID_Adm                VARCHAR(64)    NULL,
    SourceOrigin_Adm                VARCHAR(50)    NULL,
    CASE_STATUS                     VARCHAR(50)    NULL,
    LUWID                           VARCHAR(64)    NULL,       /* claim number */
    PublicID                        VARCHAR(64)    NOT NULL,   /* unique */
    Retired                         BIGINT         NOT NULL DEFAULT 0,   /* NOT NULL in ccst_check */
    AccountName                     VARCHAR(100)   NULL,
    BankAccountNumber               VARCHAR(20)    NULL,
    BankSortCodeStr_Adm             VARCHAR(8)     NULL,
    CheckBatching                   VARCHAR(50)    NULL,
    CheckNumber                     VARCHAR(255)   NULL,
    CheckSetID                      VARCHAR(64)    NULL,       /* FK transaction set */
    CheckType                       VARCHAR(50)    NULL,
    ChequeNumber_Adm                VARCHAR(26)    NULL,
    ChequePresentedDate_Adm         DATETIME2(7)   NULL,       /* date only: time is midnight */
    ChequeStopReason_Adm            VARCHAR(50)    NULL,
    ClaimContactID                  VARCHAR(64)    NULL,       /* FK claim contact */
    ClaimID                         VARCHAR(64)    NULL,       /* FK claim */
    DenormCashMoveNo_Adm            BIGINT         NULL,
    DenormPostalCode_Adm            VARCHAR(60)    NULL,
    EnteredTime                     DATETIME2(7)   NULL,
    InCareOf_Adm                    VARCHAR(64)    NULL,       /* FK contact */
    InternalCCPayClaimNumber_Adm    VARCHAR(255)   NULL,
    IssueDate                       DATETIME2(7)   NULL,
    MailingAddressID                VARCHAR(64)    NULL,       /* FK address - pending */
    MailTo                          VARCHAR(255)   NULL,       /* pending */
    PaymentMethod                   VARCHAR(50)    NULL,
    PayTo                           VARCHAR(255)   NULL,       /* pending */
    Status                          VARCHAR(50)    NULL,
    LegacyCreateTime_Adm            DATETIME2(7)   NULL,       /* first status record (CreateTime logic goes to legacy create time) */
    VoidStopUserID                  VARCHAR(64)    NULL        /* FK user - users not created yet, NULL */
);
GO
IF OBJECT_ID('dbo.IS_CHECK_MOTOR') IS NULL
CREATE TABLE dbo.IS_CHECK_MOTOR
(
    GW_HDR_CASEID                   BIGINT         NULL,       /* debug columns */
    CLAIM_REF                       VARCHAR(50)    NULL,
    VectusCaseID_Adm                VARCHAR(64)    NULL,
    SourceOrigin_Adm                VARCHAR(50)    NULL,
    CASE_STATUS                     VARCHAR(50)    NULL,
    LUWID                           VARCHAR(64)    NULL,       /* claim number */
    PublicID                        VARCHAR(64)    NOT NULL,   /* unique */
    Retired                         BIGINT         NOT NULL DEFAULT 0,   /* NOT NULL in ccst_check */
    AccountName                     VARCHAR(255)   NULL,
    BankAccountNumber               VARCHAR(100)    NULL,
    BankSortCodeStr_Adm             VARCHAR(50)     NULL,
    CheckBatching                   VARCHAR(50)    NULL,
    CheckNumber                     VARCHAR(255)   NULL,
    CheckSetID                      VARCHAR(64)    NULL,       /* FK transaction set */
    CheckType                       VARCHAR(50)    NULL,
    ChequeNumber_Adm                VARCHAR(100)    NULL,
    ChequePresentedDate_Adm         DATETIME2(7)   NULL,       /* date only: time is midnight */
    ChequeStopReason_Adm            VARCHAR(50)    NULL,
    ClaimContactID                  VARCHAR(64)    NULL,       /* FK claim contact */
    ClaimID                         VARCHAR(64)    NULL,       /* FK claim */
    DenormCashMoveNo_Adm            BIGINT         NULL,
    DenormPostalCode_Adm            VARCHAR(100)    NULL,
    EnteredTime                     DATETIME2(7)   NULL,
    InCareOf_Adm                    VARCHAR(64)    NULL,       /* FK contact */
    InternalCCPayClaimNumber_Adm    VARCHAR(255)   NULL,
    IssueDate                       DATETIME2(7)   NULL,
    MailingAddressID                VARCHAR(64)    NULL,       /* FK address */
    MailTo                          VARCHAR(255)   NULL,       
    PaymentMethod                   VARCHAR(50)    NULL,
    PayTo                           VARCHAR(255)   NULL,       
    Status                          VARCHAR(50)    NULL,
    LegacyCreateTime_Adm            DATETIME2(7)   NULL,       /* first status record (CreateTime logic goes to legacy create time) */
    VoidStopUserID                  VARCHAR(64)    NULL        /* FK user - users not created yet, NULL */
);
GO

/* ------------------------------------------------------------------------------------
   T5. Target : check payee (exactly one per check). Follows ccst_checkpayee without PayeeDenormID.
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_CHECKPAYEE') IS NULL
CREATE TABLE dbo.IS_CHECKPAYEE
(
    GW_HDR_CASEID                   BIGINT         NULL,       /* debug columns */
    CLAIM_REF                       VARCHAR(50)    NULL,
    VectusCaseID_Adm                VARCHAR(64)    NULL,
    SourceOrigin_Adm                VARCHAR(50)    NULL,
    CASE_STATUS                     VARCHAR(50)    NULL,
    LUWID              VARCHAR(64)    NULL,       /* claim number */
    PublicID           VARCHAR(64)    NOT NULL,   /* unique */
    CheckID            VARCHAR(64)    NULL,       /* FK check */
    ClaimContactID     VARCHAR(64)    NULL,       /* FK claim contact (NOT nullable in the sheet) */
    PayeeType          VARCHAR(50)    NULL        /* ContactRole type key, 'checkpayee' (sheet: not nullable) */
);
GO
IF OBJECT_ID('dbo.IS_CHECKPAYEE_MOTOR') IS NULL
CREATE TABLE dbo.IS_CHECKPAYEE_MOTOR
(
    GW_HDR_CASEID                   BIGINT         NULL,       /* debug columns */
    CLAIM_REF                       VARCHAR(50)    NULL,
    VectusCaseID_Adm                VARCHAR(64)    NULL,
    SourceOrigin_Adm                VARCHAR(50)    NULL,
    CASE_STATUS                     VARCHAR(50)    NULL,
    LUWID              VARCHAR(64)    NULL,       /* claim number */
    PublicID           VARCHAR(64)    NOT NULL,   /* unique */
    CheckID            VARCHAR(64)    NULL,       /* FK check */
    ClaimContactID     VARCHAR(64)    NULL,       /* FK claim contact (NOT nullable in the sheet) */
    PayeeType          VARCHAR(50)    NULL        /* ContactRole type key, 'checkpayee' (sheet: not nullable) */,
    IsDummyPayee       BIT            NULL        /* Motor working column only */
);
GO

/* ------------------------------------------------------------------------------------
   R1. Exception / warning report (rebuilt by usp_Load_SS_to_IS_PAYMENT_EXCEPTION_MOTOR)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_PAYMENT_EXCEPTION_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYMENT_EXCEPTION_MOTOR
(
    TranID           BIGINT         NOT NULL,
    MasterSuffix       VARCHAR(10)    NOT NULL,
    GW_HDR_CASEID    BIGINT         NULL,
    CLAIM_REF        VARCHAR(50)    NULL,
    CaseID           BIGINT         NULL,
    CaseType         VARCHAR(10)    NULL,
    DebitCredit      CHAR(1)        NULL,
    CostType         VARCHAR(20)    NULL,
    MasterAmount       DECIMAL(18,2)  NULL,
    Severity         VARCHAR(10)    NOT NULL,    /* ISSUE = problem found, row still copied; EXCLUDED = PA recovery (mapping row 136); NOTE = information */
    ExceptionCode    VARCHAR(40)    NOT NULL
);
GO
