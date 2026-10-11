# Open items: BA questions, senior developer items, data checks (payments + recoveries, Motor)

## How to read this file
- Every item says: **WHERE** (table, proc, section, column), **WHAT HAPPENS TODAY** in plain words, **EXAMPLE**, **WHY IT MATTERS**, **WHAT TO ASK / DO**.
- "Master proc" = `usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR` (file 01). "Exception" / "issue" = the first problem found on a master row, written in `ExceptionCode` of `IS_PAYMENT_MASTER_MOTOR` and listed by the exception proc (file 07) and query Q21. **The row is NOT held back**: it is still copied to the transaction tables with the missing value left NULL, and ClaimCenter is expected to report it as a load error; we analyse those load errors with the BA afterwards. The procs never fail the run. The only rows not copied are recoveries on PA cases, because mapping row 136 says so (switch `@ExcludePaCredits` in the master proc).
- A "V2 transaction" is one row of `VEC_GW_PAY_TRANS` (column `ID` = `TranID`). One V2 transaction can become 1 or 2 master rows (see the guide, file 16, part 7).
- Nothing below is a business decision taken by me. Where I had to choose, the choice only keeps the row visible in the exception report.
- Method for each BA question: run the query named in [brackets] from file 09, copy ONE real row, show it to the BA and say: "In Vectus I see this. Today my code does this. Is that right?" One question at a time.

---------------------------------------------------------------------------------------------------

# PART A. NEW since the pay contact work (read these first)

## BA-27. PayTo for a COMPANY payee  [09 Q17d, Q17i]
- **Where:** `IS_CHECK_MOTOR.PayTo`, proc 05 (`usp_Load_SS_to_IS_CHECK_MOTOR`), variable `@PayToCompanyFallback` (top of the proc), expression `AS PayTo`.
- **Mapping rule (row 46):** PayTo = `IS_CLAIMCONTACT.PersonFirstNameDenorm` + one space + `PersonLastNameDenorm` of the check's claim contact.
- **Problem:** a claim contact that is a company (Subtype Company, CompanyVendor, AutoRepairShop, LawFirm, MedicalCareOrg, LegalVenue) has NO first and last name. In `usp_Load_IS_CLAIMCONTACT` those subtypes only fill `ContactNameDenorm`. So PayTo would be empty. The dummy payee is ALWAYS a Company, so every dummy payee has an empty PayTo.
- **Today:** the mapping is followed literally: PayTo is NULL for company payees. Switch `@PayToCompanyFallback = 1` makes PayTo use `ContactNameDenorm` for companies. The default is 0 (literal mapping) because choosing 1 is a business decision.
- **Example to show the BA:** run Q17d: it counts real payees per Subtype. Take one row where Subtype is a company type and show the check would have PayTo = empty.
- **Ask:** "For a company payee (and for the dummy payee) what should PayTo contain: empty, or the company name from ContactNameDenorm / PAYEE_NAME?"
- **After the answer:** change `DECLARE @PayToCompanyFallback BIT = 0` to 1 if the answer is "company name". Nothing else changes.

