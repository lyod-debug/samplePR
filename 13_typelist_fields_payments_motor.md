# Typelist (type key) fields in the payment mapping - Motor

Source: the "Typelist" column (L) of the source-to-target pictures. A type key must be loaded as a TYPECODE.
"Mapping gives code" = the mapping text already names the typecode. "Source value" = the typecode must be worked out from a V2 value through the typelist mapping.

| Entity | Field | Typelist | How the typecode is decided | Today in my procs |
|---|---|---|---|---|
| Check | CheckBatching | CheckBatching | Source value GROUPED: N = apdefault, Y = bulkcheck | CASE in proc 05 (hardcoded) |
| Check | CheckType | CheckType | Mapping gives code: primary | hardcoded 'primary' |
| Check | ChequeStopReason_Adm | ReasonToStopCheque_Adm | Source value REASON, via typelist mapping tab | TYPELIST_TABLE_MAPPING join (proc 01) |
| Check | PaymentMethod | PaymentMethod | Source value PAY_TYPE, via typelist mapping tab | TYPELIST_TABLE_MAPPING join (proc 01) |
| Check | Status | TransactionStatus | Same as transaction Status | TYPELIST_TABLE_MAPPING join (proc 01) |
| CheckPayee | PayeeType | ContactRole | Mapping gives code: checkpayee (column of the check payee table; the claim contact ROLE row is created later in the claim contact role proc, not here) | hardcoded 'checkpayee' |
| RecoveryCoding | RecoveryCategory | RecoveryCategory | Reused from the reserve line (senior's proc) | not built here |
| Transaction | Subtype | Transaction | Mapping gives code: Payment (recoveries: Recovery, from the lookup Subtype) | hardcoded |
| Transaction | Status | TransactionStatus | Source value STATUS_TYPE (GCURRENT = X), via typelist mapping tab | TYPELIST_TABLE_MAPPING join (proc 01) |
| Transaction | RecoveryCategory | RecoveryCategory | Mapping gives code: subro (recoveries) | hardcoded 'subro' |
| Transaction | ReservingCurrency | Currency | Mapping gives code: gbp | hardcoded |
| Transaction | PaymentType | PaymentType | Mapping gives code: partial | hardcoded |
| Transaction | LifeCycleState | TransactionLifeCycleState | Based on Status, via typelist mapping tab | TYPELIST_TABLE_MAPPING join (proc 01) |
| Transaction | InternalCCPayRecoCurrency_Adm | Currency | Mapping gives code: gbp (transfers) | hardcoded |
| Transaction | InternalCCPayRecoCat_Adm | RecoveryCategory | Mapping gives code: subro (transfers) | hardcoded |
| Transaction | Currency | Currency | Mapping gives code: gbp | hardcoded |
| Transaction | CostType | CostType | Payment lookup, column CostTypeCode | Lkp_Transaction_Typelist (motor rows) |
| Transaction | CostCategory | CostCategory | Taken from the reserve line (senior's reserve procs) | from reserve line |
| LineItem | LineCategory | LineCategory | Payment lookup, column LineItem (Migrated Payment / Migrated Recovery) | from lookup |
| Set | Subtype | TransactionSet | In line with the transaction subtype (CheckSet / RecoverySet) | hardcoded |
| Set | CreatedVia | CreatedVia | Mapping gives code: manual | hardcoded |
| Set | ApprovalStatus | ApprovalStatus | Based on transaction Status, via typelist mapping tab | TYPELIST_TABLE_MAPPING join (proc 01) |

Not typelists (plain foreign keys): ClaimID, ClaimContactID, CheckID, TransactionSetID, ReserveLineID, RecoveryCodingID, ExposureID, MailingAddressID, InCareOf_Adm, users.

## What I need from you
1. Structure and a few sample rows of the typelist table(s) (cctl_* tables or whatever your senior uses) and of TYPELIST_TABLE_MAPPING.
2. Run:  SELECT DISTINCT TypeList_Name FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING ORDER BY 1;
3. Tell me whether the typecode must be looked up (and validated) for the "mapping gives code" fields too, or whether writing the code text is enough. Once I have the structure I will replace every hardcoded code with a typelist join, so a wrong or missing code is reported instead of loaded.
