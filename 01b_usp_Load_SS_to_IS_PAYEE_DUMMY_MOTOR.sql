/* =====================================================================================
   01b_usp_Load_SS_to_IS_PAYEE_DUMMY_MOTOR
   Builds the DUMMY payee: used for a PAYMENT (debit) when VEC_GW_PAY_TRANS.PAYEE_LINKID is NULL / 0 / not in VEC_GW_CF_LINK,
   or the link row has no CONTACT RECORD (GWCF_HDRID empty), or the CONTACT RECORD has no row in CONTACT_MASTER_MOTOR
   (BA rule, Payee_Contact mapping + BA transcript line 83; the last two cases added Oct 13 by user decision, listed as NOTE in the exception report). One dummy per V2 transaction (TranID); every master row of that V2 transaction shares it.
   Run AFTER usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR (it reads the master rows with IsDummyPayee = 1).
   Fills 3 working tables, in this FK order:
     IS_PAYEE_ADDRESS_PAY_MOTOR       PublicID 'mig:motorpayeeadr_' + TranID  (only when ADDRESS_LINE1-3 or POST_CODE have text)
     IS_PAYEE_CONTACT_PAY_MOTOR       PublicID 'mig:motorpayee_'    + TranID  Subtype Company (always, even if the name is a person)
     IS_PAYEE_CLAIMCONTACT_PAY_MOTOR  PublicID 'mig:motorpayeecc_'  + TranID  ClaimantFlag 0
   The checkpayee ROLE row (cc_claimcontactrole, role 'checkpayee') is NOT created here: the claim contact role proc does it.
   Values come from the Payee_Contact mapping sheet.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_PAYEE_DUMMY_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYEE_ADDRESS_PAY_MOTOR;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYEE_CONTACT_PAY_MOTOR;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR;

    /* one row per V2 transaction that has a loadable dummy-payee master row */
    IF OBJECT_ID('tempdb..#D') IS NOT NULL DROP TABLE #D;
    SELECT
            M.TranID AS TranID
          , MIN(M.GW_HDR_CASEID) AS GW_HDR_CASEID
          , MIN(M.CLAIM_REF) AS CLAIM_REF
          , MIN(M.ClaimPublicID) AS ClaimPublicID
          , MIN(NULLIF(LTRIM(RTRIM(M.PayeeName)), '')) AS PayeeName
          , MIN(NULLIF(LTRIM(RTRIM(M.AddressLine1)), '')) AS AddressLine1
          , MIN(NULLIF(LTRIM(RTRIM(M.AddressLine2)), '')) AS AddressLine2
          , MIN(NULLIF(LTRIM(RTRIM(M.AddressLine3)), '')) AS AddressLine3
          , MIN(NULLIF(LTRIM(RTRIM(M.PostCode)), '')) AS PostCode
    INTO #D
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
    WHERE M.DebitCredit = 'D' AND M.IsDummyPayee = 1
    GROUP BY M.TranID;
    CREATE UNIQUE CLUSTERED INDEX IX_D ON #D (TranID);

    /* 1. address - only "if there is something there" (BA) */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYEE_ADDRESS_PAY_MOTOR
        (TranID, GW_HDR_CASEID, CLAIM_REF, PublicID, AddressLine1, AddressLine2, AddressLine3, PostalCode, State, Subtype)
    SELECT
            D.TranID, D.GW_HDR_CASEID, D.CLAIM_REF
          , 'mig:motorpayeeadr_' + CONVERT(VARCHAR(20), D.TranID)
          , D.AddressLine1
          , D.AddressLine2
          , D.AddressLine3
          , D.PostCode
          , 'GB_E_Adm'
          , 'Address'
    FROM #D D
    WHERE D.AddressLine1 IS NOT NULL OR D.AddressLine2 IS NOT NULL OR D.AddressLine3 IS NOT NULL OR D.PostCode IS NOT NULL;

    /* 2. contact - always a Company */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYEE_CONTACT_PAY_MOTOR
        (TranID, GW_HDR_CASEID, CLAIM_REF, PublicID, Name, NameLongerThan60, Subtype, AutoSync, Notes, PreferredCurrency, PreferRemitChannel_Adm, PrimaryAddressID)
    SELECT
            D.TranID, D.GW_HDR_CASEID, D.CLAIM_REF
          , 'mig:motorpayee_' + CONVERT(VARCHAR(20), D.TranID)
          , D.PayeeName                    /* PAYEE_NAME as it is, nothing is cut */
          , CASE WHEN LEN(D.PayeeName) > 60 THEN 1 ELSE 0 END
          , 'Company'
          , 'Disallow'
          , 'Contact created for migration purpose - Do not use'
          , 'gbp'
          , 'email'
          , A.PublicID
    FROM #D D
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_PAYEE_ADDRESS_PAY_MOTOR A ON A.TranID = D.TranID
;   /* a dummy without a PAYEE_NAME is still created (Name NULL); the master proc only lists it as DUMMY_PAYEE_NO_NAME */

    /* 3. claim contact */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR
        (TranID, GW_HDR_CASEID, CLAIM_REF, PublicID, LUWID, ClaimID, ContactID, ClaimantFlag, ContactNameDenorm)
    SELECT
            D.TranID, D.GW_HDR_CASEID, D.CLAIM_REF
          , 'mig:motorpayeecc_' + CONVERT(VARCHAR(20), D.TranID)
          , D.CLAIM_REF
          , D.ClaimPublicID
          , C.PublicID
          , 0
          , C.Name
    FROM #D D
    INNER JOIN IntermediateStaging_DEV.dbo.IS_PAYEE_CONTACT_PAY_MOTOR C ON C.TranID = D.TranID;

    IF NOT EXISTS (SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING WHERE LTRIM(RTRIM(GW_TypeCode)) = 'GB_E_Adm')
        RAISERROR('WARNING usp_Load_SS_to_IS_PAYEE_DUMMY_MOTOR: GB_E_Adm (state) is not in TYPELIST_TABLE_MAPPING.', 10, 1) WITH NOWAIT;

    DROP TABLE #D;
END;
GO