## BA-28. Payee found in V2 but not usable in the migration  [09 Q17, Q17b]
- **Where:** master proc, section S10 (line ~442), column `PayeeResolution`, and the exception codes in the big CASE of S11 (`PAYEE_LINK_HAS_NO_HDR`, `PAYEE_NOT_IN_CONTACT_MASTER`, `PAYEE_CONTACT_OTHER_CLAIM`, `PAYEE_NO_CLAIMCONTACT`).
- **How the payee is found:** `VEC_GW_PAY_TRANS.PAYEE_LINKID` -> `VEC_GW_CF_LINK.ID` -> `VEC_GW_CF_LINK.GWCF_HDRID` (this is the CONTACT RECORD id, `HDR_ID`) -> `CONTACT_MASTER_MOTOR.HDR_ID` (same claim: `GW_HDR_CASEID`) -> `IS_CLAIMCONTACT` (`ContactID` = contact PublicID, `ClaimID` = claim PublicID).
- **BA rule (transcript + Payee_Contact mapping):** dummy payee ONLY when PAYEE_LINKID is NULL, 0, or not found in `VEC_GW_CF_LINK`. That is `PayeeResolution` = `NO_PAYEE_LINK` or `LINK_NOT_IN_CF_LINK`. Done.
- **NOT covered by the BA, so NOT decided by me** (each is only FLAGGED with an issue code; the row is still copied, `ClaimContactID` stays NULL, no dummy is made):
  1. `LINK_NO_HDR`: the link exists but `GWCF_HDRID` is empty. Exception `PAYEE_LINK_HAS_NO_HDR`.
  2. `HDR_NOT_IN_CONTACT_MASTER`: the CONTACT RECORD has no row in `CONTACT_MASTER_MOTOR` at all. Typical reason: the contact master only keeps CONTACT RECORD types with `VEC_GW_CF_HDR_TYPE.PRODUCT = 'MOTOR'` (line 62 of the contact master proc) and drops records whose kept link has no row in `GWCC_CONTACT_SUBTYPE_MOTOR` (last line `WHERE EL.Subtype IS NOT NULL`, line 725). Exception `PAYEE_NOT_IN_CONTACT_MASTER`.
  3. `CONTACT_ON_OTHER_CLAIM`: the CONTACT RECORD exists, but only under another claim (`GW_HDR_CASEID` differs). Exception `PAYEE_CONTACT_OTHER_CLAIM`.
  4. `NO_CLAIMCONTACT`: contact found, but `IS_CLAIMCONTACT` has no row for (this contact, this claim). This is a run-order or filter problem, not a business case. Exception `PAYEE_NO_CLAIMCONTACT`. (Before, this silently became a dummy payee; I changed it to an error so a load-order defect is not hidden.)
- **Run Q17** (it returns one line per category with a count, an example TranID and an example claim) and Q17b (for category 4: which CONTACT RECORD ids and which record type).
- **Ask the BA (using the counts):** "For payments whose payee link exists in V2 but the person was not migrated (category 2, 3 or 4 of Q17), do you want (a) a dummy payee, (b) the payment held back, or (c) the person added to the migration?"
- **If the answer is (a):** add the category to the `IN ('NO_PAYEE_LINK','LINK_NOT_IN_CF_LINK')` list in section S11, CTE `C`, column `IsDummy` (one line). No other change.

## BA-29. In-care-of, MailingAddressID and MailTo  [09 Q17f, Q17g, Q17h]
- **Where:** `IS_CHECK_MOTOR.InCareOf_Adm`, `MailingAddressID`, `MailTo` (proc 05); source columns `VEC_GW_PAY_TRANS.ADD_LINKID`; master proc S10 (`InCareOfHdrID`).
- **Rules used (mapping rows 34, 42, 43):**
  - InCareOf_Adm = the contact of ADD_LINKID, found through the CONTACT RECORD (same way as the payee). NULL if ADD_LINKID is NULL / 0 / not found.
  - MailingAddressID = the primary address of that in-care-of contact (`CONTACT_MASTER_MOTOR.PrimaryAddressID`). I only fill it if a row with `CONTACT_ADDRESS_PUBLICID` = that id really exists in `IS_ADDRESS_CONTACT` (so there is never a broken foreign key). Otherwise NULL.
  - MailTo = filled only when InCareOf_Adm is filled. It is the address of the PAYEE (mapping text: "address of the cc_checkpayee.ClaimDenormID contact"; I read this as the payee contact, because PayeeDenormID is not loaded). The mapping does not say how an address becomes text, so I write it as one line: `AddressLine1, AddressLine2, AddressLine3, AddressLine4_Ext, City, County, PostalCode` (empty parts skipped), cut at 255 characters (`CONCAT_WS`, proc 05, expression `AS MailTo`). For a dummy payee the lines come from `IS_PAYEE_ADDRESS_PAY_MOTOR`.
- **Three things to confirm with the BA:**
  1. "MailTo = address of the PAYEE, written as one text line in this order. Is that the format you want?"
  2. "ClaimDenormID in the MailTo rule: is it the payee? (cc_checkpayee has PayeeDenormID; there is no ClaimDenormID column)".
  3. "When the in-care-of contact has no address, MailingAddressID stays empty. Correct?" Q17f category 4 gives the count (contact found but no address row).
