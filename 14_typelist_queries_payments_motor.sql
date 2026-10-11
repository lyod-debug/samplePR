/* =====================================================================================
   14_typelist_queries_payments_motor
   Run each block and send me the result. Nothing here changes data.
   Assumed columns of SourceStaging.dbo.TYPELIST_TABLE_MAPPING (the ones proc 01 uses today):
        TypeList_Name, Vectus_TypeCode, GW_TypeCode, [Household/Motor/Both]
   with values 'Motor only' / 'Household only' / 'Both' / NULL in the last one (NULL rows are used for Motor).
   If block T0 shows different column names, tell me and I will change the procs.
   ===================================================================================== */

/* T0. Column names and a few rows of the typelist table */
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM SourceStaging.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'TYPELIST_TABLE_MAPPING' ORDER BY ORDINAL_POSITION;
SELECT TOP (30) * FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING;

/* T0b. Every typelist name that exists, and how many Motor / Household / Both rows each has */
SELECT TypeList_Name, [Household/Motor/Both], COUNT(*) AS Rows_
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
GROUP BY TypeList_Name, [Household/Motor/Both] ORDER BY TypeList_Name, [Household/Motor/Both];

/* -------------------------------------------------------------------------------------
   PART A. Typelists whose typecode depends on a V2 value.
   For each: (1) the typelist rows, (2) the V2 values that really occur on Motor claims,
   how many rows each has, and what they map to. MappedCode NULL = no typelist row = a problem.
   ------------------------------------------------------------------------------------- */

/* A1. CheckBatching  <- VEC_GW_PAY_TRANS.GROUPED */
SELECT * FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING WHERE TypeList_Name = 'CheckBatching';
SELECT LTRIM(RTRIM(PT.GROUPED)) AS V2_GROUPED, COUNT(*) AS Rows_, MAX(TL.GW_TypeCode) AS MappedCode
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
       ON TL.TypeList_Name = 'CheckBatching' AND LTRIM(RTRIM(TL.Vectus_TypeCode)) = LTRIM(RTRIM(PT.GROUPED))
      AND (TL.[Household/Motor/Both] IS NULL OR TL.[Household/Motor/Both] IN ('Motor only', 'Both'))
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR' AND PT.DEBIT_CREDIT = 'D'
GROUP BY LTRIM(RTRIM(PT.GROUPED)) ORDER BY COUNT(*) DESC;

/* A2. PaymentMethod  <- VEC_GW_PAY_TRANS.PAY_TYPE */
SELECT * FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING WHERE TypeList_Name = 'PaymentMethod';
SELECT LTRIM(RTRIM(PT.PAY_TYPE)) AS V2_PAY_TYPE, PT.DEBIT_CREDIT, COUNT(*) AS Rows_, MAX(TL.GW_TypeCode) AS MappedCode
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
       ON TL.TypeList_Name = 'PaymentMethod' AND LTRIM(RTRIM(TL.Vectus_TypeCode)) = LTRIM(RTRIM(PT.PAY_TYPE))
      AND (TL.[Household/Motor/Both] IS NULL OR TL.[Household/Motor/Both] IN ('Motor only', 'Both'))
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
GROUP BY LTRIM(RTRIM(PT.PAY_TYPE)), PT.DEBIT_CREDIT ORDER BY COUNT(*) DESC;

/* A3. ReasonToStopCheque_Adm  <- VEC_GW_PAY_STATUS.REASON where STATUS_TYPE = 'CANX' */
SELECT * FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING WHERE TypeList_Name = 'ReasonToStopCheque_Adm';
SELECT LTRIM(RTRIM(S.REASON)) AS V2_REASON, COUNT(*) AS Rows_, MAX(TL.GW_TypeCode) AS MappedCode
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S ON S.GW_PAY_TRAN_ID = PT.ID AND S.STATUS_TYPE = 'CANX'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
       ON TL.TypeList_Name = 'ReasonToStopCheque_Adm' AND LTRIM(RTRIM(TL.Vectus_TypeCode)) = LTRIM(RTRIM(S.REASON))
      AND (TL.[Household/Motor/Both] IS NULL OR TL.[Household/Motor/Both] IN ('Motor only', 'Both'))
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
GROUP BY LTRIM(RTRIM(S.REASON)) ORDER BY COUNT(*) DESC;

/* A4. TransactionStatus (transaction Status, check Status)  <- VEC_GW_PAY_STATUS.STATUS_TYPE where GCURRENT = 'X' */
SELECT * FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING WHERE TypeList_Name = 'TransactionStatus';
SELECT LTRIM(RTRIM(S.STATUS_TYPE)) AS V2_STATUS, PT.DEBIT_CREDIT, COUNT(*) AS Rows_, MAX(TL.GW_TypeCode) AS MappedCode
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S ON S.GW_PAY_TRAN_ID = PT.ID AND S.GCURRENT = 'X'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
       ON TL.TypeList_Name = 'TransactionStatus' AND LTRIM(RTRIM(TL.Vectus_TypeCode)) = LTRIM(RTRIM(S.STATUS_TYPE))
      AND (TL.[Household/Motor/Both] IS NULL OR TL.[Household/Motor/Both] IN ('Motor only', 'Both'))
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
GROUP BY LTRIM(RTRIM(S.STATUS_TYPE)), PT.DEBIT_CREDIT ORDER BY COUNT(*) DESC;

/* A5. TransactionLifeCycleState and ApprovalStatus  <- based on the transaction Status.
       First show the rows, so I can see whether their Vectus_TypeCode holds the V2 status (PAID) or the ClaimCenter status. */
