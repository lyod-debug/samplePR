# Traceability: every payment mapping row and BA rule → where the proc does it

Legend: **DONE** = implemented as the BA wrote it. **PENDING** = cannot be filled by the payment procs yet (needs the contact / address procs or the migration user). **BA-Q** = the BA text is unclear or two sources disagree, see file 10. **N/A-MOTOR** = Household only, ignored.
Procs: 01 = `usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR` (decides everything), 02 transaction, 03 line item, 04 set, 05 check, 06 checkpayee, 07 exceptions, 08 validation, 09 data checks.

## 1. Source-to-target mapping file (`de04c726…`), row by row

### cc_check
| Row | Field | BA rule | Where | Status |
|---|---|---|---|---|
| 3 | AccountName | PAYEE_NAME as is | 05 | DONE |
| 6 | BankAccountNumber | ACCOUNT_NUMBER as is | 05 | DONE |
| 7 | BankSortCodeStr_Adm | SORT_CODE as is | 05 | DONE |
| 8 | CheckBatching | GROUPED N → apdefault, Y → bulkcheck | 05 (other value → NULL + warning GROUPED_NOT_Y_OR_N in 01) | DONE |
| 10 | CheckNumber | VEC_GW_PAY_GATEWAY.TRANS_REF via GW_PAY_GATEID | 01 S11 join, 05 | DONE |
| 11 | CheckSetID | same set as the transaction | 05 (`mig:motorpts_<TranID><suffix>`) | DONE |
| 12 | CheckType | primary | 05 | DONE |
| 13 | ChequeNumber_Adm | CHEQUE_NUMBER as is | 05 | DONE |
| 18 | ChequePresentedDate_Adm | status PRESENTED record date + time | 01 S8 (latest if several) | DONE, BA-Q 10 (several records) |
| 19 | ChequeStopReason_Adm | status CANX, typelist ReasonToStopCheque_Adm, not in typelist → issued_in_error | 01 S8/S12 | DONE |
| 20 | ClaimContactID | claim contact of PAYEE_LINKID (through the CONTACT RECORD); NULL / 0 / not in VEC_GW_CF_LINK → dummy claim contact | 01 S10/S12, 01b, 05 | DONE; other not-found cases are ERRORS until BA decides (BA-28) |
| 21 | ClaimID | claim | 05 | DONE |
| 23 | CreateTime | same as transaction | 05 | DONE |
| 24 | CreateUserID | migration user | – | PENDING (migration user PublicID) |
| 25 | DenormCashMoveNo_Adm | CASH_MOVE_NO as is | 05 | DONE |
| 31 | DenormPostalCode_Adm | POST_CODE as is | 05 | DONE |
| 33 | EnteredTime | status PAID record | 01/05 | DONE |
| 34 | InCareOf_Adm | contact of ADD_LINKID (through the CONTACT RECORD), else NULL | 01 S10, 05 | DONE |
| 35 | InternalCCPayClaimNumber_Adm | PAY_TYPE = T and DEBIT_CREDIT = D, = PAYEE_NAME | 01 (IsTransfer), 05 | DONE |
| 40 | IsPrimary | DB default | – | DONE (not set) |
| 41 | IssueDate | status PAID record | 05 | DONE |
| 42 | MailingAddressID | address of the in-care-of contact | 05 (CONTACT_MASTER_MOTOR.PrimaryAddressID checked against IS_ADDRESS_CONTACT) | DONE; BA-29 |
| 43 | MailTo | address of the payee contact if in-care-of is not NULL | 05 (address lines as one text) | DONE; text format and ClaimDenormID = payee: BA-29 |
| 45 | PaymentMethod | typelist PaymentMethod on PAY_TYPE | 01 S9, 05 | DONE (transfer T → internal payment CC via typelist) |
| 46 | PayTo | first name + space + last name of the claim contact | 05 (@PayToCompanyFallback) | DONE literally; company payee gives NULL: BA-27 |
| 49 | PayToDenorm | same as PayTo | – | PENDING |
| 50 | RejectedByGateway_Adm | DB default FALSE | – | DONE (not set) |
| 52 | Status | same as transaction status | 05 | DONE |
| 53 | VoidStopUserID | migration user when status CANX | – | PENDING (migration user) |

### cc_checkpayee
| Row | Field | BA rule | Where | Status |
|---|---|---|---|---|
| 86 | PayeeType | create claimcontactrole `checkpayee` for the payee contact | 06 sets 'checkpayee' (PayeeType column); the ROLE ROW is not created here | PENDING in the claim contact role proc (S-11 in file 10; feed query in file 17) |
| 87 | PayeeDenormID | contact of PAYEE_LINKID | – | NOT LOADED: filled by ClaimCenter on CCST to CC load (user decision, transcript line 82) |
| 88 | ClaimContactID | claim contact of the payee, dummy if none | 06 | DONE |
| 89 | CheckID | exactly one checkpayee per check | 06, validation V3 | DONE |