- **Why it matters:** Q17h counts contacts whose `PrimaryAddressID` has no address row. That is a gap in the senior's address procs (see senior item S-10), not in my code.

## BA-30. One dummy payee per V2 transaction, or one per payee name?
- **Where:** proc 01b (`usp_Load_SS_to_IS_PAYEE_DUMMY_MOTOR`), PublicIDs `mig:motorpayee_<TranID>`, `mig:motorpayeecc_<TranID>`, `mig:motorpayeeadr_<TranID>`.
- **Today:** one dummy company contact + claim contact (+ address) PER V2 TRANSACTION, even if the same payee name appears on ten payments of the claim. If one V2 transaction is split in two master rows, both share the same dummy.
- **Reason:** the transcript says the dummy is created per transaction and uses the transaction's own PAYEE_NAME / address. Nothing in the mapping says to merge by name.
- **Ask:** "Dummy payee per transaction is fine? Or one per distinct PAYEE_NAME on the claim?" (If per name, the PublicID must change to a hash of claim + name; tell me and I change 01b and the master proc, section S11 insert, two lines.)

## BA-31. Dummy payee for TRANSFER payments and for a person's name  [09 Q17c, Q17e]
- **Where:** proc 01b, column `Name`; master proc `PayeeName`.
- **Today:** on a transfer payment (`PAY_TYPE = 'T'`) the debit's PAYEE_NAME holds the TARGET CLAIM NUMBER (that is also copied to `IS_CHECK_MOTOR.InternalCCPayClaimNumber_Adm`). If PAYEE_LINKID is empty on that payment, the dummy company contact will be named with the claim number. Q17e shows how many transfer payments fall in which payee category.
- **Also:** the dummy is always Subtype Company, even if PAYEE_NAME is a person (BA rule). The name is cut to 60 characters (same as the company name in the contact master); Q17c column `NameLongerThan60` counts the cut ones, and `IS_PAYEE_CONTACT_PAY_MOTOR.NameCut` flags them. Address lines are cut to 60 characters (same as `IS_ADDRESS_CONTACT`); Q17c column `AddressLineLongerThan60`.
- **Ask:** "A transfer payment without a payee link: dummy named with the claim number, correct?" and "Is cutting a name at 60 characters acceptable?"
- **Blank name:** a dummy payee with a blank PAYEE_NAME cannot be created (a company needs a name in ClaimCenter). The dummy contact is still created with `Name` NULL, and the row is flagged `DUMMY_PAYEE_NO_NAME` (ClaimCenter will reject the empty name; that is the load error to analyse). Q17c column `NoName` gives the count.

---------------------------------------------------------------------------------------------------

# PART B. BA questions from the earlier work (still open)

**1. Recoveries on the claim itself.** [09 Q11c]
- WHERE: `IS_PAYMENT_MASTER_MOTOR.CaseType = 'HDR'` and `DebitCredit = 'C'`; master proc S11, exception `NO_RECOVERY_RESERVE_LINE`.
- A credit (money coming back) whose `VEC_GW_PAY_TRANS.CASEID` equals the CLAIM KEY (`GW_HDR_CASEID`) belongs to the claim itself, not to AD/TP/PA. BA transcript example: claim whose CLAIM KEY ends 9004, 4 transactions, one is a recovery of 2 pence. She said it goes to the claim-level recovery reserve line.
- PROBLEM: that line is `pm_other_adm` (reserve lookup row 4, "create only if there are transactions"). The senior's reserve proc does not create it.
- TODAY: those credits are copied with `ReserveLineID` NULL and flagged `NO_RECOVERY_RESERVE_LINE`; ClaimCenter will report them.
- ASK: "Credits on the claim itself go to `pm_other_adm`? Who creates the line?" (also senior item S-2).

