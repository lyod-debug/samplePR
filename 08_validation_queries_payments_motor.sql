/* =====================================================================================
   08_validation_queries_payments_motor.sql
   Run after the 01..07 procs.
   V1, V3 and the dummy-payee checks of V2b must return ZERO rows (structure of my own tables).
   V2 lists foreign keys that point nowhere: such rows are EXPECTED while a reserve line, recovery coding, payee or claim contact is
   missing (the procs do not hold them back). Match each row with its ExceptionCode in IS_PAYMENT_EXCEPTION_MOTOR; they are the
   load errors to analyse later with the BA. Queries marked "report" are information.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO

/* V1. Duplicate PublicIDs (one query per table) */
SELECT 'TRANSACTION' AS Tbl, PublicID, COUNT(*) AS Cnt FROM dbo.IS_TRANSACTION_PAY_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'LINEITEM', PublicID, COUNT(*) FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'SET',      PublicID, COUNT(*) FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR      GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'CHECK',    PublicID, COUNT(*) FROM dbo.IS_CHECK_MOTOR                   GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'CHECKPAYEE', PublicID, COUNT(*) FROM dbo.IS_CHECKPAYEE_MOTOR            GROUP BY PublicID HAVING COUNT(*) > 1;

/* V2. Foreign keys that point nowhere (expected load errors, see the header of this file) */
SELECT 'TX -> CLAIM' AS Fk, T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIM_MASTER C WHERE C.PUBLICID = T.ClaimID)
UNION ALL SELECT 'TX -> RESERVELINE', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_RESERVELINE_MOTOR R WHERE R.PublicID = T.ReserveLineID)
UNION ALL SELECT 'TX -> EXPOSURE', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE T.ExposureID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IS_EXPOSURE_MOTOR E WHERE E.Exposure_Motor_PublicID = T.ExposureID)
UNION ALL SELECT 'TX -> RECOVERYCODING', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE T.Subtype = 'Recovery' AND NOT EXISTS (SELECT 1 FROM dbo.IS_RECOVERYCODING_MOTOR RC WHERE RC.PublicID = T.RecoveryCodingID)
UNION ALL SELECT 'TX -> SET', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR S WHERE S.PublicID = T.TransactionSetID)
UNION ALL SELECT 'TX -> CHECK', T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE T.Subtype = 'Payment' AND NOT EXISTS (SELECT 1 FROM dbo.IS_CHECK_MOTOR C WHERE C.PublicID = T.CheckID)
UNION ALL SELECT 'LINEITEM -> TX', L.PublicID FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR L
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_TRANSACTION_PAY_MOTOR T WHERE T.PublicID = L.TransactionID)
UNION ALL SELECT 'CHECK -> SET', C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR S WHERE S.PublicID = C.CheckSetID)
UNION ALL SELECT 'CHECKPAYEE -> CHECK', P.PublicID FROM dbo.IS_CHECKPAYEE_MOTOR P
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CHECK_MOTOR C WHERE C.PublicID = P.CheckID)
/* check pay contact foreign keys: real claim contact (IS_CLAIMCONTACT) or dummy claim contact (IS_PAYEE_CLAIMCONTACT_PAY_MOTOR) */
UNION ALL SELECT 'CHECK -> CLAIMCONTACT', C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIMCONTACT CC WHERE CC.PublicID = C.ClaimContactID)
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR D WHERE D.PublicID = C.ClaimContactID)
UNION ALL SELECT 'CHECKPAYEE -> CLAIMCONTACT', P.PublicID FROM dbo.IS_CHECKPAYEE_MOTOR P
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIMCONTACT CC WHERE CC.PublicID = P.ClaimContactID)
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR D WHERE D.PublicID = P.ClaimContactID)
UNION ALL SELECT 'CHECK.InCareOf_Adm -> CONTACT', C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE C.InCareOf_Adm IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.CONTACT_MASTER_MOTOR M WHERE M.PublicID = C.InCareOf_Adm)
UNION ALL SELECT 'CHECK.MailingAddressID -> ADDRESS', C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE C.MailingAddressID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IS_ADDRESS_CONTACT A WHERE A.CONTACT_ADDRESS_PUBLICID = C.MailingAddressID)
UNION ALL SELECT 'DUMMY CLAIMCONTACT -> DUMMY CONTACT', D.PublicID FROM dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR D
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_PAYEE_CONTACT_PAY_MOTOR C WHERE C.PublicID = D.ContactID)
UNION ALL SELECT 'DUMMY CONTACT -> DUMMY ADDRESS', C.PublicID FROM dbo.IS_PAYEE_CONTACT_PAY_MOTOR C
WHERE C.PrimaryAddressID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IS_PAYEE_ADDRESS_PAY_MOTOR A WHERE A.PublicID = C.PrimaryAddressID)
UNION ALL SELECT 'DUMMY CLAIMCONTACT -> CLAIM', D.PublicID FROM dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR D
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CLAIM_MASTER C WHERE C.PUBLICID = D.ClaimID);