### cc_recoverycoding
| Row | Field | Rule | Where | Status |
|---|---|---|---|---|
| 95/96 | ReserveLineID / RecoveryCategory | only recovery transactions; same as the transaction | built by the senior's proc; payments only look it up | DONE as "reuse", BA-Q 9 |

### cc_transaction
| Row | Field | BA rule | Where | Status |
|---|---|---|---|---|
| 123 | TransactionSetID | 1..1, one set per transaction (transcript: a split gives separate sets) | 02/04 | DONE |
| 124 | Subtype | D → Payment, C → Recovery | 01 | DONE |
| 125 | Status | status record with GCURRENT = X, typelist | 01 S8/S9 | DONE, senior-Q 1 |
| 126 | RecoveryCategory | subro, recoveries | 02 | DONE |
| 127 | ReservingCurrency | gbp | 02 | DONE |
| 128 | ReserveLineID | main claim cost / expense / recovery line of the exposure | 01 S7/S11 | DONE; injury expense line BA-Q 3 |
| 129 | RecoveryCodingID | the coding of the same reserve line | 01 | DONE |
| 130 | PaymentType | partial | 02 | DONE |
| 131 | CreateUserID | migration user | – | PENDING |
| 132 | CreateTime | first status record (MIN ID) | 01 | DONE |
| 133 | LifeCycleState | typelist from the status | 01 | DONE, senior-Q 1 |
| 134 | InternalCCPayRecoCurrency_Adm | transfer only, gbp | 02 (debit transfers) | DONE, BA-Q 4 (which side) |
| 135 | InternalCCPayRecoCat_Adm | transfer, subro, "on the target claim" | 02 (credit transfers) | DONE; sheet lists it under Payment, transcript says credit → BA-Q 4 |
| 136 | ExposureID | AD → surviving AD exposure (N AD cases all go to the single one); PA → PA exposure, PA credits not migrated; TP VEH only/INJ only/PRO only/VEH+INJ/VEH+PRO/INJ+PRO(→ property)/none(→ vehicle); hire codes → hire exposure | 01 S6/S11 | DONE; VEH+INJ+PRO not listed → BA-Q 13 |
| 137 | DoesNotErodeReserves | default column says FALSE, transformation text and transcript say TRUE (1) | 02 uses 1 | DONE, BA-Q 17 (confirm) |
| 138 | DenormCashMoveNo_Adm | recoveries, CASH_MOVE_NO | 02 | DONE |
| 139 | Currency | gbp | 02 | DONE |
| 140/141 | CostType / CostCategory | NEW_MOTOR_Payment-Recovery tab; category as is from the reserve line | 01 + 02 | DONE; confirm the lookup is the NEW tab → BA-Q 8 |
| 144/145 | CloseExposure / CloseClaim | FALSE | 02 | DONE |
| 147 | ClaimID | claim | 02 | DONE |
| 148 | ChequeNumber_Adm | recoveries, CHEQUE_NUMBER | 02 | DONE |
| 149 | CheckID | every payment has exactly one check | 02/05 | DONE |
| 150 | BookingDate | = CreateTime | 02 | DONE |

### cc_transactionlineitem
| Row | Field | Rule | Where | Status |
|---|---|---|---|---|
| 174 | TransactionID | one dissection = one line item, all linked to the same transaction | 03 | DONE; the comment "not necessary to split to multiple check-transactions if not part of a bulk invoice" → BA-Q 19 |
| 175/177/183 | ReservingForEx / ReportingForEx / ClaimForEx amounts | 0 | 03 | DONE |
| 176/178/179/184 | Reserving / Reporting / Transaction / Claim amount | dissection AMOUNT | 03 | DONE |
| 180 | LineCategory | Migrated Payment / Migrated Recovery | 03 | DONE, typecode not confirmed → BA-Q 18 |
| 181 | CreateUserID | migration user | – | PENDING |
| 182 | CreateTime | first status record (same for every line) | 03 | DONE |

### cc_transactionset
| Row | Field | Rule | Where | Status |
|---|---|---|---|---|
| 199 | Subtype | Payment → CheckSet, Recovery → RecoverySet | 04 | DONE |
| 200/201 | RequestingUserID / CreateUserID | migration user | – | PENDING |
| 202 | CreateTime | same as transaction | 04 | DONE |
| 204 | CreatedVia | manual | 04 | DONE |
| 205 | ClaimID | claim | 04 | DONE |
| 207 | CashMoveNo_Adm | CASH_MOVE_NO as is | 04 | DONE |
| 208 | ApprovalStatus | typelist from the transaction status (the detailed text under "208" is really the ApprovalDate text, OCR / layout slip) | 01/04 | DONE, senior-Q 1 |
| 209 | ApprovalDate | credits: first status record; debits: latest AUTH / GRP_AUTH (MAX ID), else first record | 01 S8/S12 | DONE |

