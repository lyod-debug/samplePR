/* =====================================================================================
   07_usp_Load_SS_to_IS_PAYMENT_EXCEPTION_MOTOR
   REPORT ONLY. This proc never stops or fails the run and nothing is held back by it.
   Severity ISSUE    = the first problem found on a master row (the row is STILL copied to the transaction tables;
                       ClaimCenter is expected to report it as a load error, which is analysed later with the BA).
   Severity EXCLUDED = the only exclusion, stated by the mapping itself (row 136): recoveries on PA cases, when
                       @ExcludePaCredits = 1 in the master proc.
   Severity NOTE     = something to look at that is not an error (assumption applied, dummy payee ...).
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Load_SS_to_IS_PAYMENT_EXCEPTION_MOTOR
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_PAYMENT_EXCEPTION_MOTOR;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYMENT_EXCEPTION_MOTOR
        (TranID, MasterSuffix, GW_HDR_CASEID, CLAIM_REF, CaseID, CaseType, DebitCredit, CostType, MasterAmount, Severity, ExceptionCode)
    SELECT U.TranID, U.MasterSuffix, U.GW_HDR_CASEID, U.CLAIM_REF, U.CaseID, U.CaseType, U.DebitCredit, U.CostType, U.MasterAmount
         , CASE WHEN U.ExceptionCode = 'PA_CREDIT_NOT_MIGRATED' THEN 'EXCLUDED' ELSE 'ISSUE' END, U.ExceptionCode
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
    WHERE U.ExceptionCode IS NOT NULL;

    INSERT INTO IntermediateStaging_DEV.dbo.IS_PAYMENT_EXCEPTION_MOTOR
        (TranID, MasterSuffix, GW_HDR_CASEID, CLAIM_REF, CaseID, CaseType, DebitCredit, CostType, MasterAmount, Severity, ExceptionCode)
    SELECT U.TranID, U.MasterSuffix, U.GW_HDR_CASEID, U.CLAIM_REF, U.CaseID, U.CaseType, U.DebitCredit, U.CostType, U.MasterAmount
         , 'NOTE', LTRIM(RTRIM(W.value))
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR U
    CROSS APPLY STRING_SPLIT(U.WarnList, ';') W
    WHERE U.WarnList IS NOT NULL
      AND LTRIM(RTRIM(W.value)) <> '';

    /* summary: how many rows and how much money per exception */
    SELECT E.Severity, E.ExceptionCode, E.CaseType, E.DebitCredit
         , COUNT(*) AS MasterRows, SUM(E.MasterAmount) AS Amount
    FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_EXCEPTION_MOTOR E
    GROUP BY E.Severity, E.ExceptionCode, E.CaseType, E.DebitCredit
    ORDER BY E.Severity, COUNT(*) DESC;
END;
GO