/* V2b. Dummy payee: duplicate PublicIDs, and every dummy claim contact used by a check must exist (checked above) */
SELECT 'DUP DUMMY CONTACT' AS Chk, PublicID, COUNT(*) AS Cnt FROM dbo.IS_PAYEE_CONTACT_PAY_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'DUP DUMMY CLAIMCONTACT', PublicID, COUNT(*) FROM dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1
UNION ALL SELECT 'DUP DUMMY ADDRESS', PublicID, COUNT(*) FROM dbo.IS_PAYEE_ADDRESS_PAY_MOTOR GROUP BY PublicID HAVING COUNT(*) > 1;
/* dummy rows that no loaded check uses (should be 0) */
SELECT 'DUMMY CLAIMCONTACT NOT USED' AS Chk, D.PublicID FROM dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR D
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_CHECK_MOTOR C WHERE C.ClaimContactID = D.PublicID);
/* a loaded check on a dummy payee but the dummy contact was not built (run proc 01b after proc 01) - should be 0 */
SELECT 'CHECK ON DUMMY WITHOUT DUMMY ROWS' AS Chk, M.TranID, M.MasterSuffix FROM dbo.IS_PAYMENT_MASTER_MOTOR M
WHERE M.Loadable = 1 AND M.DebitCredit = 'D' AND M.IsDummyPayee = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR D WHERE D.PublicID = M.PayeeClaimContactID);

/* V2c. Pay contact rules on the check (report rows, not necessarily errors) */
/* MailTo must be filled exactly when InCareOf_Adm is filled, and the in-care-of contact normally has an address */
SELECT 'MAILTO RULE BROKEN' AS Chk, C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE (C.InCareOf_Adm IS NULL AND (C.MailTo IS NOT NULL OR C.MailingAddressID IS NOT NULL));
SELECT 'INCAREOF WITHOUT MAILINGADDRESS (report)' AS Chk, C.PublicID, C.InCareOf_Adm FROM dbo.IS_CHECK_MOTOR C
WHERE C.InCareOf_Adm IS NOT NULL AND C.MailingAddressID IS NULL;
SELECT 'INCAREOF WITHOUT MAILTO TEXT (report)' AS Chk, C.PublicID FROM dbo.IS_CHECK_MOTOR C
WHERE C.InCareOf_Adm IS NOT NULL AND C.MailTo IS NULL;
SELECT 'PAYTO EMPTY (report; company payees, BA question 27)' AS Chk, COUNT(*) AS Cnt FROM dbo.IS_CHECK_MOTOR WHERE PayTo IS NULL;
/* the check claim contact must belong to the same claim as the check */
SELECT 'CHECK CLAIMCONTACT ON OTHER CLAIM' AS Chk, C.PublicID FROM dbo.IS_CHECK_MOTOR C
INNER JOIN dbo.IS_CLAIMCONTACT CC ON CC.PublicID = C.ClaimContactID
WHERE CC.ClaimID <> C.ClaimID;
/* check payee must be the same claim contact as the check */
SELECT 'CHECKPAYEE <> CHECK CLAIMCONTACT' AS Chk, P.PublicID FROM dbo.IS_CHECKPAYEE_MOTOR P
INNER JOIN dbo.IS_CHECK_MOTOR C ON C.PublicID = P.CheckID WHERE ISNULL(P.ClaimContactID,'') <> ISNULL(C.ClaimContactID,'');