## 2. Lookup `MOTOR_Payment-Recovery` / `Lkp_Transaction_Typelist`
| Rule | Where | Status |
|---|---|---|
| Debit with NULL code → claimcost, normal exposure (row 4) | 01 S3/S4 (`~NULL~`) | DONE |
| 147 rows, one cost type per code; "All" vs "All cases apart from GW_MOTOR_TP" vs "GW_MOTOR_TP" | 01 S4 (specific beats All) | DONE |
| Hire & Mobility codes ABA ABH ABP CDW FSC OUH PLH PLP RVM SUB TEM TPH on a TP case → hire exposure, claimcost, pm_tp_mobility_adm; same codes elsewhere → normal exposure | 01 S4/S11 | DONE; the 12 codes equal the exposure proc's list (checked) |
| CDW, FSC, RVM, SUB, TEM only listed for TP; SUC only for non-TP | 01: no row → UNMAPPED_DISS_CODE | BA-Q 7 |
| All credits → Recovery, claimcost, Migrated Recovery, Subrogation (general note 2 and "ALL dissection codes" row), credit rows by code are not needed (transcript) | 01 S4 | DONE |
| Credit rows show Cost Category `claimcost_adm` while row 24 says "main recovery reserve line" | category comes from the recovery reserve line | BA-Q 8 |
| Lookup `ASR`, `EXG`, `RTI`, `SPH`, `STP`, `TPR`, `WIN` appear as both debit and credit | debit rows used for debits only, credit rows never read | DONE |

## 3. BA SQL files (parts 1 and 2)
| Rule | Where | Status |
|---|---|---|
| Claim = VEC_GW_CLAIM_SUM current, not WINDSCREEN, CLAIM_REF filled | replaced by `IS_CLAIM_MASTER` (your standing rule 1); assumes IS_CLAIM_MASTER applies the same filter | DONE, confirm with a count (query not needed if the master is the agreed source) |
| Join payments to claim on GW_HDR_CASEID; case on CASEID | 01 S1/S2 | DONE |
| Status first record = MIN(ID), current = GCURRENT X | 01 S8 | DONE |
| PRESENTED / PAID / CANX / AUTH records | 01 S8 | DONE |
| Approval: no credit has AUTH; no debit has both AUTH and GRP_AUTH; duplicates → latest; no AUTH → first record (311,890 paid directly) | 01 S8/S12 | DONE |
| Transfer payments: debit on the source claim, credit on the target claim | 01/02/05 | DONE, BA-Q 4 |
| Dummy contact when `VEC_GW_CF_LINK.ID IS NULL`: name = PAYEE_NAME, address lines 1-3 + POST_CODE | DONE in 01b (`mig:motorpayee_<TranID>`, `mig:motorpayeecc_<TranID>`, `mig:motorpayeeadr_<TranID>`) | PENDING contact proc |
| Edge case "dissection to transaction mapping, creation of 2 transactions" (the example 53656976) | 01 master rows | DONE; **the example is a HOUSEHOLD claim** (transcript) |

## 4. BA transcript, topic by topic
| Topic | Where | Status |
|---|---|---|
| Header case id = claim; case id = case; CASEID = GW_HDR_CASEID means claim level | 01 S2 | DONE |
| Claim-level payments → claim-level reserve lines (migrated_cost / migrated_expense), no exposure | 01 S11 (`HDR`) | DONE |
| Claim-level recovery goes to the claim-level lines | the senior's proc has no `pm_other_adm` line (lookup row 4) | BA-Q 1, senior-Q 2 |
| One V2 transaction = one CC transaction; mixed cost types → two transactions, each with its own set | 01 S5 | DONE |
| Set per transaction; check + checkpayee per payment; recovery coding per recovery | 04/05/06/02 | DONE |
| Voided / cancelled / any status is in scope; transaction offset table not mapped | no status filter | DONE, BA-Q 14 |
| Recoveries: always one exposure per case (vehicle, or property) | 01 `#RLREC` | DONE |
| Hire & Mobility routing | 01 | DONE |
| PA credits not migrated (data fix) | 01 `PA_CREDIT_NOT_MIGRATED` | DONE (reported, not deleted) |
| Payee through PAYEE_LINKID; in-care-of through ADD_LINKID; dummy payee is a Company | 01 S10 / 01b / 05 / 06 | DONE |
| Approval date rules | 01 | DONE |
| Legacy create time may replace CreateTime later | – | note only |