**2. Recoveries on a removed AD case.** [09 Q10, Q11b]
- WHERE: master proc S6 (`#ADEXP`, `#ADCNT`), S11 columns `AdRemapped`, `AdAmbiguous`.
- When a claim has several AD cases, only one AD exposure survives (mapping row 136: all transactions go to it). A DEBIT on a removed AD case is moved to the surviving AD (warning `AD_REMAPPED_TO_SURVIVING_CASE`). A CREDIT on a removed AD case needs a recovery reserve line on the surviving AD, but the reserve proc creates the recovery line (`_rec`) only when a credit sits on that AD case itself.
- ASK: "Should the surviving AD always get a recovery reserve line when a removed AD case had a credit?" (senior item S-3).

**3. Injury: which reserve line takes expense payments?** [09 Q12]
- WHERE: master proc S7, `#RLC` column `Pref`; exception `NO_MAIN_INJ_LINE`.
- An injury exposure has several reserve lines of the same cost type. I assumed: claim cost -> cost category `pm_injury_adm`; expense -> `pm_third_party_costs_adm` ("Third Party Solicitors Costs"). The BA said she added a column to the mapping that names the main line; I do not have it. An open injury exposure only has the expense line when its reserve is above 0.
- TODAY: when the main line does not exist, `ReserveLineID` and `CostCategory` stay NULL (no other injury line is guessed) and the row is flagged `NO_MAIN_INJ_LINE`; the row is still copied.
- ASK: "Please send the column that names the main line, or confirm the two categories above. What happens to an expense payment when that expense line does not exist?"

**4. Transfer payments (PAY_TYPE = T).** [09 Q19]
- WHERE: `IS_TRANSACTION_PAY_MOTOR.InternalCCPayRecoCurrency_Adm`, `InternalCCPayRecoCat_Adm`; `IS_CHECK_MOTOR.InternalCCPayClaimNumber_Adm`.
- TODAY: claim number + currency on the debit (source claim), recovery category `subro` on the credit (target claim). The sheet lists the category under Payment, the BA said it is for the credit.
- ASK: "Which side gets InternalCCPayRecoCurrency: debit, credit, or both? Is a payment method needed on the credit (a recovery has no cheque)?"

**5. Hire & Mobility codes mixed with normal codes in one third-party transaction.** [09 Q8]
- WHERE: master proc S4/S5 (`IsHire`), suffix `h`.
- TODAY: one V2 transaction becomes two ClaimCenter transactions: one on the Hire & Mobility exposure, one on the vehicle exposure (a transaction can sit on one exposure only).
- ASK: "Is that right?"

**6. A V2 transaction with no dissection row at all.** [09 Q2]
- WHERE: master proc S3 (`LEFT JOIN VEC_GW_PAY_DISS`, `CASE WHEN D.GW_PAY_TRAN_ID IS NULL THEN T.HdrAmount`).
- TODAY: one line item with the transaction amount, cost type claim cost.
- ASK: "Is that right?"

**7. Dissection codes with no row in the lookup.** [09 Q5]
- WHERE: `SourceStaging.dbo.Lkp_Transaction_Typelist`, columns `DISSECTION_CODE`, `V2_CASE`, `LOB = motor`, `DEBIT_CREDIT = D`; master proc S4; exception `UNMAPPED_DISS_CODE`.
- Codes CDW, FSC, RVM, SUB, TEM exist in the lookup only for third-party cases (`V2_CASE = GW_MOTOR_TP`); SUC only for non-third-party. If CDW is found on an AD payment, or SUC on a TP payment, no lookup row matches.
- TODAY: that dissection line gets `CostType` NULL, the master row is flagged `UNMAPPED_DISS_CODE` and is still copied (no reserve line can be found for a NULL cost type, so `ReserveLineID` is NULL too).
- ASK: "Which cost type for these?" Show the BA the Q5 result so she sees real counts.

**8. Which lookup tab and what recovery cost category.**
- The lookup table has a recovery row and 21 credit rows with cost category `claimcost_adm`. My proc does NOT read credit rows; every credit is Recovery / claim cost / Migrated Recovery, and the cost category comes from the recovery reserve line.
- ASK: "Confirm the loaded lookup is the NEW_MOTOR_Payment-Recovery tab and that the recovery cost category is the cost category of the recovery reserve line."

