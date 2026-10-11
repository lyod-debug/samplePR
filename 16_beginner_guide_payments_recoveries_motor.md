# Beginner guide: payments, recoveries, reserves and the payment master proc (Motor)

Read in order. Each part uses only words explained before it.
All numbers in the example claim are MADE UP to show the steps. The table and column names are the real ones.
The words CLAIM KEY, CASE, CONTACT RECORD are used as in the project rules: CLAIM KEY = `GW_HDR_CASEID`; CASE = a row of `VEC_GW_MOTOR_AD`, `VEC_GW_MOTOR_TP` or `VEC_PA_ANCILLARY` (identified by its `ID`); CONTACT RECORD = `VEC_GW_CF_HDR.ID` (`HDR_ID`).

---------------------------------------------------------------------------------------------------
## PART 1. The words

**Claim.** One insurance claim, for example a car accident. In the source system (Vectus, "V2" tables) it is identified by the CLAIM KEY (`GW_HDR_CASEID`) and has a claim number (`CLAIM_REF`). In ClaimCenter it is one row of `cc_claim`.

**CASE (AD / TP / PA).** A claim is split into parts. In Vectus each part is a row in its own table:
- AD = "accidental damage": the damage to our own policyholder's vehicle (`VEC_GW_MOTOR_AD`).
- TP = "third party": a person or vehicle that is not our policyholder but is hurt or damaged in the accident (`VEC_GW_MOTOR_TP`). One claim can have many TP rows.
- PA = personal accident or ancillary (`VEC_PA_ANCILLARY`).
- HDR = no part at all: the money is attached to the claim itself (the payment's `CASEID` equals the CLAIM KEY).
The column `VEC_GW_PAY_TRANS.CASEID` says which CASE a payment belongs to. The proc works this out in section S2 (column `CaseType`).

**Exposure.** The ClaimCenter name for "a part of the claim that can cost money". An AD CASE becomes one exposure. A TP CASE can become up to four exposures: vehicle (`TP_VEH`), property (`TP_PRO`), injury (`TP_INJ`) and hire and mobility (`TP_HIRE`). The column `SourceOrigin_Adm` holds these names. The table is `IS_EXPOSURE_MOTOR` (built by another proc).

**Reserve.** An amount of money the insurer writes down as "we expect to pay about this much on this part". It is an estimate, not a payment. No money moves.

**Cost type.** Whether the amount is for the claim itself (`claimcost`, for example repairing a car) or for the expenses of handling it (`aoexpense`, for example solicitor fees). Hire and mobility is an exposure of its own.

**Reserve line.** One row of reserve = (one exposure) + (one cost type) + (one cost category such as `pm_injury_adm`). It is a row of `IS_RESERVELINE_MOTOR`, built by the senior's reserve line proc. Its `PublicID` identifies it. Every payment and every recovery must say which reserve line it belongs to (column `ReserveLineID`). In the mapping `ReserveLineID` is a foreign key of every transaction, so a payment or recovery without one is not loaded (exception `NO_RESERVE_LINE` / `NO_RECOVERY_RESERVE_LINE`).

---------------------------------------------------------------------------------------------------
## PART 2. Payment, recovery, and where they differ

**Payment.** Money that LEAVES the insurer: for example the cost of repairing the policyholder's car, paid to a garage. In Vectus: a row in `VEC_GW_PAY_TRANS` with `DEBIT_CREDIT = 'D'` (debit). In ClaimCenter: a `cc_transaction` row with Subtype `Payment`.

**Recovery.** Money that COMES BACK to the insurer: for example, the insurer paid its policyholder, then the other driver's insurer repays part of it. In Vectus: a row in `VEC_GW_PAY_TRANS` with `DEBIT_CREDIT = 'C'` (credit). In ClaimCenter: a `cc_transaction` row with Subtype `Recovery`. The business word for it is subrogation (code `subro`).

Both are rows of the same V2 table `VEC_GW_PAY_TRANS` with the same dissection table (`VEC_GW_PAY_DISS`), the same status table (`VEC_GW_PAY_STATUS`) and the same proc, so the manager is right that they "follow the same approach". They differ in these places:

| Topic | Payment (debit, D) | Recovery (credit, C) |
|---|---|---|
| ClaimCenter `Subtype` of the transaction | `Payment` | `Recovery` |
| Which reserve line | the MAIN reserve line of the exposure (a normal reserve line) | the RECOVERY reserve line of the exposure (PublicID ends `_rec`) |
| Cost type | decided per dissection from `Lkp_Transaction_Typelist` (claimcost or aoexpense, hire) | always `claimcost` (BA rule) |
| Line item text (LineItem) | `Migrated Payment` | `Migrated Recovery` |
| Check (`cc_check`, `cc_checkpayee`) | YES, one check and one check payee per payment | NO |
| Payee, in-care-of, dummy payee | YES | NO |
| Recovery coding (`RecoveryCodingID`) | NO | YES, mandatory |
| `RecoveryCategory` | not set | `subro` |
| `PaymentType`, `DoesNotErodeReserves`, `CloseExposure`, `CloseClaim` | set (`partial`, 1, 0, 0) | not set |
| `CashMoveNo`, `ChequeNumber` | on the check | on the transaction (`DenormCashMoveNo_Adm`, `ChequeNumber_Adm`) |
| Transaction set `Subtype` | `CheckSet` | `RecoverySet` |
| `ApprovalDate` | latest AUTH / GRP_AUTH status date, else first status date | first status date |
| Origin of a TP credit | the exposure with the most specific content (see S11 `TargetOrigin`) | the exposure that carries the recovery line (`#RLREC`: vehicle first, then property, then injury, never hire) |
| PA (ancillary) | loaded | NOT migrated (mapping: V2 data issue) -> exception `PA_CREDIT_NOT_MIGRATED` |
| Extra exception codes | `NO_RESERVE_LINE`, `NO_MAIN_INJ_LINE`, payee codes | `NO_RECOVERY_RESERVE_LINE`, `NO_RECOVERY_CODING` |

---------------------------------------------------------------------------------------------------
## PART 3. Recovery reserve, "recovery only", recovery coding

**Recovery reserve (recovery reserve line).** A normal reserve line is an estimate of money to PAY. A recovery reserve line is an estimate of money to RECEIVE. In `IS_RESERVELINE_MOTOR` its `PublicID` ends with `_rec`. A recovery can only be booked on a recovery reserve line.

**"Recovery only".** I read this as the rule in the senior's reserve line proc: reserve lines are ALWAYS created, but a recovery line is created ONLY where recovery is expected ("RESERVE rows always, RECOVERY rows only where RecoveryHere = 1"; for AD "recovery line only where eligible", `AD_RECOVERY_ELIGIBLE`). For a TP CASE the recovery line sits on ONE exposure only (vehicle first; property if there is no vehicle; injury if neither; never hire and mobility). If you meant a different phrase, tell me where you saw it and I will explain that one.
Consequence for my proc: a recovery can only be loaded if its CASE has a recovery line. If not, the master row gets exception `NO_RECOVERY_RESERVE_LINE`.

**Recovery coding.** A ClaimCenter table (`cc_recoverycoding`, here `IS_RECOVERYCODING_MOTOR`) with one row per recovery reserve line. It holds the `RecoveryCategory` (`subro`) and the `ReserveLineID`. A recovery transaction must point to it (`IS_TRANSACTION_PAY_MOTOR.RecoveryCodingID`). The BA transcript says every recovery transaction needs a recovery coding record, and the mapping fills `RecoveryCodingID` for recoveries only. It classifies the recovery (what kind: `RecoveryCategory`) and ties it to its recovery reserve line. A payment has no recovery coding. (Whether ClaimCenter itself rejects a recovery without it is not stated in the documents I have; my proc simply does not load such a recovery.)
My proc does not create coding rows. It looks them up: section S11, CTE `C`: `LEFT JOIN IS_RECOVERYCODING_MOTOR RC ON RC.ReserveLineID = RS.ReserveLinePublicID AND B.DC = 'C'`. If no row is found: exception `NO_RECOVERY_CODING`.

---------------------------------------------------------------------------------------------------
## PART 4. Why recovery coding in the senior's procs gives problems

File: `usp_Load_SS_to_IS_RECOVERYCODING_MOTOR` (the senior's). It builds coding rows from `IS_TRANSACTION_MOTOR` rows where `Subtype = 'RecoveryReserve'`, i.e. from the senior's reserve TRANSACTION rows, not from the reserve lines directly. Five points:
1. **It depends on another proc's output.** If a `_rec` reserve line has no `RecoveryReserve` reserve transaction (for example when the transaction proc skips it), no coding row exists, and my recoveries on that line stop with `NO_RECOVERY_CODING`. The reserve transaction proc must run first and must create one for every `_rec` line.
2. **No token for the claim-level origin `HDR`.** Its second part (`#TP`) accepts `SourceOrigin_Adm IN (..., 'HDR')`, but the `CASE TP.SourceOrigin_Adm` that builds `PublicIDToken` has no `HDR` branch, so the token is NULL and the whole `PublicID` ('mig:motorrc_' + NULL + ...) becomes NULL.
3. **No token for `TP_HIRE`.** Same effect. Harmless today, because recoveries never go to hire and mobility.
4. **`pm_other_adm` is never created.** The claim-level recovery line (reserve lookup row 4) is not created by the reserve proc, so credits on the claim itself (BA-1) have nowhere to go.
5. **Category text.** The coding row copies `TX.RecoveryCategory` from the reserve transaction, which the reserve transaction proc writes as `Subrogation`; the typelist code is `subro` (my proc writes `subro`). The two must be the same or the foreign key to the typelist fails.
None of these is a mistake of my code; they are what my recoveries depend on. They are listed as senior items S-2, S-4, S-5 in file 10.

---------------------------------------------------------------------------------------------------
## PART 5. Why the table is called "payment master", and what "unit" meant

I first called one prepared row a "payment unit" (the word meant "one piece that becomes one ClaimCenter transaction"). That word has no meaning outside this project, so it is replaced.
**IS_PAYMENT_MASTER_MOTOR** = the master list. One row per ClaimCenter transaction to be created from the V2 payments and recoveries. It is the one table where every decision is made once (case type, cost type, exposure, reserve line, recovery coding, status, dates, payee, exception). The other procs (02 transaction, 03 line item, 04 transaction set, 05 check, 06 check payee) only copy fields from it and add fixed values. This is the same idea as `IS_CLAIM_MASTER` and `CONTACT_MASTER_MOTOR`: a master table that other procs read.
Sentence for managers: "The payment master table has one row for each transaction we will create in ClaimCenter. All business rules are applied once, when it is filled. If a row cannot be loaded, it stays in the table with an error code, so nothing disappears silently."
Names: table `IS_PAYMENT_MASTER_MOTOR`, line table `IS_PAYMENT_MASTER_LINE_MOTOR`, proc `usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR`, columns `MasterSuffix`, `MasterAmount`, `MasterCountInTran`.

---------------------------------------------------------------------------------------------------
## PART 6. The example claim

Made-up claim, claim number `EX-1`, CLAIM KEY `5000`. It has:
- one AD CASE (id 6001): our policyholder's car.
- one TP CASE (id 7001) with a vehicle exposure and an injury exposure.

Reserve lines (built by the senior's procs, they already exist in `IS_RESERVELINE_MOTOR`):
- AD, claimcost line (PublicID `RL-AD-CC`) and AD recovery line (`RL-AD-REC`).
- TP vehicle claimcost line, expense line, and the recovery line (`RL-TPV-REC`); TP injury lines.

V2 payments of the claim (`VEC_GW_PAY_TRANS`):

| TranID | CASEID | DEBIT_CREDIT | AMOUNT | PAYEE_LINKID | ADD_LINKID | PAYEE_NAME | what it is |
|---|---|---|---|---|---|---|---|
| 900001 | 6001 | D | 1,000.00 | 573 | NULL | GARAGE ONE | repair paid to a garage whose link is in the contact data |
| 900002 | 7001 | D | 500.00 | 574 | 575 | TP SOLICITORS | one payment with two dissections: 400.00 claim cost and 100.00 expense; paid via a care-of person |
| 900003 | 6001 | D | 250.00 | NULL | NULL | ABC RECOVERY LTD | payee link missing; the V2 row has ADDRESS_LINE1 `1 HIGH STREET`, POST_CODE `AB1 2CD` |
| 900004 | 7001 | C | 300.00 | NULL | NULL | NULL | money received back on the TP CASE |

Status history (`VEC_GW_PAY_STATUS`): 900001: AUTH then PAID (PAID is the current row, `GCURRENT = 'X'`). 900002: AUTH, GRP_AUTH, PAID. 900003: AUTH (current). 900004: PAID.
Dissections (`VEC_GW_PAY_DISS`): 900001: one row 1,000.00 code A (lookup says `claimcost`). 900002: 400.00 code A (`claimcost`) and 100.00 code B (lookup says `aoexpense`). 900003: 250.00 code A. 900004: 300.00.
The CONTACT RECORDS: link 573 belongs to CONTACT RECORD 11 (`VEC_GW_CF_LINK.GWCF_HDRID = 11`), link 574 to 12, link 575 to 13. In `CONTACT_MASTER_MOTOR` the kept (MAX) link of record 11 is 5730 (a newer link of the same person), so 573 is NOT in the contact master. This is exactly why the proc goes through the CONTACT RECORD.

### Walkthrough of `usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR` (file 01)

**Start.** The two output tables are emptied (`TRUNCATE`). The proc can therefore be run again at any time.

**S1 (line ~34): read the V2 payments of Motor claims.** `IS_CLAIM_MASTER` is joined to `VEC_GW_PAY_TRANS` on CLAIM KEY, only `PRODUCT = 'MOTOR'`. Result `#TX0`: 4 rows (900001-900004), with the amount rounded to pennies, `PayeeLinkKey` = `PAYEE_LINKID` as a number (0 or non-number becomes NULL), `AddLinkKey` likewise, address text, post code, and the gateway id.
**S2 (line ~69): find the CASE type.** 900001 and 900003: `CASEID` 6001 is in `VEC_GW_MOTOR_AD` -> `CaseType = 'AD'`. 900002 and 900004: 7001 is in `VEC_GW_MOTOR_TP` -> `'TP'`. The join also demands the same CLAIM KEY, so an id from another claim can never match. `#CS` reads the live status of the CASE (information only).
**S3 (line ~108): dissections = line items.** Each V2 dissection row becomes one line. 900002 gets two lines (400.00 code A, 100.00 code B). A payment with no dissection row at all gets one line with the full amount.
**S4 (line ~130): cost type per line.**
 - Debits: look up code and CASE type in `Lkp_Transaction_Typelist` (motor rows, debit). A specific row for TP beats the general row. Code A -> `claimcost`, code B -> `aoexpense`. `IsHire` = 1 if the lookup row is hire and mobility.
 - Credits: always `claimcost`, line text `Migrated Recovery`. The credit rows of the lookup are not read.
 - `#TXSUM` adds the lines of each payment to compare with the V2 amount (difference -> warning `DISS_SUM_MISMATCH`).
**S5 (line ~200): master rows.** One master row per (V2 payment, cost type, hire flag). 900001 -> 1 master row. 900002 -> 2 master rows (claim cost 400.00, expense 100.00). 900003 -> 1. 900004 -> 1. The suffix keeps PublicIDs unique: `''` when there is one master row, otherwise `_cc` (claim cost) or `_ex` (expense), plus `h` for hire and mobility. 900002 gives `_cc` and `_ex`. Result: 5 master rows.
**S6 (line ~218): which exposures exist** (`IS_EXPOSURE_MOTOR`). `#TPFLAG` tells, per TP CASE, whether vehicle / property / injury / hire exposures exist. `#ADEXP`, `#ADCNT` tell which AD CASE has the exposure (a claim with several AD CASES keeps only one exposure; a payment on a removed AD CASE is moved to the surviving one, warning `AD_REMAPPED_TO_SURVIVING_CASE`).
**S7 (line ~251): reserve lines.** `#RLC` lists the reserve lines of these claims from `IS_RESERVELINE_MOTOR`, marks recovery lines (`_rec`), and for injury marks the main line. `#RLSEL` keeps ONE line per (claim, origin, CASE, cost type, recovery or not). `#RLREC` finds the one exposure of a TP CASE that carries the recovery line.
**S8 (line ~318): status history.** `#STAT` reads `VEC_GW_PAY_STATUS`; `#STD` takes: current status (`GCURRENT = 'X'`), first date (CreateTime), latest AUTH / GRP_AUTH date (approval), PAID date, PRESENTED date, CANX date and reason.
**S9 (line ~369): typelists.** Reads `TYPELIST_TABLE_MAPPING` to turn V2 status codes into ClaimCenter codes (`Status`, `LifeCycleState`, `ApprovalStatus`, payment method, cheque stop reason) and checks that every fixed code my procs write exists (message `WARNING ... NOT in TYPELIST_TABLE_MAPPING`).
**S10 (line ~442): payee and in-care-of person (debits only).** Steps for the example:
 1. `#PAYLINK`: the list of (CLAIM KEY, link id) used by debits: 573, 574, 575 (900003 has none).
 2. `#PAYHDR`: for each link read `VEC_GW_CF_LINK` and take `GWCF_HDRID`: 573 -> record 11, 574 -> 12, 575 -> 13.
 3. `#PAYCON`: find the row in `CONTACT_MASTER_MOTOR` with that `HDR_ID` on the SAME claim: record 11 -> contact PublicID `mig:motor11`, etc. (This works although link 573 itself is not in the contact master.)
 4. `#PAYCC`: find the claim contact in `IS_CLAIMCONTACT` for (contact, claim). Result per link: contact PublicID, claim contact PublicID, record id.
 Resolution (column `PayeeResolution`): 900001: `OK`; 900002: `OK` (payee 574; in-care-of 575 found); 900003: `NO_PAYEE_LINK` = dummy payee.
**S11 (line ~518): put everything together and decide the exceptions.**
 - CTE `B`: joins S2-S10 for every master row. Computes the target origin: AD -> `AD`; TP debit -> the exposure that matches the cost type (hire -> `TP_HIRE`; otherwise vehicle, else property, else injury); TP credit -> the exposure with the recovery line. Also reads the payee fields, `GatewayRef` (`VEC_GW_PAY_GATEWAY.TRANS_REF` trimmed), and the status dates.
 - CTE `C`: finds the reserve line (`#RLSEL`: same claim, origin, CASE, cost type, recovery or not), exposure, cost category, and for credits the recovery coding row. Looks up the typelist codes. Sets `IsDummy` (payee link missing).
 - Final select: `ExceptionCode` is the FIRST matching reason in the CASE list (information only: the row is still copied), for example `NO_RESERVE_LINE`, `NO_RECOVERY_RESERVE_LINE`, `NO_RECOVERY_CODING`, `UNMAPPED_STATUS`, the payee codes. `WarnList` gathers further notes separated by `;` (`DUMMY_PAYEE`, `INCAREOF_NOT_FOUND`, `DISS_SUM_MISMATCH`...).
 Example outcome: 
 - 900001: `AD`, reserve line `RL-AD-CC`, status PAID, payee contact `mig:motor11`, claim contact found, no exception -> no exception (every master row is copied on; `Loadable` is 1).
 - 900002 `_cc`: `TP_VEH`, TP vehicle claim-cost line; 900002 `_ex`: TP vehicle expense line. Both share the same payee. In-care-of contact = `mig:motor13`.
 - 900003: dummy payee: `PayeeContactID = mig:motorpayee_900003`, `PayeeClaimContactID = mig:motorpayeecc_900003`, `IsDummyPayee = 1`, warning `DUMMY_PAYEE`. Status AUTH (not paid).
 - 900004: credit on TP: origin = the exposure carrying the recovery line (vehicle), reserve line `RL-TPV-REC`, `RecoveryCodingID` = the coding row of that line. If the coding row did not exist: `NO_RECOVERY_CODING`, not loaded.
**S12 (line ~673): write.** `IS_PAYMENT_MASTER_MOTOR` gets the 5 master rows; `IS_PAYMENT_MASTER_LINE_MOTOR` gets the lines with the LineCategory code from the typelist (`Migrated Payment` for debits, `Migrated Recovery` for credits). A V2 row whose `DEBIT_CREDIT` is neither D nor C is written as a master row with exception `BAD_DEBIT_CREDIT`. Nothing is deleted.

### What the other procs do with the example
- **01b `usp_Load_SS_to_IS_PAYEE_DUMMY_MOTOR`:** for 900003 creates dummy address `mig:motorpayeeadr_900003` (`1 HIGH STREET`, `AB1 2CD`, State `GB_E_Adm`), dummy company contact `mig:motorpayee_900003` (Name `ABC RECOVERY LTD`, Subtype `Company`, AutoSync `Disallow`, Notes `Contact created for migration purpose - Do not use`, PreferredCurrency `gbp`, PreferRemitChannel_Adm `email`, PrimaryAddressID = the dummy address) and dummy claim contact `mig:motorpayeecc_900003` (ClaimantFlag 0).
- **02 transaction:** one `cc_transaction` row per master row (all except PA recoveries when `@ExcludePaCredits = 1`): `mig:motorpay_900001`, `mig:motorpay_900002_cc`, `mig:motorpay_900002_ex`, `mig:motorpay_900003`, `mig:motorpay_900004`. The recovery one has `Subtype = 'Recovery'`, `RecoveryCategory = 'subro'`, `RecoveryCodingID`; the others `Payment`, `PaymentType = 'partial'`, `CheckID`.
- **03 line item:** one row per line: `mig:motorpli_900002_cc_1` (400.00), `mig:motorpli_900002_ex_1` (100.00)...
- **04 transaction set:** one set per transaction: `mig:motorpts_900001`...; Subtype `CheckSet` (payments) or `RecoverySet`.
- **05 check:** one check per payment (not for 900004): `mig:motorchk_900001`, `mig:motorchk_900002_cc`, `mig:motorchk_900002_ex`, `mig:motorchk_900003`. Pay contact fields: `ClaimContactID` = payee claim contact; `InCareOf_Adm` = `mig:motor13` for 900002 (both checks); `MailingAddressID` = primary address of `mig:motor13`; `MailTo` = payee address text (only because in-care-of is filled); `PayTo` = first name + space + last name of the payee claim contact (empty for companies and for the dummy, BA-27).
- **06 check payee:** exactly one per check, `mig:motorchp_<TranID><suffix>`, `PayeeType = 'checkpayee'`, `ClaimContactID` = the check's. The role row `checkpayee` (`cc_claimcontactrole`) is created later in the claim contact role proc.
- **07 exception:** lists every master row with `ExceptionCode` (severity ERROR) and every warning (severity WARN), with counts and amounts.
- **08 / 09:** checks (file 08 must be empty; file 09 are read-only data questions).

---------------------------------------------------------------------------------------------------
## PART 7. Reading an exception (cheat sheet for KT)

| ExceptionCode | Meaning | Where to look |
|---|---|---|
| `BAD_DEBIT_CREDIT` | `DEBIT_CREDIT` is not D or C | `VEC_GW_PAY_TRANS.DEBIT_CREDIT` |
| `NO_CLAIM_PUBLICID` | claim missing in `IS_CLAIM_MASTER` | claim master proc |
| `CASETYPE_UNKNOWN` | `CASEID` is not the claim, AD, TP or PA | S2 |
| `PA_CREDIT_NOT_MIGRATED` | recovery on a PA CASE (not migrated, BA-15) | none (by design) |
| `UNMAPPED_DISS_CODE` | dissection code has no lookup row (BA-7) | `Lkp_Transaction_Typelist` |
| `NO_CURRENT_STATUS`, `UNMAPPED_STATUS`, `UNMAPPED_LIFECYCLE`, `UNMAPPED_APPROVAL_STATUS` | no current status row, or the V2 status is not in the typelists | `VEC_GW_PAY_STATUS`, `TYPELIST_TABLE_MAPPING` |
| `AD_EXPOSURE_AMBIGUOUS` | claim has several AD exposures and the payment's AD CASE has none | `IS_EXPOSURE_MOTOR` |
| `NO_EXPOSURE_FOR_CASE` | the CASE has no matching exposure | exposure proc |
| `NO_RESERVE_LINE` | no main reserve line for (exposure, cost type) | reserve line proc |
| `NO_MAIN_INJ_LINE` | injury main line missing (BA-3) | reserve line proc |
| `NO_RECOVERY_RESERVE_LINE` | credit but no `_rec` line (BA-1, BA-2) | reserve line proc |
| `NO_RECOVERY_CODING` | `_rec` line has no coding row | senior's recovery coding proc (part 4) |
| `DUMMY_PAYEE_NO_NAME` | payee link missing and PAYEE_NAME blank | `VEC_GW_PAY_TRANS.PAYEE_NAME` |
| `PAYEE_LINK_HAS_NO_HDR`, `PAYEE_NOT_IN_CONTACT_MASTER`, `PAYEE_CONTACT_OTHER_CLAIM`, `PAYEE_NO_CLAIMCONTACT` | payee found in V2 but not usable (BA-28) | file 09 Q17 / Q17b |
| `NO_STATUS_DATE` | status row without a date | `VEC_GW_PAY_STATUS.RECORD_DATE/TIME` |

Quick investigation: `SELECT * FROM IS_PAYMENT_MASTER_MOTOR WHERE TranID = <id>` shows every decision for the payment; `IS_PAYMENT_EXCEPTION_MOTOR` shows the reasons; `WarnList` shows the notes.
