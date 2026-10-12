/* =====================================================================================================
   usp_Load_IS_CLAIMCONTACTROLE  -  v6 (Motor + Household). v6 = v5 + the lookup roles are built from EVERY link record of the contact, not only the single link kept in the contact master

   RULES USED EVERYWHERE (from the BA transcript, the mapping sheets and the loaded lookup only):
     - ExposureID is filled ONLY when the lookup column Link_to_Exposure = 'YES'. IncidentID ONLY when Link_to_Incident = 'YES'.
     - Third-party roles take the exposure / incident of their OWN TP case. NO claim-level fallback.
     - First-party roles (v2 CHANGE): Motor AD / PA roles take the exposure of THEIR OWN AD / PA case (contact CASEID = case ID, no MIN); Household has no first-party
       exposure link in the lookup (the mandatory claimant is built separately).
     - Nothing is deleted, no row is picked by ROW_NUMBER. A role without a vehicle incident is KEPT with NULL incident / exposure.
     - Mandatory roles logic and PublicID generation are NOT changed.

   v6 CHANGE (the only change versus v5):
     PROBLEM: usp_Load_IS_CONTACT_MASTER_MOTOR / _HOUSEHOLD keep ONE link per contact header (MAX(LINK_ID) per HDR_ID, steps 2-3 of both procs). Steps 1A/1B of this proc read that single
              link (C.LINK_ID / C.LINK_TYPE_ID), so a contact with several link records got the role of ONE link only. BA: "each one of the records in the link ID table will translate to a contact role in CC".
     FIX:     NEW STEP 1C builds #ROLE_LINKS_HH / #ROLE_LINKS_MOTOR = the v5 base rows (kept link, exactly as before) UNION every link of the same header read from
              SourceStaging.VECCASRN.VEC_GW_CF_LINK (GWCF_HDRID = HDR_ID) joined to VEC_GW_CFLINK_TYPE (GWCFLNK_TYPEID = ID).
              STEP 3A / 3B now read FROM #ROLE_LINKS_* instead of FROM #BASE_CONTACT_ROLE_*. Nothing else in 3A / 3B changed.
              STEP 0 and STEP 6: DROP lines for the two new temp tables.
     NEW STEP 5A (CTE ROLE_MOST_LINKED, placed just before DEDUP_ROLE): when ONE claim contact has the SAME role twice and one row carries MORE links than the other,
              the less-linked row is removed and the more-linked row stays. Example: link type P gives role R with an exposure, link type Q gives role R with Link to Exposure = NO (blank exposure)
              -> only the row with the exposure stays. Precisely: row F is removed only if another row S has the same ClaimContactID and Role, every non-blank PolicyID / ExposureID / IncidentID of F
              is equal in S, and S has a value where F is blank. Rows with CONFLICTING values (two different exposures) are NOT touched. Roles claimant, insured, reporter are never touched by 5A.
              DEDUP_ROLE now reads ROLE_MOST_LINKED instead of FINAL_ROLE; its own logic is unchanged.
     NOT CHANGED: STEP 1A / 1B (base, IS_CLAIMCONTACT join), STEP 2 (all pickers), STEP 4 (mandatory insured / reporter / claimant), the logic inside DEDUP_ROLE, the final insert and every PublicID formula.
     WHY THE MANDATORY ROLES STAY THE SAME: claimant reads #BASE_CONTACT_ROLE_* (unchanged). Insured / reporter read #LKP_ROLES_* filtered on header type 44 / 113 and use only columns that are the same for every link of
              the contact; the extra rows are identical on every column that reaches the target and are collapsed by DEDUP_ROLE. STEP 5A explicitly skips claimant, insured and reporter. The check files prove it (v5 snapshot compared with v6, mandatory roles must be identical).
     v6 ADDS ROLES, IT DOES NOT REMOVE ANY: the kept link pair is still in #ROLE_LINKS_* (first SELECT of the UNION), so every (claim contact, role) v5 produced is still produced.
              The only v5 row v6 can replace is a less-linked row of a (claim contact, role) that now also has a more-linked row (STEP 5A); it keeps the same PublicID. Check 4g lists such replacements.
     OPEN RISK (see check file): a role coming from a non-kept link may not be allowed for the contact's Subtype (the subtype is chosen in the contact master from the kept link only).

   v5 SUMMARY: (1) Motor AD and PA: no pick at all (DISTINCT list of the case's own exposure, no unique index). (2) Motor TP: pick inside ONE case only (real split).
               (3) Household TP: pick inside ONE case only (MIN of that case's PublicID) because the BA never described a household split; proc is correct whether HH splits or not.
               (4) Claimant roles are never picked: one claimant row per exposure.
   WHAT CHANGED (search for these names in the code):
     MOTOR + HOUSEHOLD  STEP 2A / 2B  #HH_INCIDENT_BY_TP_CASE and #MOTOR_INCIDENT_BY_TP_CASE = the incident OF THE PICKED EXPOSURE (no independent MIN)
     MOTOR      STEP 2B   #MOTOR_INCIDENT_BY_TP_CASE_VEH  vehicle incident = IS_EXPOSURE_MOTOR.IncidentType = 'VehicleDamage' (no IS_INCIDENT join)
                STEP 2B   #MOTOR_EXPOSURE_BY_TP_CASE_VEH  vehicle exposure of that incident (prefer TP_VEH)
                STEP 3B   #LKP_ROLES_MOTOR ExposureID / IncidentID CASE  (5 roles: repairshop, hirecompany_adm, thirdparty_adm, tpinsurer_Adm, recoveryagent)
                          Hire-versus-vehicle choice is NOT implemented: it is pending BA (the pick stays the lowest incident ID).
     HOUSEHOLD  STEP 2A   #HH_INCIDENT_BY_TP_CASE_VEH     vehicle incident = IS_INCIDENT.Subtype = 'VehicleIncident' (household incidents, third-party CASE exposures only, selected by the PublicID prefix mig:hhtp)
                STEP 2A   #HH_EXPOSURE_BY_TP_CASE_VEH     vehicle exposure of that incident
                STEP 3A   #LKP_ROLES_HH   ExposureID / IncidentID CASE   (3 roles: thirdparty_adm, tpinsurer_Adm, recoveryagent)
                          claim-level fallback REMOVED for third-party roles
     STEP 0 / STEP 6      DROP lines for the new temp tables
   Household claim-level pickers (#HH_EXPOSURE_BY_CLAIM / #HH_INCIDENT_BY_CLAIM) REMOVED: Household first-party roles have no exposure / incident link in the mapping.
   ===================================================================================================== */
USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[usp_Load_IS_CLAIMCONTACTROLE]
AS
BEGIN
    SET NOCOUNT ON;

    /* ========================================================================
       STEP 0: TRUNCATE TARGET & CLEANUP TEMP TABLES
       ======================================================================== */
    TRUNCATE TABLE [IntermediateStaging_DEV].dbo.IS_CLAIMCONTACTROLE;

    IF OBJECT_ID('tempdb..#BASE_CONTACT_ROLE_HH') IS NOT NULL DROP TABLE #BASE_CONTACT_ROLE_HH;
    IF OBJECT_ID('tempdb..#BASE_CONTACT_ROLE_MOTOR') IS NOT NULL DROP TABLE #BASE_CONTACT_ROLE_MOTOR;
    IF OBJECT_ID('tempdb..#HH_EXPOSURE_BY_TP_CASE') IS NOT NULL DROP TABLE #HH_EXPOSURE_BY_TP_CASE;
    IF OBJECT_ID('tempdb..#HH_INCIDENT_BY_TP_CASE') IS NOT NULL DROP TABLE #HH_INCIDENT_BY_TP_CASE;
    IF OBJECT_ID('tempdb..#HH_INCIDENT_BY_TP_CASE_VEH') IS NOT NULL DROP TABLE #HH_INCIDENT_BY_TP_CASE_VEH;
    IF OBJECT_ID('tempdb..#HH_EXPOSURE_BY_TP_CASE_VEH') IS NOT NULL DROP TABLE #HH_EXPOSURE_BY_TP_CASE_VEH;
    IF OBJECT_ID('tempdb..#MOTOR_EXPOSURE_BY_TP_CASE') IS NOT NULL DROP TABLE #MOTOR_EXPOSURE_BY_TP_CASE;
    IF OBJECT_ID('tempdb..#MOTOR_INCIDENT_BY_TP_CASE') IS NOT NULL DROP TABLE #MOTOR_INCIDENT_BY_TP_CASE;
    IF OBJECT_ID('tempdb..#MOTOR_EXPOSURE_BY_AD_CASE') IS NOT NULL DROP TABLE #MOTOR_EXPOSURE_BY_AD_CASE;
    IF OBJECT_ID('tempdb..#MOTOR_EXPOSURE_BY_PA_CASE') IS NOT NULL DROP TABLE #MOTOR_EXPOSURE_BY_PA_CASE;
    IF OBJECT_ID('tempdb..#MOTOR_INCIDENT_BY_TP_CASE_VEH') IS NOT NULL DROP TABLE #MOTOR_INCIDENT_BY_TP_CASE_VEH;
    IF OBJECT_ID('tempdb..#MOTOR_EXPOSURE_BY_TP_CASE_VEH') IS NOT NULL DROP TABLE #MOTOR_EXPOSURE_BY_TP_CASE_VEH;
    IF OBJECT_ID('tempdb..#ROLE_LINKS_HH') IS NOT NULL DROP TABLE #ROLE_LINKS_HH;
    IF OBJECT_ID('tempdb..#ROLE_LINKS_MOTOR') IS NOT NULL DROP TABLE #ROLE_LINKS_MOTOR;
    IF OBJECT_ID('tempdb..#LKP_ROLES_HH') IS NOT NULL DROP TABLE #LKP_ROLES_HH;
    IF OBJECT_ID('tempdb..#LKP_ROLES_MOTOR') IS NOT NULL DROP TABLE #LKP_ROLES_MOTOR;

    /* ========================================================================
       STEP 1A: HOUSEHOLD BASE CONTACT EXTRACTION r
       ======================================================================== */
    SELECT
        CLM.PublicID AS ClaimPublicID,
        CC.PublicID AS ClaimContactID,
        C.PublicID AS ContactPublicID,
        C.HDR_ID,
        C.GW_HDR_CASEID,
        C.CLAIM_REF,
        C.HDR_TYPE_ID,
        HDR_TYPE.HDR_TYPE,
        C.LINK_TYPE_ID,
        CFLINK_TYPE.LINK_TYPE,
        RSK.COVERABLE_TYPE AS RISKUNIT_COVERABLE_TYPE,
        HDR.CASEID AS V2_SubCaseID,
        'Household' AS PRODUCT
    INTO #BASE_CONTACT_ROLE_HH
    FROM [IntermediateStaging_DEV].dbo.CONTACT_MASTER_HOUSEHOLD C
    INNER JOIN [IntermediateStaging_DEV].dbo.IS_CLAIM_MASTER CLM
        ON C.GW_HDR_CASEID = CLM.GW_HDR_CASEID
       AND CLM.PRODUCT = 'HOUSEHOLD'
    INNER JOIN [IntermediateStaging_DEV].dbo.IS_CLAIMCONTACT CC
        ON CC.ContactID = C.PublicID
       AND CC.ClaimID = CLM.PublicID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR
        ON CLM.GW_HDR_CASEID = SR.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK
        ON RSK.GWP_POLICYID = SR.GWP_POLICYID
       AND RSK.PUBLICID = SR.PUBLICID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR
        ON HDR.ID = C.HDR_ID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HDR_TYPE
        ON HDR_TYPE.ID = HDR.GWCONTH_TYPEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK CF_LINK
        ON CF_LINK.ID = C.LINK_ID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CFLINK_TYPE CFLINK_TYPE
        ON C.LINK_TYPE_ID = CFLINK_TYPE.ID;

    CREATE NONCLUSTERED INDEX IX_BCR ON #BASE_CONTACT_ROLE_HH (HDR_TYPE_ID, LINK_TYPE_ID);
    CREATE NONCLUSTERED INDEX IX_BCR_CASE ON #BASE_CONTACT_ROLE_HH (V2_SubCaseID);

    /* ========================================================================
       STEP 1B: MOTOR BASE CONTACT EXTRACTION
       ======================================================================== */
    SELECT
        CLM.PublicID AS ClaimPublicID,
        CC.PublicID AS ClaimContactID,
        C.PublicID AS ContactPublicID,
        C.HDR_ID,
        C.GW_HDR_CASEID,
        C.CLAIM_REF,
        C.HDR_TYPE_ID,
        HDR_TYPE.HDR_TYPE,
        C.LINK_TYPE_ID,
        CFLINK_TYPE.LINK_TYPE,
        RSK.COVERABLE_TYPE AS RISKUNIT_COVERABLE_TYPE,
        HDR.CASEID AS V2_SubCaseID,
        'Motor' AS PRODUCT
    INTO #BASE_CONTACT_ROLE_MOTOR
    FROM [IntermediateStaging_DEV].dbo.CONTACT_MASTER_MOTOR C
    INNER JOIN [IntermediateStaging_DEV].dbo.IS_CLAIM_MASTER CLM
        ON C.GW_HDR_CASEID = CLM.GW_HDR_CASEID
       AND CLM.PRODUCT = 'MOTOR'
    INNER JOIN [IntermediateStaging_DEV].dbo.IS_CLAIMCONTACT CC
        ON CC.ContactID = C.PublicID
       AND CC.ClaimID = CLM.PublicID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR
        ON CLM.GW_HDR_CASEID = SR.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK
        ON RSK.GWP_POLICYID = SR.GWP_POLICYID
       AND RSK.PUBLICID = SR.PUBLICID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR
        ON HDR.ID = C.HDR_ID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HDR_TYPE
        ON HDR_TYPE.ID = HDR.GWCONTH_TYPEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK CF_LINK
        ON CF_LINK.ID = C.LINK_ID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CFLINK_TYPE CFLINK_TYPE
        ON C.LINK_TYPE_ID = CFLINK_TYPE.ID;

    CREATE NONCLUSTERED INDEX IX_BCRM ON #BASE_CONTACT_ROLE_MOTOR (HDR_TYPE_ID, LINK_TYPE_ID);
    CREATE NONCLUSTERED INDEX IX_BCRM_CASE ON #BASE_CONTACT_ROLE_MOTOR (V2_SubCaseID);

    /* ========================================================================
       STEP 1C (NEW IN v6): ALL LINK RECORDS OF EACH CONTACT, for the lookup roles only
       The contact master keeps ONE link per header (MAX(LINK_ID)). The role comes from the pair (header type, link type) in CLAIM_CONTACT_ROLE_LOOKUP,
       so every link TYPE the header has must be looked up, not only the kept one.
       First SELECT  = the base rows exactly as v5 (the kept link)  -> v6 can never lose a role v5 produced.
       Second SELECT = the same base rows x every link of the header in the source link table (VEC_GW_CF_LINK.GWCF_HDRID = HDR_ID) with its link type (VEC_GW_CFLINK_TYPE).
       UNION removes identical rows (same contact, same link type, same risk unit). LINK_ID itself is not needed later, only the link TYPE.
       #BASE_CONTACT_ROLE_* are NOT changed and still feed the mandatory claimant.
       ======================================================================== */
    SELECT
        B.ClaimPublicID, B.ClaimContactID, B.ContactPublicID, B.HDR_ID, B.GW_HDR_CASEID, B.CLAIM_REF,
        B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE,
        B.RISKUNIT_COVERABLE_TYPE, B.V2_SubCaseID, B.PRODUCT
    INTO #ROLE_LINKS_HH
    FROM #BASE_CONTACT_ROLE_HH B
    UNION
    SELECT
        B.ClaimPublicID, B.ClaimContactID, B.ContactPublicID, B.HDR_ID, B.GW_HDR_CASEID, B.CLAIM_REF,
        B.HDR_TYPE_ID, B.HDR_TYPE, CFLINK_TYPE.ID, CFLINK_TYPE.LINK_TYPE,
        B.RISKUNIT_COVERABLE_TYPE, B.V2_SubCaseID, B.PRODUCT
    FROM #BASE_CONTACT_ROLE_HH B
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK CF_LINK
        ON CF_LINK.GWCF_HDRID = B.HDR_ID
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_CFLINK_TYPE CFLINK_TYPE
        ON CFLINK_TYPE.ID = CF_LINK.GWCFLNK_TYPEID;

    CREATE NONCLUSTERED INDEX IX_RLH ON #ROLE_LINKS_HH (HDR_TYPE_ID, LINK_TYPE_ID);
    CREATE NONCLUSTERED INDEX IX_RLH_CASE ON #ROLE_LINKS_HH (V2_SubCaseID);

    SELECT
        B.ClaimPublicID, B.ClaimContactID, B.ContactPublicID, B.HDR_ID, B.GW_HDR_CASEID, B.CLAIM_REF,
        B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE,
        B.RISKUNIT_COVERABLE_TYPE, B.V2_SubCaseID, B.PRODUCT
    INTO #ROLE_LINKS_MOTOR
    FROM #BASE_CONTACT_ROLE_MOTOR B
    UNION
    SELECT
        B.ClaimPublicID, B.ClaimContactID, B.ContactPublicID, B.HDR_ID, B.GW_HDR_CASEID, B.CLAIM_REF,
        B.HDR_TYPE_ID, B.HDR_TYPE, CFLINK_TYPE.ID, CFLINK_TYPE.LINK_TYPE,
        B.RISKUNIT_COVERABLE_TYPE, B.V2_SubCaseID, B.PRODUCT
    FROM #BASE_CONTACT_ROLE_MOTOR B
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK CF_LINK
        ON CF_LINK.GWCF_HDRID = B.HDR_ID
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_CFLINK_TYPE CFLINK_TYPE
        ON CFLINK_TYPE.ID = CF_LINK.GWCFLNK_TYPEID;

    CREATE NONCLUSTERED INDEX IX_RLM ON #ROLE_LINKS_MOTOR (HDR_TYPE_ID, LINK_TYPE_ID);
    CREATE NONCLUSTERED INDEX IX_RLM_CASE ON #ROLE_LINKS_MOTOR (V2_SubCaseID);

    /* ========================================================================
       STEP 2A: HOUSEHOLD EXPOSURE & INCIDENT PICKERS
       ======================================================================== */
    -- Third-party case level (VectusCaseID_Adm of the mig:hhtp exposures)
    /* v5: ONE exposure per household TP case, chosen INSIDE THAT CASE ONLY (GROUP BY VectusCaseID_Adm). Never across cases.
       Why: the BA mapping says "if more than one exposure is created from a single V2 case the contact relates to, it is sufficient to link the contact to only one of the exposures".
       The BA transcript explains the split only for Motor (a vehicle+injury TP case = 2 exposures). It says nothing about a household TP case being split, so this proc must not depend on it.
       This one rule is correct in BOTH situations, so the proc is not affected by the household exposure table:
         (a) the table repeats the same PublicID on several rows (today, check H5)  -> MIN returns that same PublicID;
         (b) the table is later fixed to one row per PublicID                      -> MIN returns that PublicID;
         (c) the owner of the household exposure proc confirms a real split (2 PublicIDs for one case) -> the role gets the lowest PublicID (same result on every run), no load failure.
       The mandatory CLAIMANT role does NOT use this picker: it reads every exposure itself, so with a real split each exposure still gets its own claimant row (BA: one claimant record per exposure). */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.PublicID) AS PickedExposureID
    INTO #HH_EXPOSURE_BY_TP_CASE
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_HOUSEHOLD EXP
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.PublicID LIKE 'mig:hhtp%'   -- third-party CASE exposures only: prefix per block of the exposure proc (mig:hhtp = TP, mig:hhb = buildings, mig:hhc = contents); case IDs come from 3 tables and can repeat
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_HEBC ON #HH_EXPOSURE_BY_TP_CASE (V2_SubCaseID);

    /* The incident is the incident OF THE EXPOSURE PICKED above (so exposure and incident always belong together).
       If that exposure sits on 2 incident IDs (check H4, case 216182585) a role holds only one, so the lowest is taken (BA rule: link to only one incident of the same case).
       Scope = ONE TP case. When each exposure has exactly one incident, MIN returns that one and changes nothing. */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.IncidentID) AS PickedIncidentID
    INTO #HH_INCIDENT_BY_TP_CASE
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_HOUSEHOLD EXP
    INNER JOIN #HH_EXPOSURE_BY_TP_CASE PX
        ON PX.V2_SubCaseID = EXP.VectusCaseID_Adm
       AND PX.PickedExposureID = EXP.PublicID
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.PublicID LIKE 'mig:hhtp%'   -- third-party case exposures only (same reason as above)
      AND EXP.IncidentID IS NOT NULL
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_HIBC ON #HH_INCIDENT_BY_TP_CASE (V2_SubCaseID);

    /* CHANGE (Household): thirdparty_adm, tpinsurer_Adm, recoveryagent may only sit on a VehicleIncident (Guidewire load errors, same as Motor).
       The household exposure table has no incident type column, so for HOUSEHOLD ONLY we join IS_INCIDENT (filtered to household:
       the exposure side is IS_EXPOSURE_HOUSEHOLD and the incident ID must be a household one 'mig:HH%') to read the subtype.
       NOTHING is deleted: if the TP case has no vehicle incident, these roles keep their row and get NULL incident / NULL exposure
       (BA sees them through the HH checks). */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.IncidentID) AS PickedIncidentID
    INTO #HH_INCIDENT_BY_TP_CASE_VEH
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_HOUSEHOLD EXP
    INNER JOIN IntermediateStaging_DEV.dbo.IS_INCIDENT INC
        ON INC.PublicID = EXP.IncidentID
       AND INC.PublicID LIKE 'mig:HH%'               -- household incidents only
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.PublicID LIKE 'mig:hhtp%'   -- third-party CASE exposures only. Buildings / contents exposures can ALSO carry a vehicle incident ('mig:HH_veh<id>', no _tp), but they are not the TP case's incident
      AND EXP.IncidentID IS NOT NULL
      AND INC.Subtype = 'VehicleIncident'            -- CONFIRM column name Subtype on IS_INCIDENT (run HH check V0 first)
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_HHIBC_VEH ON #HH_INCIDENT_BY_TP_CASE_VEH (V2_SubCaseID);

    /* The vehicle EXPOSURE for the same 3 roles = the household exposure of the same TP case that sits on the picked vehicle incident. */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.PublicID) AS PickedExposureID   -- v5: lowest PublicID of THIS case on the picked vehicle incident (same reason as #HH_EXPOSURE_BY_TP_CASE)
    INTO #HH_EXPOSURE_BY_TP_CASE_VEH
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_HOUSEHOLD EXP
    INNER JOIN #HH_INCIDENT_BY_TP_CASE_VEH V
        ON V.V2_SubCaseID = EXP.VectusCaseID_Adm
       AND V.PickedIncidentID = EXP.IncidentID
    WHERE EXP.PublicID LIKE 'mig:hhtp%'   -- third-party CASE exposures only
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_HEBC_VEH ON #HH_EXPOSURE_BY_TP_CASE_VEH (V2_SubCaseID);

    /* ========================================================================
       STEP 2B: MOTOR EXPOSURE & INCIDENT PICKERS
       CHANGED (mapping-driven, see notes): the mapping sheet says which KIND of
       exposure each role links to, so each picker now only looks at that kind:
         - TP roles  ("Link to 1 of the TP exposures created from the V2 TP case")
              -> #MOTOR_EXPOSURE_BY_TP_CASE / #MOTOR_INCIDENT_BY_TP_CASE
                 keyed by TP.ID (VectusCaseID_Adm), TP_* exposures only
         - AD roles  ("ONLY link to the AD/F&T exposure")
              -> #MOTOR_EXPOSURE_BY_AD_CASE  (AD CASE level: contact CASEID = AD case ID, AD exposure only)
         - PA roles  ("Link to the 1st party BI exposure created for the V2 PA Anc Case")
              -> #MOTOR_EXPOSURE_BY_PA_CASE  (PA CASE level: contact CASEID = PA case ID, PA exposure only)
       The old claim-level pickers (any LossParty='insured' exposure / incident)
       are removed: a TP role could fall back to the 1st-party exposure/incident.
       ======================================================================== */
    -- 1. TP subcase level (VectusCaseID_Adm = TP.ID). THIS IS THE ONLY MOTOR PLACE THAT PICKS: a Motor TP case really splits into veh / inj / pro / hire exposures (BA transcript: vehicle+injury case = 2 exposures),
    --    and the BA mapping says link the contact to only one of the exposures of that same case. GROUP BY case = never across cases.
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.Exposure_Motor_PublicID) AS PickedExposureID
    INTO #MOTOR_EXPOSURE_BY_TP_CASE
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.SourceOrigin_Adm IN ('TP_VEH', 'TP_INJ', 'TP_PRO', 'TP_HIRE')
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_MEBC ON #MOTOR_EXPOSURE_BY_TP_CASE (V2_SubCaseID);

    /* CHANGE: the incident is the incident OF THE EXPOSURE THAT WAS PICKED above (same exposure row), not an independent MIN over all incidents.
       Reason: exposure IDs and incident IDs sort differently (e.g. exposure 'mig:motor_tp_hm..' sorts first, but incident 'mig:motor_fpi_tp..' / 'mig:motor_inj_tp..'
       sort before 'mig:motor_veh_HM..'), so two independent MINs can point to two different exposures of the same TP case. */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.IncidentID) AS PickedIncidentID      -- one exposure has one IncidentID; MIN only collapses identical rows
    INTO #MOTOR_INCIDENT_BY_TP_CASE
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    INNER JOIN #MOTOR_EXPOSURE_BY_TP_CASE PX
        ON PX.V2_SubCaseID = EXP.VectusCaseID_Adm
       AND PX.PickedExposureID = EXP.Exposure_Motor_PublicID
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.SourceOrigin_Adm IN ('TP_VEH', 'TP_INJ', 'TP_PRO', 'TP_HIRE')
      AND EXP.IncidentID IS NOT NULL
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_MIBC ON #MOTOR_INCIDENT_BY_TP_CASE (V2_SubCaseID);

    -- 2. 1st party AD case level: each AD case (VectusCaseID_Adm = VEC_GW_MOTOR_AD.ID) is ONE exposure ('mig:motor_ad' + AD.ID); AD is NOT split by element.
    --    There is NOTHING TO PICK here: no MIN. The contact is matched to ITS OWN AD case: contact header CASEID = AD case ID (BA example, claim 139970616).
    --    DISTINCT only lists each (case, exposure PublicID) pair once; it never chooses between different exposures.
    --    No unique index on purpose: if the exposure table ever had two DIFFERENT AD exposures for one case, both are linked (nothing is hidden, nothing stops the load);
    --    the MOTOR check M10 lists such cases (expected: 0 rows).
    SELECT DISTINCT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        EXP.Exposure_Motor_PublicID AS PickedExposureID
    INTO #MOTOR_EXPOSURE_BY_AD_CASE
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.SourceOrigin_Adm = 'AD';

    CREATE NONCLUSTERED INDEX IX_MEBAD ON #MOTOR_EXPOSURE_BY_AD_CASE (V2_SubCaseID);

    -- 3. 1st party PA case level: each PA case (VectusCaseID_Adm = VEC_PA_ANCILLARY.ID) is ONE exposure ('mig:motor_pa' + PA.ID); no MIN, same reasoning as AD. Matched by contact header CASEID = PA case ID.
    --    The exposure proc stores 'PA' for both PA and PA_PLUS (PA_PLUS is only the lookup RuleKey).
    SELECT DISTINCT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        EXP.Exposure_Motor_PublicID AS PickedExposureID
    INTO #MOTOR_EXPOSURE_BY_PA_CASE
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.SourceOrigin_Adm = 'PA';

    CREATE NONCLUSTERED INDEX IX_MEBPA ON #MOTOR_EXPOSURE_BY_PA_CASE (V2_SubCaseID);

    /* ------------------------------------------------------------------------
       LOAD-ERROR DRIVEN (not in the BA mapping sheet - comes from the CCST->CC
       validation queries): these roles may only link to certain incident types.
         repairshop / hirecompany_adm / thirdparty_adm / tpinsurer_Adm -> VehicleIncident only
         recoveryagent -> VehicleIncident only (BA)
       Same TP.ID-level pick as above, but only among incidents of that subtype.
       The subtype comes from IS_EXPOSURE_MOTOR.IncidentType (no IS_INCIDENT join). Run Part 0 of BA_evidence_motor_v3 first.
       ------------------------------------------------------------------------ */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.IncidentID) AS PickedIncidentID
    INTO #MOTOR_INCIDENT_BY_TP_CASE_VEH
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.SourceOrigin_Adm IN ('TP_VEH', 'TP_INJ', 'TP_PRO', 'TP_HIRE')
      AND EXP.IncidentID IS NOT NULL
      AND EXP.IncidentType = 'VehicleDamage'       -- vehicle incident = IncidentType 'VehicleDamage' on IS_EXPOSURE_MOTOR (TP_VEH and TP_HIRE), no IS_INCIDENT
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_MIBC_VEH ON #MOTOR_INCIDENT_BY_TP_CASE_VEH (V2_SubCaseID);

    /* BA: the 5 vehicle-incident roles also link to the CORRESPONDING vehicle exposure = the exposure
       that belongs to the picked VehicleIncident of the same TP case (prefer the TP_VEH exposure,
       else any TP_* exposure on that incident). */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        COALESCE(
            MIN(CASE WHEN EXP.SourceOrigin_Adm = 'TP_VEH' THEN EXP.Exposure_Motor_PublicID END),
            MIN(EXP.Exposure_Motor_PublicID)
        ) AS PickedExposureID
    INTO #MOTOR_EXPOSURE_BY_TP_CASE_VEH
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    INNER JOIN #MOTOR_INCIDENT_BY_TP_CASE_VEH V
        ON V.V2_SubCaseID = EXP.VectusCaseID_Adm
       AND V.PickedIncidentID = EXP.IncidentID
    WHERE EXP.SourceOrigin_Adm IN ('TP_VEH', 'TP_INJ', 'TP_PRO', 'TP_HIRE')
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_MEBC_VEH ON #MOTOR_EXPOSURE_BY_TP_CASE_VEH (V2_SubCaseID);


    /* ========================================================================
       STEP 3A: HOUSEHOLD LOOKUP ROLES POPULATION
       ======================================================================== */
    SELECT
        B.HDR_TYPE_ID,
        B.HDR_TYPE,
        B.LINK_TYPE_ID,
        B.LINK_TYPE,
        B.RISKUNIT_COVERABLE_TYPE,
        LKP.Link_to_Policy,
        B.ClaimPublicID,
        B.ContactPublicID,
        B.HDR_ID,
        B.CLAIM_REF,
        1 AS Active,
        B.ClaimContactID AS ClaimContactID,
        -- ExposureID: ONLY when the lookup says Link to Exposure = YES. The lookup's EXPOSURE text says which exposure. (same pattern as IncidentID below)
        CASE
            WHEN LKP.Link_to_Exposure = 'YES' THEN
                CASE
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%' THEN
                        CASE
                            WHEN LKP.GWCC_Role_TYPECODE IN ('thirdparty_adm', 'tpinsurer_Adm', 'recoveryagent')
                                THEN EBC_VEH.PickedExposureID   -- vehicle roles: the VEHICLE exposure of their own TP case
                            ELSE EBC.PickedExposureID   -- other TP roles: the exposure of their OWN TP case. No claim-level fallback.
                        END
                    /* first-party Household: the lookup has no first-party row with Link to Exposure = YES (claimant is built separately).
                       If the mapping sheet gets one, add its branch here. */
                    ELSE NULL
                END
            ELSE NULL
        END AS ExposureID,
        -- IncidentID: ONLY when the lookup says Link to Incident = YES. Same pattern as ExposureID above.
        CASE
            WHEN LKP.Link_to_Incident = 'YES' THEN
                CASE
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%' THEN
                        CASE
                            WHEN LKP.GWCC_Role_TYPECODE IN ('thirdparty_adm', 'tpinsurer_Adm', 'recoveryagent')
                                THEN IBC_VEH.PickedIncidentID   -- vehicle roles: the VEHICLE incident of their own TP case (Guidewire accepts only VehicleIncident). None = NULL, role kept.
                            ELSE IBC.PickedIncidentID   -- other TP roles: the incident of their OWN TP case. No claim-level fallback.
                        END
                    ELSE NULL   -- incidents exist only for TP cases; first-party roles have Link to Incident = NO in the lookup
                END
            ELSE NULL
        END AS IncidentID,
        CASE WHEN LKP.Link_to_Policy = 'YES' THEN B.ClaimPublicID ELSE NULL END AS PolicyID,
        LKP.GWCC_Role_TYPECODE AS Role,
        'Household' AS PRODUCT
    INTO #LKP_ROLES_HH
    FROM #ROLE_LINKS_HH B   -- v6: every link of the contact (was #BASE_CONTACT_ROLE_HH = kept link only)
    LEFT JOIN dbo.CLAIM_CONTACT_ROLE_LOOKUP LKP
        ON LKP.PRODUCT = 'Household'
       AND LKP.HDR_TYPEID = B.HDR_TYPE_ID
       AND LKP.LINK_TYPEID = B.LINK_TYPE_ID
       AND (
            LKP.RISKUNIT_COVERABLE_TYPE = B.RISKUNIT_COVERABLE_TYPE
            OR (
                LKP.RISKUNIT_COVERABLE_TYPE IS NULL
                AND NOT EXISTS (
                    SELECT 1
                    FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP X
                    WHERE X.PRODUCT = LKP.PRODUCT
                      AND X.HDR_TYPEID = LKP.HDR_TYPEID
                      AND X.LINK_TYPEID = LKP.LINK_TYPEID
                      AND X.RISKUNIT_COVERABLE_TYPE = B.RISKUNIT_COVERABLE_TYPE
                )
            )
        )
    LEFT JOIN #HH_EXPOSURE_BY_TP_CASE EBC
        ON EBC.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #HH_INCIDENT_BY_TP_CASE IBC
        ON IBC.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #HH_INCIDENT_BY_TP_CASE_VEH IBC_VEH
        ON IBC_VEH.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #HH_EXPOSURE_BY_TP_CASE_VEH EBC_VEH
        ON EBC_VEH.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID);

    CREATE NONCLUSTERED INDEX IX_LKP ON #LKP_ROLES_HH (HDR_TYPE_ID);

    /* ========================================================================
       STEP 3B: MOTOR LOOKUP ROLES POPULATION
       ======================================================================== */
    SELECT
        B.HDR_TYPE_ID,
        B.HDR_TYPE,
        B.LINK_TYPE_ID,
        B.LINK_TYPE,
        B.RISKUNIT_COVERABLE_TYPE,
        LKP.Link_to_Policy,
        B.ClaimPublicID,
        B.ContactPublicID,
        B.HDR_ID,
        B.CLAIM_REF,
        1 AS Active,
        B.ClaimContactID AS ClaimContactID,
        -- ExposureID: ONLY when the lookup says Link to Exposure = YES. The lookup's EXPOSURE text says which exposure. (same pattern as IncidentID below)
        CASE
            WHEN LKP.Link_to_Exposure = 'YES' THEN
                CASE
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%' THEN
                        CASE
                            WHEN LKP.GWCC_Role_TYPECODE IN ('repairshop', 'hirecompany_adm', 'thirdparty_adm', 'tpinsurer_Adm', 'recoveryagent')
                                THEN EBC_VEH.PickedExposureID   -- vehicle roles: the VEHICLE exposure of their own TP case
                            ELSE EBC.PickedExposureID   -- other TP roles: the exposure of their OWN TP case. No claim-level fallback.
                        END
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%ANCILLARY%'    THEN EBPA.PickedExposureID   -- first party: the PA exposure of the contact's OWN PA case (CASEID = PA case ID)
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%MOTOR AD%'     THEN EBAD.PickedExposureID      -- first party: the AD exposure of the contact's OWN AD case (CASEID = AD case ID)
                    ELSE NULL
                END
            ELSE NULL
        END AS ExposureID,
        -- IncidentID: ONLY when the lookup says Link to Incident = YES. Same pattern as ExposureID above.
        CASE
            WHEN LKP.Link_to_Incident = 'YES' THEN
                CASE
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%' THEN
                        CASE
                            WHEN LKP.GWCC_Role_TYPECODE IN ('repairshop', 'hirecompany_adm', 'thirdparty_adm', 'tpinsurer_Adm', 'recoveryagent')
                                THEN IBC_VEH.PickedIncidentID   -- vehicle roles: the VEHICLE incident of their own TP case (Guidewire accepts only VehicleIncident). None = NULL, role kept.
                            ELSE IBC.PickedIncidentID   -- other TP roles: the incident of their OWN TP case. No claim-level fallback.
                        END
                    ELSE NULL   -- incidents exist only for TP cases; first-party roles have Link to Incident = NO in the lookup
                END
            ELSE NULL
        END AS IncidentID,
        CASE WHEN LKP.Link_to_Policy = 'YES' THEN B.ClaimPublicID ELSE NULL END AS PolicyID,
        LKP.GWCC_Role_TYPECODE AS Role,
        'Motor' AS PRODUCT
    INTO #LKP_ROLES_MOTOR
    FROM #ROLE_LINKS_MOTOR B   -- v6: every link of the contact (was #BASE_CONTACT_ROLE_MOTOR = kept link only)
    LEFT JOIN dbo.CLAIM_CONTACT_ROLE_LOOKUP LKP
        ON LKP.PRODUCT = 'Motor'
       AND LKP.HDR_TYPEID = B.HDR_TYPE_ID
       AND LKP.LINK_TYPEID = B.LINK_TYPE_ID
       AND (
            LKP.RISKUNIT_COVERABLE_TYPE = B.RISKUNIT_COVERABLE_TYPE
            OR (
                LKP.RISKUNIT_COVERABLE_TYPE IS NULL
                AND NOT EXISTS (
                    SELECT 1
                    FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP X
                    WHERE X.PRODUCT = LKP.PRODUCT
                      AND X.HDR_TYPEID = LKP.HDR_TYPEID
                      AND X.LINK_TYPEID = LKP.LINK_TYPEID
                      AND X.RISKUNIT_COVERABLE_TYPE = B.RISKUNIT_COVERABLE_TYPE
                )
            )
        )
    LEFT JOIN #MOTOR_EXPOSURE_BY_TP_CASE EBC
        ON EBC.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #MOTOR_INCIDENT_BY_TP_CASE IBC
        ON IBC.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #MOTOR_EXPOSURE_BY_TP_CASE_VEH EBC_VEH
        ON EBC_VEH.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #MOTOR_INCIDENT_BY_TP_CASE_VEH IBC_VEH
        ON IBC_VEH.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #MOTOR_EXPOSURE_BY_AD_CASE EBAD
        ON EBAD.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #MOTOR_EXPOSURE_BY_PA_CASE EBPA
        ON EBPA.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID);

    CREATE NONCLUSTERED INDEX IX_LKPM ON #LKP_ROLES_MOTOR (HDR_TYPE_ID);

    /* ========================================================================
       STEP 4: MANDATORY ROLES (100% UNTOUCHED FROM WORKING VERSION)
       ======================================================================== */
    ;WITH
    /* --- Household Mandatory Insured & Reporter --- */
    MANDATORY_INSURED_ROLE_HH AS (
        SELECT
            B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE,
            'YES' AS Link_to_Policy, B.ClaimPublicID, B.ContactPublicID, B.HDR_ID, B.CLAIM_REF,
            1 AS Active, B.ClaimContactID, NULL AS ExposureID, NULL AS IncidentID,
            B.ClaimPublicID AS PolicyID, 'insured' AS Role, 'Household' AS PRODUCT
        FROM #LKP_ROLES_HH B
        WHERE B.HDR_TYPE_ID = 113
    ),
    MANDATORY_REPORTER_ROLE_HH AS (
        SELECT
            B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE,
            'NO' AS Link_to_Policy, B.ClaimPublicID, B.ContactPublicID, B.HDR_ID, B.CLAIM_REF,
            1 AS Active, B.ClaimContactID, NULL AS ExposureID, NULL AS IncidentID,
            NULL AS PolicyID, 'reporter' AS Role, 'Household' AS PRODUCT
        FROM #LKP_ROLES_HH B
        WHERE B.HDR_TYPE_ID = 113
    ),

    /* --- Household Mandatory Claimant (Per Exposure) --- */
    MANDATORY_CLAIMANT_ROLE_HH AS (
        /* 1st Party HH Exposures -> Policyholder (HDR 113)*/
        SELECT
            113 AS HDR_TYPE_ID, 'Policy Holder' AS HDR_TYPE, NULL AS LINK_TYPE_ID, NULL AS LINK_TYPE, NULL AS RISKUNIT_COVERABLE_TYPE,
            'NO' AS Link_to_Policy, EXP.ClaimID AS ClaimPublicID, B.ContactPublicID, B.HDR_ID, CLM.CLAIM_REF, 1 AS Active,
            B.ClaimContactID, EXP.PublicID AS ExposureID, NULL AS IncidentID, NULL AS PolicyID,
            'claimant' AS Role, 'Household' AS PRODUCT
        FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_HOUSEHOLD EXP
        INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
            ON CLM.PublicID = EXP.ClaimID
        INNER JOIN (
            SELECT DISTINCT ClaimPublicID, ClaimContactID, ContactPublicID, HDR_ID
            FROM #BASE_CONTACT_ROLE_HH
            WHERE HDR_TYPE_ID = 113
        ) B ON B.ClaimPublicID = EXP.ClaimID
        WHERE EXP.LossParty = 'insured'

        UNION ALL

        /* 3rd Party HH Exposures -> Third Party Contact (HDR 127)*/
        SELECT
            127 AS HDR_TYPE_ID, 'Third Party' AS HDR_TYPE, NULL AS LINK_TYPE_ID, NULL AS LINK_TYPE, NULL AS RISKUNIT_COVERABLE_TYPE,
            'NO' AS Link_to_Policy, EXP.ClaimID AS ClaimPublicID, TPC.ContactPublicID, TPC.HDR_ID, CLM.CLAIM_REF, 1 AS Active,
            TPC.ClaimContactID, EXP.PublicID AS ExposureID, NULL AS IncidentID, NULL AS PolicyID,
            'claimant' AS Role, 'Household' AS PRODUCT
        FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_HOUSEHOLD EXP
        INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
            ON CLM.PublicID = EXP.ClaimID
        INNER JOIN (
            SELECT DISTINCT V2_SubCaseID, ClaimContactID, ContactPublicID, HDR_ID
            FROM #BASE_CONTACT_ROLE_HH
            WHERE HDR_TYPE_ID = 127
        ) TPC ON TPC.V2_SubCaseID = CONVERT(VARCHAR(64), EXP.VectusCaseID_Adm)
        WHERE EXP.LossParty = 'third_party'
          AND EXP.PublicID LIKE 'mig:hhtp%'   -- same prefix filter as the pickers: Household case IDs come from 3 tables and can repeat
    ),

    /* --- Motor Mandatory Insured & Reporter --- */
    MANDATORY_INSURED_ROLE_MOTOR AS (
        SELECT
            B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE,
            'YES' AS Link_to_Policy, B.ClaimPublicID, B.ContactPublicID, B.HDR_ID, B.CLAIM_REF,
            1 AS Active, B.ClaimContactID, NULL AS ExposureID, NULL AS IncidentID,
            B.ClaimPublicID AS PolicyID, 'insured' AS Role, 'Motor' AS PRODUCT
        FROM #LKP_ROLES_MOTOR B
        WHERE B.HDR_TYPE_ID = 44
    ),
    MANDATORY_REPORTER_ROLE_MOTOR AS (
        SELECT
            B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE,
            'NO' AS Link_to_Policy, B.ClaimPublicID, B.ContactPublicID, B.HDR_ID, B.CLAIM_REF,
            1 AS Active, B.ClaimContactID, NULL AS ExposureID, NULL AS IncidentID,
            NULL AS PolicyID, 'reporter' AS Role, 'Motor' AS PRODUCT
        FROM #LKP_ROLES_MOTOR B
        WHERE B.HDR_TYPE_ID = 44
    ),

    /* --- Motor Mandatory Claimant (Per Exposure) --- */
    MANDATORY_CLAIMANT_ROLE_MOTOR AS (
        /* 1st Party Motor Exposures -> Policyholder (HDR 44)*/
        SELECT
            44 AS HDR_TYPE_ID, 'Policy Holder' AS HDR_TYPE, NULL AS LINK_TYPE_ID, NULL AS LINK_TYPE, NULL AS RISKUNIT_COVERABLE_TYPE,
            'NO' AS Link_to_Policy, EXP.ClaimID AS ClaimPublicID, B.ContactPublicID, B.HDR_ID, EXP.CLAIM_REF, 1 AS Active,
            B.ClaimContactID, EXP.Exposure_Motor_PublicID AS ExposureID, NULL AS IncidentID, NULL AS PolicyID,
            'claimant' AS Role, 'Motor' AS PRODUCT
        FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
        INNER JOIN (
            SELECT DISTINCT ClaimPublicID, ClaimContactID, ContactPublicID, HDR_ID
            FROM #BASE_CONTACT_ROLE_MOTOR
            WHERE HDR_TYPE_ID = 44
        ) B ON B.ClaimPublicID = EXP.ClaimID
        WHERE EXP.LossParty = 'insured'

        UNION ALL

        /* 3rd Party Motor Exposures -> Third Party Contact (HDR 55)*/
        SELECT
            55 AS HDR_TYPE_ID, 'Third Party' AS HDR_TYPE, NULL AS LINK_TYPE_ID, NULL AS LINK_TYPE, NULL AS RISKUNIT_COVERABLE_TYPE,
            'NO' AS Link_to_Policy, EXP.ClaimID AS ClaimPublicID, TPC.ContactPublicID, TPC.HDR_ID, EXP.CLAIM_REF, 1 AS Active,
            TPC.ClaimContactID, EXP.Exposure_Motor_PublicID AS ExposureID, NULL AS IncidentID, NULL AS PolicyID,
            'claimant' AS Role, 'Motor' AS PRODUCT
        FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
        INNER JOIN (
            SELECT DISTINCT V2_SubCaseID, ClaimContactID, ContactPublicID, HDR_ID
            FROM #BASE_CONTACT_ROLE_MOTOR
            WHERE HDR_TYPE_ID = 55
        ) TPC ON TPC.V2_SubCaseID = CONVERT(VARCHAR(64), EXP.VectusCaseID_Adm)
        WHERE EXP.LossParty = 'third_party'
    ),

    /* ========================================================================
       COMBINE ALL ROLES
       ======================================================================== */
    FINAL_ROLE AS (
        SELECT * FROM #LKP_ROLES_HH
        UNION ALL
        SELECT * FROM MANDATORY_INSURED_ROLE_HH
        UNION ALL
        SELECT * FROM MANDATORY_REPORTER_ROLE_HH
        UNION ALL
        SELECT * FROM MANDATORY_CLAIMANT_ROLE_HH
        UNION ALL
        SELECT * FROM #LKP_ROLES_MOTOR
        UNION ALL
        SELECT * FROM MANDATORY_INSURED_ROLE_MOTOR
        UNION ALL
        SELECT * FROM MANDATORY_REPORTER_ROLE_MOTOR
        UNION ALL
        SELECT * FROM MANDATORY_CLAIMANT_ROLE_MOTOR
    ),

    /* ========================================================================
       STEP 5: DEDUPLICATION & EXCLUSIONS
       ======================================================================== */
    /* ========================================================================
       STEP 5A (NEW IN v6): SAME ROLE ON THE SAME CLAIM CONTACT, KEEP THE ROW THAT HAS THE MOST LINKS
       Why: a contact can reach the same role through two link types whose lookup flags differ (for example Link to Exposure YES on one, NO on the other).
            The role PublicID is HDR_ID + role only, so both rows would share one PublicID. The row with the exposure / incident / policy is the useful one.
       Rule: row F is dropped only if another row S exists with the same ClaimContactID and the same Role such that
               (a) every PolicyID / ExposureID / IncidentID that F HAS is the same value in S, and
               (b) S has a value in at least one of those three where F is blank.
             Rows that merely differ (two different exposures) are NOT touched. Identical rows are left to DEDUP_ROLE.
             claimant (one row per exposure), insured and reporter (mandatory) are excluded: they are never dropped by this step.
       ======================================================================== */
    ROLE_MOST_LINKED AS (
        SELECT F.*
        FROM FINAL_ROLE F
        WHERE NOT EXISTS (
            SELECT 1
            FROM FINAL_ROLE S
            WHERE S.ClaimContactID = F.ClaimContactID
              AND S.Role = F.Role
              AND F.Role NOT IN ('claimant', 'insured', 'reporter')
              AND (F.PolicyID   IS NULL OR F.PolicyID   = S.PolicyID)
              AND (F.ExposureID IS NULL OR F.ExposureID = S.ExposureID)
              AND (F.IncidentID IS NULL OR F.IncidentID = S.IncidentID)
              AND (   (F.PolicyID   IS NULL AND S.PolicyID   IS NOT NULL)
                   OR (F.ExposureID IS NULL AND S.ExposureID IS NOT NULL)
                   OR (F.IncidentID IS NULL AND S.IncidentID IS NOT NULL))
        )
    ),

    DEDUP_ROLE AS (
        SELECT
            ROW_NUMBER() OVER (
                PARTITION BY ClaimContactID, Role, ISNULL(PolicyID,''), ISNULL(ExposureID,''), ISNULL(IncidentID,'')
                ORDER BY ClaimContactID
            ) AS RN,
            *
        FROM ROLE_MOST_LINKED F
        WHERE Role IS NOT NULL
    )

    /* ========================================================================
       FINAL TARGET INSERT
       ======================================================================== */
    INSERT INTO [IntermediateStaging_DEV].[dbo].[IS_CLAIMCONTACTROLE]
    (
        [PublicID],
        [LUWID],
        [Active],
        [ClaimContactID],
        [ExposureID],
        [IncidentID],
        [PolicyID],
        [Role]
    )
    SELECT
        CAST(
            CASE
                /* 1. Claimant Role */
                WHEN Role = 'claimant' AND PRODUCT = 'Motor'
                    THEN 'mig:motorccr' + CONVERT(VARCHAR(20), HDR_ID) + '_claimant_' + REPLACE(ExposureID, 'mig:motor_', '')
                WHEN Role = 'claimant' AND PRODUCT = 'Household'
                    THEN 'mig:hhccr' + CONVERT(VARCHAR(20), HDR_ID) + '_claimant_' +
                        REPLACE(REPLACE(REPLACE(ExposureID, 'mig:hhb', 'b'), 'mig:hhc', 'c'), 'mig:hhtp', 'tp')
                /* 2. All other Roles */
                WHEN PRODUCT = 'Motor'
                    THEN 'mig:motorccr' + CONVERT(VARCHAR(20), HDR_ID) + '_' + Role
                WHEN PRODUCT = 'Household'
                    THEN 'mig:hhccr' + CONVERT(VARCHAR(20), HDR_ID) + '_' + Role
            END
        AS VARCHAR(64)) AS PublicID,
        CLAIM_REF AS LUWID,
        Active,
        ClaimContactID,
        ExposureID,
        IncidentID,
        PolicyID,
        Role
    FROM DEDUP_ROLE
    WHERE RN = 1;

    /* ========================================================================
       STEP 6: CLEANUP TEMP TABLES
       ======================================================================== */
    DROP TABLE #BASE_CONTACT_ROLE_HH;
    DROP TABLE #BASE_CONTACT_ROLE_MOTOR;
    DROP TABLE #HH_EXPOSURE_BY_TP_CASE;
    DROP TABLE #HH_INCIDENT_BY_TP_CASE;
    DROP TABLE #HH_INCIDENT_BY_TP_CASE_VEH;
    DROP TABLE #HH_EXPOSURE_BY_TP_CASE_VEH;
    DROP TABLE #MOTOR_EXPOSURE_BY_TP_CASE;
    DROP TABLE #MOTOR_INCIDENT_BY_TP_CASE;
    DROP TABLE #MOTOR_EXPOSURE_BY_AD_CASE;
    DROP TABLE #MOTOR_EXPOSURE_BY_PA_CASE;
    DROP TABLE #MOTOR_INCIDENT_BY_TP_CASE_VEH;
    DROP TABLE #MOTOR_EXPOSURE_BY_TP_CASE_VEH;
    DROP TABLE #ROLE_LINKS_HH;
    DROP TABLE #ROLE_LINKS_MOTOR;
    DROP TABLE #LKP_ROLES_HH;
    DROP TABLE #LKP_ROLES_MOTOR;

END;
