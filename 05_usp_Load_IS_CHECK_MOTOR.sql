/* =====================================================================================
   05_usp_Load_IS_CHECK_MOTOR
   One cc_check per loadable PAYMENT (debit) master row. Recoveries have no check.
   PublicID: 'mig:motorchk_' + TranID + MasterSuffix.
   InCareOf_Adm     = contact of ADD_LINKID (mapping row 34), NULL if none.
   MailingAddressID = primary address of the in-care-of contact (CONTACT_MASTER_MOTOR.PrimaryAddressID), only if it exists in
                      IS_ADDRESS_CONTACT (mapping row 42).
   MailTo           = only when InCareOf_Adm is not NULL: address text of the PAYEE (lines 1-4, city, county, postcode), real payee from
                      IS_ADDRESS_CONTACT, dummy payee from IS_DUMMY_PAYEE_ADDRESS_MOTOR (mapping row 43).
   PayTo            = by contact subtype (CONTACT_MASTER_MOTOR.Subtype): Person, Doctor = FirstName + space + LastName of CONTACT_MASTER_MOTOR (the
                      contact of the check claim contact IS_CLAIMCONTACT.ContactID, mapping row 46); every other subtype (Company, CompanyVendor, AutoRepairShop,
                      LawFirm, MedicalCareOrg, LegalVenue, Contact) = company name (CONTACT_MASTER_MOTOR.Name); dummy payee (subtype Company) = its name.
   PayToDenorm      = same as PayTo (mapping row 49).
   CreateUserID and VoidStopUserID = type code 'migration user' (mapping rows 24, 53). VoidStopUserID only when the current status is CANX.
   Not loaded: PayeeDenormID. LegacyCreateTime_Adm is commented out until the column exists.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_IS_CHECK_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_CHECK_MOTOR;

    /* address work is done only for checks with an in-care-of contact (small set), not for every check */
    SELECT
        X.TranID AS TranID
      , X.MasterSuffix AS MasterSuffix
      , X.IsDummyPayee AS IsDummyPayee
      , ICM.PrimaryAddressID AS IcAddrID
      , PCM.PrimaryAddressID AS PayAddrID
    INTO #IC
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR X
    LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR ICM
           ON ICM.HDR_ID = X.InCareOfHdrID AND ICM.GW_HDR_CASEID = X.GW_HDR_CASEID AND ICM.PublicID = X.InCareOfContactID
    LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR PCM
           ON PCM.HDR_ID = X.PayeeHdrID AND PCM.GW_HDR_CASEID = X.GW_HDR_CASEID
          AND PCM.PublicID = X.PayeeContactID
          AND X.IsDummyPayee = 0
    WHERE X.DebitCredit = 'D'
      AND X.Loadable = 1
      AND X.InCareOfContactID IS NOT NULL;

    /* [added] payee contact subtype and company name, once per payee contact */
    SELECT CM.PublicID AS PublicID, MIN(CM.Subtype) AS Subtype, MIN(CM.FirstName) AS FirstName, MIN(CM.LastName) AS LastName, MIN(CM.Name) AS Name
    INTO #PAYTO
    FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM
    WHERE EXISTS (SELECT 1
                  FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR X
                  WHERE X.PayeeContactID = CM.PublicID
                    AND X.DebitCredit = 'D'
                    AND X.Loadable = 1
                    AND X.IsDummyPayee = 0)
    GROUP BY CM.PublicID;
    CREATE UNIQUE CLUSTERED INDEX IX_PAYTO ON #PAYTO (PublicID);

    SELECT A.CONTACT_ADDRESS_PUBLICID, A.AddressLine1, A.AddressLine2, A.AddressLine3, A.AddressLine4_Ext, A.City, A.County, A.PostalCode
    INTO #ADR
    FROM
    (
        SELECT
            CONVERT(VARCHAR(128), AC.CONTACT_ADDRESS_PUBLICID) AS CONTACT_ADDRESS_PUBLICID
          , AC.AddressLine1, AC.AddressLine2, AC.AddressLine3, AC.AddressLine4_Ext, AC.City, AC.County, AC.PostalCode
          , ROW_NUMBER() OVER (PARTITION BY AC.CONTACT_ADDRESS_PUBLICID ORDER BY AC.AddressLine1, AC.PostalCode) AS RN
        FROM IntermediateStaging_DEV.dbo.IS_ADDRESS_CONTACT AC
        WHERE AC.CONTACT_ADDRESS_PUBLICID IN (SELECT IcAddrID FROM #IC UNION SELECT PayAddrID FROM #IC)
    ) A
    WHERE A.RN = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_ADR ON #ADR (CONTACT_ADDRESS_PUBLICID);

    SELECT
        I.TranID AS TranID
      , I.MasterSuffix AS MasterSuffix
      , MA.CONTACT_ADDRESS_PUBLICID AS MailingAddressID
      , LEFT(NULLIF(CONCAT_WS(', '
            , NULLIF(LTRIM(RTRIM(COALESCE(PA.AddressLine1, DA.AddressLine1))), '')
            , NULLIF(LTRIM(RTRIM(COALESCE(PA.AddressLine2, DA.AddressLine2))), '')
            , NULLIF(LTRIM(RTRIM(COALESCE(PA.AddressLine3, DA.AddressLine3))), '')
            , NULLIF(LTRIM(RTRIM(PA.AddressLine4_Ext)), '')
            , NULLIF(LTRIM(RTRIM(PA.City)), '')
            , NULLIF(LTRIM(RTRIM(PA.County)), '')
            , NULLIF(LTRIM(RTRIM(COALESCE(PA.PostalCode, DA.PostalCode))), '')), ''), 255) AS MailTo
    INTO #MAIL
    FROM #IC I
    LEFT JOIN #ADR MA ON MA.CONTACT_ADDRESS_PUBLICID = I.IcAddrID
    LEFT JOIN #ADR PA ON PA.CONTACT_ADDRESS_PUBLICID = I.PayAddrID
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_ADDRESS_MOTOR DA ON DA.TranID = I.TranID AND I.IsDummyPayee = 1;
    CREATE UNIQUE CLUSTERED INDEX IX_MAIL ON #MAIL (TranID, MasterSuffix);

    INSERT INTO IntermediateStaging_DEV.dbo.IS_CHECK_MOTOR WITH (TABLOCK)
    (
        GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, PublicID, LUWID
      , AccountName, BankAccountNumber, BankSortCodeStr_Adm, CheckBatching, CheckNumber, CheckSetID, CheckType
      , ChequeNumber_Adm, ChequePresentedDate_Adm, ChequeStopReason_Adm, ClaimContactID, ClaimID
      , DenormCashMoveNo_Adm, DenormPostalCode_Adm, EnteredTime, InCareOf_Adm, InternalCCPayClaimNumber_Adm
      , IssueDate, MailingAddressID, MailTo, PaymentMethod, PayTo, PayToDenorm, Status, CreateTime /*, LegacyCreateTime_Adm*/, CreateUserID, VoidStopUserID, Retired
    )
    SELECT
        X.GW_HDR_CASEID
      , X.CLAIM_REF
      , X.VectusCaseID_Adm
      , X.SourceOrigin_Adm
      , X.CASE_STATUS
      , 'mig:motorchk_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix
      , X.CLAIM_REF
      , X.PayeeName
      , X.AccountNumber
      , X.SortCode
        /* GROUPED N = Individual payment (apdefault), Y = Bulk check (bulkcheck) */
      , CASE UPPER(X.Grouped) WHEN 'N' THEN 'apdefault' WHEN 'Y' THEN 'bulkcheck' END
        /* VEC_GW_PAY_GATEWAY.TRANS_REF */
      , X.GatewayRef
      , 'mig:motorpts_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix
      , 'primary'
      , X.ChequeNumber
        /* date only, time midnight (mapping row 18) */
      , CONVERT(DATETIME2(7), CONVERT(DATE, X.PresentedDate))
      , X.ChequeStopReason
        /* payee claim contact, or the dummy one */
      , X.PayeeClaimContactID
      , X.ClaimPublicID
      , X.CashMoveNo
      , X.PostCode
      , X.PaidDate
      , X.InCareOfContactID
        /* transfer payment only (PAY_TYPE T, debit): PAYEE_NAME holds the target claim number */
      , CASE WHEN X.IsTransfer = 1 THEN X.PayeeName END
      , X.PaidDate
      , M.MailingAddressID
      , M.MailTo
        /* payment method is on the check, also for transfer payments (typelist PaymentMethod) */
      , X.PaymentMethod
        /* PayTo and PayToDenorm (mapping rows 46, 49) */
      , P.PayToText
      , P.PayToText
      , X.Status
        /* same as transaction CreateTime (mapping row 23) */
      , X.CreateTime /*, X.CreateTime AS LegacyCreateTime_Adm*/
        /* migration user type code (mapping row 24) */
      , 'migration user'
        /* migration user type code, only if the current status is CANX (mapping row 53) */
      , CASE WHEN X.CurrentStatusType = 'CANX' THEN 'migration user' END
      , 0
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR X
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC
           ON CC.PublicID = X.PayeeClaimContactID AND CC.ClaimID = X.ClaimPublicID AND X.IsDummyPayee = 0
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR DCC
           ON DCC.PublicID = X.PayeeClaimContactID AND DCC.ClaimID = X.ClaimPublicID
    LEFT JOIN #PAYTO PC ON PC.PublicID = CC.ContactID
    LEFT JOIN #MAIL M ON M.TranID = X.TranID AND M.MasterSuffix = X.MasterSuffix
    CROSS APPLY (SELECT LEFT(CASE
                      WHEN X.IsDummyPayee = 1
                          THEN NULLIF(LTRIM(RTRIM(DCC.ContactNameDenorm)), '')
                      WHEN PC.Subtype IN ('Person', 'Doctor')
                          THEN NULLIF(LTRIM(RTRIM(CONCAT(PC.FirstName, ' ', PC.LastName))), '')
                      WHEN PC.Subtype IS NOT NULL
                          THEN NULLIF(LTRIM(RTRIM(PC.Name)), '')
                  END, 255) AS PayToText) P
    WHERE X.DebitCredit = 'D'
      AND X.Loadable = 1;

    DROP TABLE #IC;
    DROP TABLE #ADR;
    DROP TABLE #MAIL;
    DROP TABLE #PAYTO;
END;
GO