## 5. Handoff
| Rule | Status |
|---|---|
| IS_CLAIM_MASTER + GW_HDR_CASEID for every claim join; CONTACT_MASTER_MOTOR for contacts | DONE |
| CASEID is the payment's case, never join case data on GW_HDR_CASEID | DONE (S2 restricts AD / TP / PA to the same claim) |
| Unique PublicIDs, FK existence checks | DONE (08 V1/V2); not yet run on SQL Server |
| Do not delete or exclude without BA decision | DONE (every master row stays in IS_PAYMENT_MASTER_MOTOR with an ExceptionCode; the only mapped exclusion is PA credits, reported) |
| Contact master keeps only MAX(LINK_ID) per CONTACT RECORD | CONFIRMED by user; payee found through VEC_GW_CF_LINK.GWCF_HDRID (01 S10), checked by Q17 |
| checkpayee role links to an exposure | the master row carries ExposureID; role PublicID pattern has no exposure → BA-Q 12 |
| DUH vs OUH hire code | the current exposure proc and the lookup both use OUH (checked), so no conflict remains |


## 6. Changes after checking the source-to-target pictures
| Item | Picture says | Done |
|---|---|---|
| checkpayee.PayeeType (row 86) | Type key of ContactRole, not nullable | Loaded as 'checkpayee' (proc 06) |
| checkpayee.PayeeDenormID | Nullable | Not loaded (user decision) |
| DenormCashMoveNo_Adm (check, transaction), CashMoveNo_Adm (set) | longint | BIGINT in DDL; safe conversion in proc 01; CASHMOVE_NOT_NUMERIC warning |
| ChequePresentedDate_Adm | dateonly | Date only, midnight (proc 05) |
| DISS AMOUNT | DOUBLE | ROUND(FLOAT, 2) to DECIMAL(18,2); DISS_SUM_MISMATCH still checks the header |
| TRANS_REF | CHAR(16) | Loaded as is; BA question 23 |
| Payee link table | VEC_GW_CF_LINK | Used (CG is a typo) |
| Recovery coding | Reused from the reserve line (BA diagram) | Reused |
| Claim-level ExposureID | Nullable | NULL |
| set.RequestingUserID | Not nullable | Still NULL; BA question 24 |
| ApprovalStatus default | "Approved" | Not applied; BA question 21 |
Note: nullable readings come from skewed photos; the low-confidence ones are RecoveryCategory, ApprovalDate and LineCategory.

User read of the original sheet (Is Nullable): transaction RecoveryCategory = FALSE (not nullable); LineCategory = TRUE (nullable) and is a type key (typecode from the typelist table); ApprovalDate = TRUE (nullable), datetime.

## 7. Typelist rules found in the real typelist table (sample data)
- Columns: Vectus_TypeCode, Vectus_Description, Household/Motor/Both, Typelist_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name.
- Household/Motor/Both can be NULL (PaymentMethod, ReasonToStopCheque_Adm, ContactRole ...). Old filter ('Motor only','Both') skipped them: FIXED, NULL rows are used, 'Household only' rows never.
- Status typelists are keyed by the V2 status; the old "ClaimCenter code first" lookup was removed.
- Typelists without Vectus codes (ContactRole, CheckType, CheckBatching ...) are lists of valid GW codes: the codes written by procs 02-06 are checked against them in proc 01 (warning) and query V9.
- LineCategory typecode is resolved from typelist LineCategory (match on GW_TypeCode or Name) into IS_PAYMENT_MASTER_LINE_MOTOR.LineCategoryCode; proc 03 loads it.

## 8. Structure rules from the user (2026-10-09)
- Check payee ROLE (cc_claimcontactrole) is NOT part of the financial procs; it is added later in the claim contact role proc.
- Few source values (2-4) = CASE with hardcoded typecodes; many values = join to TYPELIST_TABLE_MAPPING.
- Common tables IS_TRANSACTION, IS_TRANSACTIONSET, IS_TRANSACTIONLINEITEM (real DDL given): Motor working tables are aligned to their column names, types and sizes; the final insert is a plain select (file 15). IS_CHECK / IS_CHECKPAYEE were created new from ccst_check / ccst_checkpayee (mapped columns, ids, foreign keys, NOT NULL columns, debug columns).
- User and group foreign keys (RequestingUserID, VoidStopUserID, CreateUserID) stay NULL until those transformations exist.
- Not loaded: PayeeDenormID, PayToDenorm (ClaimCenter fills denorm fields), 

- Update 2026-10-09 (user): every column listed in the payment mapping stays in the Motor working tables, also if the senior's IS table has no such column (ForEx amounts, rows 175/177/183 = 0). The final insert (file 15) copies only what the IS table has.
- Update 2026-10-09 (user): CreateTime logic -> LegacyCreateTime_Adm (transaction, line item, set, check); BookingDate unchanged.
