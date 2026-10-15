/* =====================================================================================
   01b_usp_Load_IS_DUMMY_PAYEE_MOTOR
   Dummy payee for a PAYMENT (debit) when PAYEE_LINKID is NULL / 0, not in VEC_GW_CF_LINK, the link has no CONTACT RECORD (GWCF_HDRID empty),
   or the CONTACT RECORD is not in CONTACT_MASTER_MOTOR (Payee_Contact mapping + BA). One dummy per V2 transaction (TranID).
   Run AFTER usp_Load_IS_PAYMENT_MASTER_MOTOR. Fills, in FK order:
     IS_DUMMY_PAYEE_ADDRESS_MOTOR       'mig:motorpayeeadr_' + TranID  (only when ADDRESS_LINE1-3 or POST_CODE have text)
     IS_DUMMY_PAYEE_CONTACT_MOTOR       'mig:motorpayee_'    + TranID  (Company)
     IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR  'mig:motorpayeecc_'  + TranID  (ClaimantFlag 0)
   The checkpayee ROLE row is created in usp_Load_IS_CLAIMCONTACTROLE (step 5B).
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_IS_DUMMY_PAYEE_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_ADDRESS_MOTOR;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CONTACT_MOTOR;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR;

    /* one row per V2 transaction with a loadable dummy-payee master row */
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
    WHERE M.DebitCredit = 'D'
      AND M.IsDummyPayee = 1
      AND M.Loadable = 1   /* fixed */
    GROUP BY M.TranID;
    CREATE UNIQUE CLUSTERED INDEX IX_D ON #D (TranID);

    /* 1. address, only if there is text */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_ADDRESS_MOTOR
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

    /* 2. contact, always a Company; a dummy without PAYEE_NAME is still created (Name NULL) */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CONTACT_MOTOR
        (TranID, GW_HDR_CASEID, CLAIM_REF, PublicID, Name, NameLongerThan60, Subtype, AutoSync, Notes, PreferredCurrency, PreferRemitChannel_Adm, PrimaryAddressID)
    SELECT
        D.TranID, D.GW_HDR_CASEID, D.CLAIM_REF
      , 'mig:motorpayee_' + CONVERT(VARCHAR(20), D.TranID)
      , D.PayeeName
      , CASE WHEN LEN(D.PayeeName) > 60 THEN 1 ELSE 0 END
      , 'Company'
      , 'Disallow'
      , 'Contact created for migration purpose - Do not use'
      , 'gbp'
      , 'email'
      , A.PublicID
    FROM #D D
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_ADDRESS_MOTOR A ON A.TranID = D.TranID;

    /* 3. claim contact */
    INSERT INTO IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR
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
    INNER JOIN IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CONTACT_MOTOR C ON C.TranID = D.TranID;

    DROP TABLE #D;
END;
GO