**9. Recovery coding: one per recovery transaction, or one per recovery reserve line?**
- WHERE: master proc S11, CTE `C`: `LEFT JOIN IS_RECOVERYCODING_MOTOR RC ON RC.ReserveLineID = RS.ReserveLinePublicID`; exception `NO_RECOVERY_CODING`.
- TRANSCRIPT: "one record for each recovery transaction". EXAMPLE in the transcript: reserve line 1 -> coding 22 and the transaction carries coding 22.
- TODAY: coding is reused (one per reserve line, shared by all recoveries of that line); no new rows are created.
- ASK: "Is the coding created once per recovery reserve line and shared?"

**10. Several PAID / PRESENTED / CANX records on one transaction.** [09 Q15]
- WHERE: master proc S8 (`#STAT`, `#STD`). The BA decided only AUTH / GRP_AUTH (use the latest). Today the same rule (latest status row id) is used for PAID, PRESENTED, CANX. ASK: confirm.

**11. (replaced by BA-28)**
**12. (replaced by BA-27, 29, 30, 31)**

**13. Third party with vehicle AND injury AND property.** [09 Q9]
- WHERE: master proc S11 column `TpAllThree`, warning `TP_VEH_INJ_PRO_RULE_ASSUMED`. The mapping lists two-way combinations only. TODAY: vehicle. ASK: confirm.

**14. Voided / recorded / transferred transactions (offset table).**
- A developer asked about the transaction offset table; the BA said it is not mapped. ASK: confirm it was de-scoped.

**15. PA (ancillary) recoveries.** [09 Q11]
- Mapping row 136: PA credits are a V2 data issue and "should not be migrated". TODAY: they stay in `IS_PAYMENT_MASTER_MOTOR` (flag `PA_CREDIT_NOT_MIGRATED`, `Loadable = 0`) but are not copied to the transaction tables; set `@ExcludePaCredits = 0` in the master proc to copy them. ASK: the final agreed handling and the count.

**16. A V2 payment where only some parts can load.** [09 Q22]
- Example: the claim-cost part is fine, the expense part has no reserve line. TODAY: both parts are copied; only the bad part carries an issue code (query Q22 lists these). The totals then do not match V2. ASK: "Hold back the whole V2 payment in that case?"

**17. DoesNotErodeReserves.** Mapping default column says FALSE; the transformation text and the transcript say TRUE (1). TODAY: 1. ASK: confirm.

**18. LineCategory typecode.** WHERE: `IS_PAYMENT_MASTER_LINE_MOTOR.LineCategoryCode`; master proc S9 `#TLV`. Confirm the typecodes for `Migrated Payment` and `Migrated Recovery` in `TYPELIST_TABLE_MAPPING` (query in file 14).

**19. Mapping row 174 comment.** "Not necessary to split to multiple check-transactions if the check is not part of a bulk invoice". The transcript requires the split when cost types differ. ASK: confirm the comment is not an exception.

**20. Claim eligibility.** The transcript says claims with payments "in flight" are held back by the claim eligibility rules. ASK: confirm there is no status filter in the payment mapping.

**21. ApprovalStatus default.** The mapping picture shows default "Approved". TODAY an unmapped status leaves `ApprovalStatus` NULL and flags `UNMAPPED_APPROVAL_STATUS`; the row is still copied. ASK: "Use Approved when the status cannot be mapped?"

**22. Not-nullable fields filled for one subtype only.** `PaymentType`, `DoesNotErodeReserves`, `RecoveryCategory`: is the other kind of transaction allowed to have NULL?

**23. TRANS_REF padding.** DECIDED by you: trailing blanks are trimmed. Nothing to ask (Q23 counts them).

**24. Migration user.** `RequestingUserID` (transaction set), `CreateUserID`, `VoidStopUserID` (check) are not nullable in ClaimCenter. Which user id? TODAY: NULL.

**25. CreateTime.** DECIDED: first status date goes to `LegacyCreateTime_Adm`. Nothing to ask.

