/* =====================================================================================
   05_usp_Load_SS_to_IS_CHECK_MOTOR
   One cc_check per PAYMENT (debit) master row, no row is held back = per ClaimCenter payment transaction.
   Recoveries (credits) have no check.
   PublicID: 'mig:motorchk_' + V2 transaction id + MasterSuffix
   Pay contact fields (mapping rows 34, 42, 43, 46):
     InCareOf_Adm     = contact of ADD_LINKID (found through the contact record, see master proc S10); NULL if none.
     MailingAddressID = primary address of that in-care-of contact (CONTACT_MASTER_MOTOR.PrimaryAddressID), only if the address
                        row exists in IS_ADDRESS_CONTACT (foreign key safe); NULL if no in-care-of contact.
     MailTo           = only when InCareOf_Adm is not NULL: the address of the PAYEE contact written as one text
                        (lines, city, county, postcode). Real payee: IS_ADDRESS_CONTACT; dummy payee: IS_PAYEE_ADDRESS_PAY_MOTOR.
     PayTo            = PersonFirstNameDenorm + space + PersonLastNameDenorm of the check's claim contact.
                        Company payees have no person name: PayTo stays NULL unless @PayToCompanyFallback = 1 (BA question 27).
   Not loaded: PayToDenorm (not a column of ccst_check; denorm fields are filled by ClaimCenter).
   CreateTime logic (first status record) goes to LegacyCreateTime_Adm.
   VoidStopUserID stays NULL until the user transformation exists.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_CHECK_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    /* 0 = mapping literally (company payee -> PayTo NULL). 1 = company payee -> ContactNameDenorm. Set after the BA answers question 27. */
    DECLARE @PayToCompanyFallback BIT = 0;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_CHECK_MOTOR;

    ;WITH X AS
    (
        SELECT U.*
        FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
        WHERE U.DebitCredit = 'D'
    )
    INSERT INTO IntermediateStaging_DEV.dbo.IS_CHECK_MOTOR
    (
          GW_HDR_CASEID, CLAIM_REF, VectusCaseID_Adm, SourceOrigin_Adm, CASE_STATUS, PublicID, LUWID
        , AccountName, BankAccountNumber, BankSortCodeStr_Adm, CheckBatching, CheckNumber, CheckSetID, CheckType
        , ChequeNumber_Adm, ChequePresentedDate_Adm, ChequeStopReason_Adm, ClaimContactID, ClaimID
        , DenormCashMoveNo_Adm, DenormPostalCode_Adm, EnteredTime, InCareOf_Adm, InternalCCPayClaimNumber_Adm
        , IssueDate, MailingAddressID, MailTo, PaymentMethod, PayTo, Status, LegacyCreateTime_Adm, VoidStopUserID, Retired
    )
    SELECT
            X.GW_HDR_CASEID AS GW_HDR_CASEID
          , X.CLAIM_REF AS CLAIM_REF
          , X.VectusCaseID_Adm AS VectusCaseID_Adm
          , X.SourceOrigin_Adm AS SourceOrigin_Adm
          , X.CASE_STATUS AS CASE_STATUS
          , 'mig:motorchk_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix AS PublicID
          , X.CLAIM_REF AS LUWID
            /* AccountName - PAYEE_NAME AS IS */
          , X.PayeeName AS AccountName
          , X.AccountNumber AS BankAccountNumber
          , X.SortCode AS BankSortCodeStr_Adm
            /* CheckBatching - GROUPED N = Individual payment (apdefault), Y = Bulk check (bulkcheck) */
          , CASE UPPER(X.Grouped) WHEN 'N' THEN 'apdefault' WHEN 'Y' THEN 'bulkcheck' END AS CheckBatching
            /* CheckNumber - VEC_GW_PAY_GATEWAY.TRANS_REF AS IS */
          , X.GatewayRef AS CheckNumber
            /* CheckSetID - same transaction set as the transactions of this V2 payment */
          , 'mig:motorpts_' + CONVERT(VARCHAR(20), X.TranID) + X.MasterSuffix AS CheckSetID
          , 'primary' AS CheckType
          , X.ChequeNumber AS ChequeNumber_Adm
            /* Mapping row 18: the field is a DATE (example 2024-01-02 00:00:00.000), so keep the date and set the time to midnight */
          , CONVERT(DATETIME2(7), CONVERT(DATE, X.PresentedDate)) AS ChequePresentedDate_Adm
            /* ChequeStopReason_Adm - only where the payment was cancelled (CANX) */
          , X.ChequeStopReason AS ChequeStopReason_Adm
            /* ClaimContactID - the payee claim contact; a dummy one when V2 has no usable payee */
          , X.PayeeClaimContactID AS ClaimContactID
          , X.ClaimPublicID AS ClaimID
          , X.CashMoveNo AS DenormCashMoveNo_Adm
          , X.PostCode AS DenormPostalCode_Adm
            /* EnteredTime / IssueDate - PAID status record */
          , X.PaidDate AS EnteredTime
            /* InCareOf_Adm - contact of ADD_LINKID, NULL if none */
          , X.InCareOfContactID AS InCareOf_Adm
            /* InternalCCPayClaimNumber_Adm - TRANSFER PAYMENTS ONLY, PAYEE_NAME holds the target claim number */
          , CASE WHEN X.IsTransfer = 1 THEN X.PayeeName END AS InternalCCPayClaimNumber_Adm
          , X.PaidDate AS IssueDate
            /* MailingAddressID / MailTo / PayTo - pending the address and contact procs */
          , MA.CONTACT_ADDRESS_PUBLICID AS MailingAddressID
          , CASE WHEN X.InCareOfContactID IS NOT NULL
                 THEN LEFT(NULLIF(CONCAT_WS(', '
                          , NULLIF(LTRIM(RTRIM(COALESCE(PA.AddressLine1, DA.AddressLine1))), '')
                          , NULLIF(LTRIM(RTRIM(COALESCE(PA.AddressLine2, DA.AddressLine2))), '')
                          , NULLIF(LTRIM(RTRIM(COALESCE(PA.AddressLine3, DA.AddressLine3))), '')
                          , NULLIF(LTRIM(RTRIM(PA.AddressLine4_Ext)), '')
                          , NULLIF(LTRIM(RTRIM(PA.City)), '')
                          , NULLIF(LTRIM(RTRIM(PA.County)), '')
                          , NULLIF(LTRIM(RTRIM(COALESCE(PA.PostalCode, DA.PostalCode))), '')), ''), 255)
            END AS MailTo
          , X.PaymentMethod AS PaymentMethod
          , LEFT(COALESCE(
                  NULLIF(LTRIM(RTRIM(CONCAT(CC.PersonFirstNameDenorm, ' ', CC.PersonLastNameDenorm))), '')
                , CASE WHEN @PayToCompanyFallback = 1 THEN COALESCE(CC.ContactNameDenorm, DCC.ContactNameDenorm) END), 255) AS PayTo
            /* Status - same as cc_transaction.Status */
          , X.Status AS Status
            /* CreateTime logic goes to LegacyCreateTime_Adm (user decision): first status record */
          , X.CreateTime AS LegacyCreateTime_Adm
            /* VoidStopUserID - migration user: users are not created yet, NULL for now */
          , NULL AS VoidStopUserID
            /* Retired - NOT NULL column in ccst_check, 0 = active */
          , 0 AS Retired
    FROM X
    /* claim contact of the payee: real one in IS_CLAIMCONTACT, dummy one in IS_PAYEE_CLAIMCONTACT_PAY_MOTOR */
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC ON CC.PublicID = X.PayeeClaimContactID
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_PAYEE_CLAIMCONTACT_PAY_MOTOR DCC ON DCC.PublicID = X.PayeeClaimContactID
    /* in-care-of contact -> its primary address, only if that address row exists */
    LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR ICM
           ON ICM.HDR_ID = X.InCareOfHdrID AND ICM.GW_HDR_CASEID = X.GW_HDR_CASEID AND ICM.PublicID = X.InCareOfContactID
    OUTER APPLY (SELECT TOP (1) AC.CONTACT_ADDRESS_PUBLICID
                 FROM IntermediateStaging_DEV.dbo.IS_ADDRESS_CONTACT AC
                 WHERE AC.CONTACT_ADDRESS_PUBLICID = ICM.PrimaryAddressID) MA
    /* payee contact -> its primary address (real) or its dummy address */
    LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR PCM
           ON PCM.HDR_ID = X.PayeeHdrID AND PCM.GW_HDR_CASEID = X.GW_HDR_CASEID AND X.IsDummyPayee = 0
    OUTER APPLY (SELECT TOP (1) AC.AddressLine1, AC.AddressLine2, AC.AddressLine3, AC.AddressLine4_Ext, AC.City, AC.County, AC.PostalCode
                 FROM IntermediateStaging_DEV.dbo.IS_ADDRESS_CONTACT AC
                 WHERE AC.CONTACT_ADDRESS_PUBLICID = PCM.PrimaryAddressID) PA
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_PAYEE_ADDRESS_PAY_MOTOR DA ON DA.TranID = X.TranID AND X.IsDummyPayee = 1;
END;
GO