/* V3. Cardinality rules */
/* every transaction has at least one line item */
SELECT 'TX WITHOUT LINEITEM' AS Chk, T.PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR T
WHERE NOT EXISTS (SELECT 1 FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR L WHERE L.TransactionID = T.PublicID);
/* exactly one check payee per check */
SELECT 'CHECK PAYEE COUNT <> 1' AS Chk, C.PublicID, COUNT(P.PublicID) AS Payees
FROM dbo.IS_CHECK_MOTOR C LEFT JOIN dbo.IS_CHECKPAYEE_MOTOR P ON P.CheckID = C.PublicID
GROUP BY C.PublicID HAVING COUNT(P.PublicID) <> 1;
/* a transaction set belongs to exactly one transaction */
SELECT 'SET TRANSACTION COUNT <> 1' AS Chk, S.PublicID, COUNT(T.PublicID) AS Tx
FROM dbo.IS_TRANSACTIONSET_PAY_MOTOR S LEFT JOIN dbo.IS_TRANSACTION_PAY_MOTOR T ON T.TransactionSetID = S.PublicID
GROUP BY S.PublicID HAVING COUNT(T.PublicID) <> 1;
/* a check belongs to exactly one payment transaction */
SELECT 'CHECK TRANSACTION COUNT <> 1' AS Chk, C.PublicID, COUNT(T.PublicID) AS Tx
FROM dbo.IS_CHECK_MOTOR C LEFT JOIN dbo.IS_TRANSACTION_PAY_MOTOR T ON T.CheckID = C.PublicID
GROUP BY C.PublicID HAVING COUNT(T.PublicID) <> 1;
/* a payment never has a recovery coding, a recovery never has a check */
SELECT 'WRONG SUBTYPE FIELDS' AS Chk, PublicID FROM dbo.IS_TRANSACTION_PAY_MOTOR
WHERE (Subtype = 'Payment' AND (CheckID IS NULL OR RecoveryCodingID IS NOT NULL))
   OR (Subtype = 'Recovery' AND (CheckID IS NOT NULL OR RecoveryCodingID IS NULL));

/* V4. Cost type and exposure of the transaction must equal those of its reserve line */
SELECT 'COSTTYPE/EXPOSURE DIFFERS FROM RESERVE LINE' AS Chk, T.PublicID
FROM dbo.IS_TRANSACTION_PAY_MOTOR T
INNER JOIN dbo.IS_RESERVELINE_MOTOR R ON R.PublicID = T.ReserveLineID
WHERE ISNULL(R.CostType, '') <> ISNULL(T.CostType, '')
   OR ISNULL(R.CostCategory, '') <> ISNULL(T.CostCategory, '')
   OR ISNULL(R.ExposureID, '') <> ISNULL(T.ExposureID, '')
   OR ISNULL(R.ClaimID, '') <> ISNULL(T.ClaimID, '');

/* V5. Money: loaded line items must equal the V2 dissections of the loaded master rows (report: difference per case type) */
SELECT U.CaseType, U.DebitCredit
     , SUM(U.MasterAmount) AS MasterAmountLoadable
FROM dbo.IS_PAYMENT_MASTER_MOTOR U
WHERE U.Loadable = 1
GROUP BY U.CaseType, U.DebitCredit;
SELECT 'LINEITEM TOTAL' AS Chk, SUM(TransactionAmount) AS Amount FROM dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR;
/* line items vs master-row amount, master row by master row */
SELECT 'MASTER AMOUNT <> LINE SUM' AS Chk, U.TranID, U.MasterSuffix, U.MasterAmount, SUM(L.Amount) AS LineSum
FROM dbo.IS_PAYMENT_MASTER_MOTOR U
INNER JOIN dbo.IS_PAYMENT_MASTER_LINE_MOTOR L ON L.TranID = U.TranID AND L.MasterSuffix = U.MasterSuffix
WHERE U.Loadable = 1
GROUP BY U.TranID, U.MasterSuffix, U.MasterAmount
HAVING ABS(U.MasterAmount - SUM(L.Amount)) > 0.005;