**26. ForEx amounts.** Kept in the Motor working line table and proc 03 (mapping lists them, always 0). `IS_TRANSACTIONLINEITEM` has no such columns, so file 15 does not copy them. ASK the senior whether the table should get them.

---------------------------------------------------------------------------------------------------

# PART C. Senior developer items

**S-1. Typelists.** ANSWERED by your sample: status typelists are keyed by the V2 status code (AUTH, GRP_AUTH, PAID...). Open: `CheckStatus` typelist (19 rows) exists but the mapping says `cc_check.Status` uses `TransactionStatus`; I use `TransactionStatus`.

**S-2. Claim-level recovery line `pm_other_adm`** (BA-1). If the senior adds it: `SourceOrigin_Adm = 'HDR'`, `VectusCaseID_Adm` = CLAIM KEY, cost type `claimcost`, PublicID ending `_rec`. The recovery coding proc (`usp_Load_SS_to_IS_RECOVERYCODING_MOTOR`) then needs an `HDR` token in its CASE, otherwise the coding PublicID is NULL.

**S-3. AD recovery eligibility** (BA-2).

**S-4. Recovery coding proc order and tokens.**
- It reads `IS_TRANSACTION_MOTOR` rows with `Subtype = 'RecoveryReserve'`: it must run AFTER the senior's reserve transaction proc, and EVERY `_rec` reserve line needs a `RecoveryReserve` row, otherwise no coding exists and my recoveries stop with `NO_RECOVERY_CODING`.
- `TP_HIRE` has no token (harmless: recoveries never go to Hire).
- See the guide, file 16, part 6, for the full explanation.

**S-5. `'Subrogation'` vs `'subro'`.** The transaction proc writes `Subrogation` (two places); the typelist code is `subro`.

**S-6. Contact master keeps only MAX(LINK_ID) per CONTACT RECORD.** Consequence handled in my code: payee found through the CONTACT RECORD, not the link id. No action, information only.

**S-7. Real DDLs** of `IS_CONTACT`, `IS_CLAIMCONTACT`, `IS_ADDRESS` (the three I do not have). Needed for the final insert templates (file 15) of dummy contact, dummy claim contact, dummy address. Please send, or run `SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME IN ('IS_CONTACT','IS_CLAIMCONTACT','IS_ADDRESS')`.

**S-8. Contact master drops CONTACT RECORDS.** WHERE: `usp_Load_IS_CONTACT_MASTER_MOTOR`, last line `WHERE EL.Subtype IS NOT NULL` (line 725) and line 62 `HDR_TYPE.PRODUCT = 'MOTOR'`. A CONTACT RECORD whose kept (MAX) link type has no row in `GWCC_CONTACT_SUBTYPE_MOTOR` disappears from the contact master, and so does its claim contact and its roles. If a payee is such a record, the payment stops (BA-28 category 4). Ask the senior how many records are dropped (Q17b lists the payees affected).

**S-9. `IS_CLAIMCONTACT` names.** WHERE: `usp_Load_IS_CLAIMCONTACT`. Company subtypes fill `ContactNameDenorm`; Person, Doctor, Contact fill `PersonFirstNameDenorm` / `PersonLastNameDenorm`; any subtype in neither list has NO name at all. Q17i counts claim contacts with no name. Matters for `PayTo` (BA-27).

**S-10. `IS_ADDRESS_CONTACT` only has rows for links that have a location.** WHERE: `usp_Load_IS_ADDRESS_CONTACT`, `INNER JOIN VEC_GW_LOCATION L ON L.ID = CFL.GW_LOCATIONID`. A CONTACT RECORD where no link has a location gets `CONTACT_MASTER_MOTOR.PrimaryAddressID` filled (ranked over all links) but NO row in `IS_ADDRESS_CONTACT`, so any foreign key to that address id is broken. Q17h counts these. My check proc guards against it (MailingAddressID is NULL then).