SELECT * FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING WHERE TypeList_Name = 'TransactionLifeCycleState';
SELECT * FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING WHERE TypeList_Name = 'ApprovalStatus';

/* -------------------------------------------------------------------------------------
   PART B. Typelists where the mapping already names the typecode (primary, checkpayee, gbp ...).
   Show the typelist rows so I can see the exact GW_TypeCode spelling and whether a lookup is possible.
   ------------------------------------------------------------------------------------- */
SELECT TypeList_Name, Vectus_TypeCode, GW_TypeCode, [Household/Motor/Both]
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name IN ('CheckType', 'RecoveryCategory', 'Transaction', 'Currency', 'PaymentType',
                        'CostType', 'CostCategory', 'LineCategory', 'TransactionSet', 'CreatedVia')
ORDER BY TypeList_Name, [Household/Motor/Both], Vectus_TypeCode;

/* B2. The payment lookup values that must become typecodes (CostType, LineCategory) - what is written in the lookup today */
SELECT DISTINCT CostTypeCode, LineItem, RecoveryCategory
FROM SourceStaging.dbo.Lkp_Transaction_Typelist WHERE LOWER(LOB) = 'motor';

/* B3. Are the typecodes we need present? Expect one row each. */
SELECT TypeList_Name, GW_TypeCode FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE (TypeList_Name = 'CheckType'        AND GW_TypeCode = 'primary')
   OR (TypeList_Name = 'RecoveryCategory' AND GW_TypeCode = 'subro')
   OR (TypeList_Name = 'Currency'         AND GW_TypeCode = 'gbp')
   OR (TypeList_Name = 'PaymentType'      AND GW_TypeCode = 'partial')
   OR (TypeList_Name = 'CreatedVia'       AND GW_TypeCode = 'manual');

/* -------------------------------------------------------------------------------------
   PART C. Nullable check on the real ClaimCenter staging table (run on the database that holds cc_transaction / CCST).
   Shows whether PaymentType, RecoveryCategory, DoesNotErodeReserves, LineCategory, ApprovalDate really refuse NULL.
   ------------------------------------------------------------------------------------- */
SELECT TABLE_NAME, COLUMN_NAME, IS_NULLABLE, COLUMN_DEFAULT, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE (TABLE_NAME = 'cc_transaction'         AND COLUMN_NAME IN ('PaymentType','RecoveryCategory','DoesNotErodeReserves','ExposureID','RecoveryCodingID','CheckID'))
   OR (TABLE_NAME = 'cc_transactionlineitem' AND COLUMN_NAME IN ('LineCategory'))
   OR (TABLE_NAME = 'cc_transactionset'      AND COLUMN_NAME IN ('ApprovalDate','ApprovalStatus','RequestingUserID'));

/* -------------------------------------------------------------------------------------
   PART D. Transactions with no current status (BA question: what should happen to them).
   ------------------------------------------------------------------------------------- */
SELECT PT.DEBIT_CREDIT, COUNT(*) AS Transactions_Without_Current_Status, MIN(PT.ID) AS ExampleTranID
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
  AND NOT EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_PAY_STATUS S WHERE S.GW_PAY_TRAN_ID = PT.ID AND S.GCURRENT = 'X')
GROUP BY PT.DEBIT_CREDIT;

/* -------------------------------------------------------------------------------------
   PART E. Dummy payee: Motor payments (debits) with no usable payee link, and what V2 holds for them.
   ------------------------------------------------------------------------------------- */
SELECT PT.DEBIT_CREDIT, COUNT(*) AS Rows_, MIN(PT.ID) AS ExampleTranID
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK L ON L.ID = PT.PAYEE_LINKID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR' AND L.ID IS NULL
GROUP BY PT.DEBIT_CREDIT;


/* -------------------------------------------------------------------------------------
   PART F. Payee link vs contact master (the contact master keeps only MAX(LINK_ID) per CONTACT RECORD).
   ANSWERED: VEC_GW_CF_LINK.GWCF_HDRID points to the CONTACT RECORD (read from the senior's address proc). F1 is no longer needed; F2 is kept as a real example for the BA / senior.
   ------------------------------------------------------------------------------------- */
SELECT 'CF_LINK' AS Tbl, COLUMN_NAME, DATA_TYPE FROM SourceStaging.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'VECCASRN' AND TABLE_NAME = 'VEC_GW_CF_LINK' ORDER BY ORDINAL_POSITION;
SELECT 'CONTACT_MASTER_MOTOR' AS Tbl, COLUMN_NAME, DATA_TYPE FROM IntermediateStaging_DEV.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'CONTACT_MASTER_MOTOR' ORDER BY ORDINAL_POSITION;
/* F2: one real example of a payee link that is NOT the max link of its header: the payment, its link row, and the contact master rows of that claim */
SELECT TOP (5) P.ID AS TranID, P.GW_HDR_CASEID, P.PAYEE_LINKID, L.*
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS P ON P.GW_HDR_CASEID = CLM.GW_HDR_CASEID
JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK L ON L.ID = P.PAYEE_LINKID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR' AND P.DEBIT_CREDIT = 'D'
  AND NOT EXISTS (SELECT 1 FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM
                  WHERE CM.GW_HDR_CASEID = P.GW_HDR_CASEID AND TRY_CONVERT(BIGINT, CM.LINK_ID) = TRY_CONVERT(BIGINT, P.PAYEE_LINKID));