/* V6. Coverage: every V2 transaction of a Motor claim is either loaded, or listed as an exception (report) */
SELECT 'V2 TRANSACTIONS' AS Chk, COUNT(*) AS Cnt
FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
WHERE EXISTS (SELECT 1 FROM dbo.IS_CLAIM_MASTER C WHERE C.GW_HDR_CASEID = PT.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR');
SELECT 'V2 TRANSACTIONS WITH AT LEAST ONE LOADED MASTER ROW' AS Chk, COUNT(DISTINCT TranID) AS Cnt FROM dbo.IS_PAYMENT_MASTER_MOTOR WHERE Loadable = 1;
SELECT 'V2 TRANSACTIONS WITH NO COPIED MASTER ROW (only PA recoveries, mapping row 136)' AS Chk, COUNT(*) AS Cnt
FROM (SELECT TranID FROM dbo.IS_PAYMENT_MASTER_MOTOR GROUP BY TranID HAVING MAX(CONVERT(INT, Loadable)) = 0) X;
/* a V2 transaction that appears in no master row at all (should be 0) */
SELECT 'V2 TRANSACTION MISSING FROM MASTER ROWS' AS Chk, PT.ID
FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
WHERE EXISTS (SELECT 1 FROM dbo.IS_CLAIM_MASTER C WHERE C.GW_HDR_CASEID = PT.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR')
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_PAYMENT_MASTER_MOTOR U WHERE U.TranID = PT.ID);

/* V7. Where the money went (report) */
SELECT U.CaseType, U.SourceOrigin_Adm, U.DebitCredit, U.CostType, COUNT(*) AS MasterRows, SUM(U.MasterAmount) AS Amount
FROM dbo.IS_PAYMENT_MASTER_MOTOR U
WHERE U.Loadable = 1
GROUP BY U.CaseType, U.SourceOrigin_Adm, U.DebitCredit, U.CostType
ORDER BY U.CaseType, U.SourceOrigin_Adm, U.DebitCredit, U.CostType;

/* V8. Exceptions (report) */
SELECT Severity, ExceptionCode, CaseType, DebitCredit, COUNT(*) AS MasterRows, SUM(MasterAmount) AS Amount
FROM dbo.IS_PAYMENT_EXCEPTION_MOTOR
GROUP BY Severity, ExceptionCode, CaseType, DebitCredit
ORDER BY Severity, COUNT(*) DESC;


/* V9. Typecodes: every fixed code the procs write must exist in the typelist (file 14 part B lists the typelist rows) */
;WITH F (TL_Name, GWCode) AS
(
    SELECT * FROM (VALUES
          ('CheckBatching','apdefault'),('CheckBatching','bulkcheck'),('CheckType','primary')
        , ('RecoveryCategory','subro'),('Currency','gbp'),('PaymentType','partial'),('CreatedVia','manual')
        , ('Transaction','Payment'),('Transaction','Recovery'),('TransactionSet','CheckSet'),('TransactionSet','RecoverySet')
        , ('CostType','claimcost'),('CostType','aoexpense')) V (TL_Name, GWCode)
)
SELECT 'TYPECODE NOT IN TYPELIST' AS Chk, F.TL_Name, F.GWCode
FROM F
WHERE NOT EXISTS (SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING T
                  WHERE LTRIM(RTRIM(T.Typelist_Name)) = F.TL_Name AND LTRIM(RTRIM(T.GW_TypeCode)) = F.GWCode
                    AND (T.[Household/Motor/Both] IS NULL OR T.[Household/Motor/Both] IN ('Motor only','Both')));

/* V9b. Lines of copied master rows without a LineCategory typecode (should be 0 unless the typelist lacks Migrated Payment / Migrated Recovery) */
SELECT 'LINE WITHOUT LINECATEGORY CODE' AS Chk, COUNT(*) AS Cnt
FROM dbo.IS_PAYMENT_MASTER_LINE_MOTOR L
JOIN dbo.IS_PAYMENT_MASTER_MOTOR U ON U.TranID = L.TranID AND U.MasterSuffix = L.MasterSuffix AND U.Loadable = 1
WHERE L.LineCategoryCode IS NULL;

/* V9c. Copied master rows whose status / lifecycle / approval / payment method code is empty (report: expected load errors) */
SELECT 'EMPTY TYPECODE' AS Chk
     , SUM(CASE WHEN Status IS NULL THEN 1 ELSE 0 END) AS NoStatus
     , SUM(CASE WHEN LifeCycleState IS NULL THEN 1 ELSE 0 END) AS NoLifeCycle
     , SUM(CASE WHEN ApprovalStatus IS NULL THEN 1 ELSE 0 END) AS NoApproval
     , SUM(CASE WHEN DebitCredit = 'D' AND PaymentMethod IS NULL THEN 1 ELSE 0 END) AS DebitNoPaymentMethod
FROM dbo.IS_PAYMENT_MASTER_MOTOR WHERE Loadable = 1;