**S-11. Checkpayee ROLE.** The role row `cc_claimcontactrole` with role `checkpayee` is NOT created in any payment proc. It must be added in `usp_Load_IS_CLAIMCONTACTROLE_ALL_FIXES_motor_and_hh_v6`:
- for every real payee (`IS_CHECKPAYEE_MOTOR.ClaimContactID` of a non-dummy payee): PublicID pattern `mig:motorccr<HDR_ID>_checkpayee` as in that proc, `ExposureID` = the payment's exposure (BA: the role is linked to the exposure of the transaction);
- for every dummy payee: the role must be built from `IS_PAYEE_CLAIMCONTACT_PAY_MOTOR`, because the CCR proc starts from the contact master, where dummy contacts do not exist;
- its "most linked role" step (5A, `ROLE_MOST_LINKED`) must exclude `checkpayee`.
- Open question to the BA: one role per payment, or one per payee and exposure? (the role PublicID pattern has no exposure; two payments of the same payee on two exposures would need two roles). The feed query is in file 17.

---------------------------------------------------------------------------------------------------

# PART D. What I need YOU to run or send (in order)

1. Run file 08 after the procs (all queries must be empty unless marked "report").
2. Run Q17, Q17b, Q17c, Q17d, Q17e, Q17f, Q17g, Q17h, Q17i from file 09. Send the results (first 20 rows are enough). They fill BA-27..31 and S-8, S-9, S-10.
3. Run Q1..Q16, Q18..Q25 if not yet done (they feed BA 1-10, 13, 15, 16).
4. Send the DDLs of `IS_CONTACT`, `IS_CLAIMCONTACT`, `IS_ADDRESS` (S-7).
5. Tell me the run order you use for the contact procs, address procs, and CCR proc (the payee lookup needs `CONTACT_MASTER_MOTOR`, `IS_CLAIMCONTACT`, `IS_ADDRESS_CONTACT` to be filled BEFORE the master proc runs).
6. Existing working tables with the old names or columns (`IS_PAYMENT_UNIT_MOTOR`, `IS_PAYMENT_LINE_MOTOR`): drop them. Run file 00 again (it creates only what does not exist, so tables with the old shape must be dropped first: `IS_PAYMENT_MASTER_MOTOR`, `IS_PAYMENT_MASTER_LINE_MOTOR` if they already exist from an earlier run of this version).


---------------------------------------------------------------------------------------------------

# PART E. Choices still built into the code (none of them removes a row)

These are places where the mapping or the BA gave a rule that needed one more detail, or where several matches exist. Each one only decides a VALUE; the row is always copied. If the BA gives another rule, only the named part changes.

| # | Where (proc, section) | What the code does | Why | Question |
|---|---|---|---|---|
| E1 | 01, S7 `#RLSEL` | If a CASE has several reserve lines of the same class, the one with the lowest PublicID is taken; note `MULTIPLE_RESERVE_LINES` | needed to choose one line | BA-3 for injury; others: Q-list in file 09 |
| E2 | 01, S11 `TargetOrigin` | TP debit with vehicle, property and injury exposures: vehicle; note `TP_VEH_INJ_PRO_RULE_ASSUMED` | mapping lists two-way combinations only | BA-13 |
| E3 | 01, S11 | TP credit goes to the one exposure that carries the recovery line (vehicle, then property, then injury) | reserve line proc puts the recovery line on one exposure | BA-2 / S-3 |
| E4 | 01, S8 `#STD` | PAID, PRESENTED, CANX dates: the latest status row | the BA decided it only for AUTH / GRP_AUTH | BA-10 |
| E5 | 01, S3 | Transaction with no dissection row: one line with the transaction amount, claim cost | BA said a debit always has a code; nothing about no row | BA-6 |
| E6 | 01, S12 | Cheque stop reason not in the typelist: `issued_in_error` | BA rule | none |
| E7 | 01, S12 | `CASH_MOVE_NO` that is not a number: NULL and note `CASHMOVE_NOT_NUMERIC` | the ClaimCenter column is a long integer | none |
| E8 | 05 | `PayTo` = first + space + last (trimmed); `MailTo` as one text line; both cut at 255 | mapping silent on format; 255 = size of the target column | BA-27, BA-29 |
| E9 | 01, S11 | `ExceptionCode` keeps only the FIRST problem found; later ones on the same row are not shown (the notes in `WarnList` are all kept) | one column | none: after the first fix, run again |
