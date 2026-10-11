# Answers in plain English (second round of questions)
Real names are used. Where I give numbers they are made up and I say so. "Not confirmed" means the documents I have do not state it.

---------------------------------------------------------------------------------------------------
## 1. Will the procs fail every time there is an exception?
No. The exception list is only a report.
- The word "exception" in my procs is just a text in the column `ExceptionCode` of `IS_PAYMENT_MASTER_MOTOR`. No proc uses `THROW`, and the only `RAISERROR` calls are warnings with severity 10 (they print a message and the run continues).
- The exception proc (file 07) only copies those texts into `IS_PAYMENT_EXCEPTION_MOTOR` so you can read them.
- What I changed in this round: before, a row with a problem was marked `Loadable = 0` and was NOT copied to the transaction tables. Now the row is always copied. The missing value stays NULL and ClaimCenter will give the load error.
- The ONE row type that is still not copied: recoveries on PA cases. Reason: the mapping itself says so (row 136: "there are recovery transactions on PA_ANCIL v2 cases - these should not be migrated"). It is a switch at the top of `usp_Load_SS_to_IS_PAYMENT_MASTER_MOTOR`: `DECLARE @ExcludePaCredits BIT = 1;` Set it to 0 and they are copied like all other recoveries. They always stay in `IS_PAYMENT_MASTER_MOTOR`.
- To avoid a real SQL error stopping a run: the holding columns of the master table are now wide (for example `PayeeName` 500, `PostCode` 100), the date conversion of the status table uses `TRY_CONVERT`, and `DEBIT_CREDIT` is cut to 1 character when stored. This was not executed on SQL Server, so a first test run is still needed.

### Every place where a row was held back, and what it does now
| Where (proc 01, section) | Before | Now |
|---|---|---|
| S4 `#LINE` | lines with `DEBIT_CREDIT` other than D or C were removed and put in a separate master row | they stay in the normal flow with `CostType` NULL; flag `BAD_DEBIT_CREDIT` |
| S11 no reserve line | flag + `Loadable = 0` | flag only; `ReserveLineID` NULL |
| S11 no recovery reserve line / no recovery coding | `Loadable = 0` | flag only; `ReserveLineID` / `RecoveryCodingID` NULL |
| S11 injury, main line missing | another injury line was chosen and the row was held back | no line is guessed: `ReserveLineID` and `CostCategory` NULL; flag only |
| S11 unmapped dissection code, status, lifecycle, approval | `Loadable = 0` | flag only; the value is NULL |
| S11 payee found in V2 but not usable | `Loadable = 0` | flag only; `ClaimContactID` NULL; no dummy is invented |
| S11 dummy payee with blank `PAYEE_NAME` | not loadable | dummy created with `Name` NULL; flag `DUMMY_PAYEE_NO_NAME` |
| 01b dummy payee | name and address lines were cut to 60 characters, blank-name dummies were not made | nothing is cut; every dummy is made |
| 05 check, 06 check payee | only `Loadable = 1` rows | every payment row |
| 02, 03, 04 | only `Loadable = 1` rows | every row except PA recoveries (switch above) |

---------------------------------------------------------------------------------------------------
## 2. What is a "ClaimCenter transaction", and what are Reserve / RecoveryReserve / Payment / Recovery?
There are two different things in ClaimCenter, and they are in two different tables.

**Reserve line (`cc_reserveline`, here `IS_RESERVELINE_MOTOR`).** A place where money is booked. It is identified by (exposure + cost type + cost category). It is NOT money; it is the label. Example from the reserve lookup file (`ReserveLine_MOTOR_LOOKUP_mapping.txt`): for an AD exposure, cost type claim cost, cost category "Vehicle Damage" (code `pm_vehicle_damage_adm`).

**Transaction (`cc_transaction`).** One entry of money booked on ONE reserve line. The table `cc_transaction` has a column `Subtype` with four kinds of entry:
| Subtype | Who creates it | What it means | Reserve line it points to |
|---|---|---|---|
| `Reserve` | senior's proc `usp_Load_SS_to_IS_TRANSACTION_MOTOR` | the estimate (money the insurer expects to pay) put on a normal reserve line when it is created | normal line |
| `RecoveryReserve` | same senior's proc | the estimate (money the insurer expects to get back) put on a recovery reserve line | recovery line (PublicID ends `_rec`) |
| `Payment` | my procs (02) | money really paid out | normal line |
| `Recovery` | my procs (02) | money really received back | recovery line |

So "Subtype" in the transaction table says what KIND of entry it is. It is not a kind of reserve line. The senior's code: `CASE WHEN RL.IsRecovery = 1 THEN 'RecoveryReserve' ELSE 'Reserve' END AS Subtype` (lines 166–167 and 443–444 of her transaction proc). The two kinds of reserve entries are created from the reserve line itself: one `Reserve` entry per normal reserve line, one `RecoveryReserve` entry per recovery reserve line (amount from the reserve lookup, column AMOUNT_DEFAULT, for example £1.00 or the sum of V2 reserve values).
In one sentence: reserve lines are the places; `Reserve` / `RecoveryReserve` transactions put the estimate there; `Payment` / `Recovery` transactions record the real money there.

**Is one transaction = payment + recovery + reserve together?** No. One transaction is ONE entry of ONE kind on ONE reserve line. The payment master table (my procs) only contains `Payment` and `Recovery` entries. Reserves are the senior's procs and never appear in my tables.

**What is one row of the payment master table?** One future `Payment` or `Recovery` transaction. In most cases one V2 row of `VEC_GW_PAY_TRANS` gives one master row. It gives TWO master rows in two cases (BA transcript):
1. its dissections have different cost types (claim cost and expense): the V2 transaction is cloned, one per cost type;
2. a third-party transaction has hire and mobility codes together with other codes: hire and mobility goes to a different exposure, so it is cloned.
So the number of transactions is NOT fixed per claim, per AD CASE or per TP CASE. One exposure normally gets many transactions: one for each V2 payment or recovery on it, plus the extra clones.

---------------------------------------------------------------------------------------------------
## 3. Line item, "line table", MasterSuffix, MasterAmount, MasterCountInTran
**Dissection (`VEC_GW_PAY_DISS`).** A V2 payment is split in the source into one or more amounts, each with a code (column `CODE`). Made-up example: a payment of 500.00 has two dissection rows: 400.00 with code A and 100.00 with code B. The lookup `Lkp_Transaction_Typelist` says code A is claim cost and code B is expense.

**Transaction line item (the table `cc_transactionlineitem`).** The ClaimCenter version of a dissection: one row per amount inside a transaction (`TransactionAmount`, `LineCategory`, `TransactionID`). The BA: "one record in the transaction, one-to-many in the line item". The sum of the line items of a transaction is the transaction amount.

**Line table (`IS_PAYMENT_MASTER_LINE_MOTOR`).** My own working table: one row per dissection. Proc 01 fills it, proc 03 copies it into `IS_TRANSACTIONLINEITEM_PAY_MOTOR`. The word "line" in the name = "line item".

**MasterSuffix.** A short text added to the end of every PublicID of a master row so that two master rows of the same V2 transaction get different PublicIDs. Rules: `''` (empty) when the V2 transaction gives one master row; `_cc` for the claim cost part and `_ex` for the expense part when it gives two; an extra `h` for hire and mobility. Example (V2 transaction 900002, made up): `mig:motorpay_900002_cc` and `mig:motorpay_900002_ex`.

**MasterAmount.** The sum of the line items of that master row (400.00 for `_cc`, 100.00 for `_ex`).

**MasterCountInTran.** How many master rows the same V2 transaction has (here 2). If it is 1 the suffix is empty.

---------------------------------------------------------------------------------------------------
## 4. Transaction set (`cc_transactionset`)
- **What it is.** A ClaimCenter record that every transaction must point to (`cc_transaction.TransactionSetID`, mapping row 123: "1..1, every record in cc_transaction should be linked to a single record in cc_transactionset"). The word "set" is ClaimCenter's own name; the documents I have do not explain why ClaimCenter has it. For the migration it simply carries the approval data of its transaction.
- **What it contains** (mapping rows 199–209, proc 04): `Subtype` (`CheckSet` for a payment, `RecoverySet` for a recovery), `ApprovalStatus`, `ApprovalDate`, `ClaimID`, `CreatedVia` (`manual`), `RequestingUserID` (NULL for now), the create time (stored in `LegacyCreateTime_Adm`), `CashMoveNo_Adm`.
- **How many.** The BA: "each transaction record will relate to a transaction set record and a transaction set record will only relate to a single transaction" (transcript, line 80). So one transaction = one set; a split V2 payment (`_cc` and `_ex`) has two sets.
- **Where it is created.** Proc 04 -> `IS_TRANSACTIONSET_PAY_MOTOR` (PublicID `mig:motorpts_<TranID><MasterSuffix>`) -> file 15 copies it into `IS_TRANSACTIONSET`.
- **How it is linked.** `IS_TRANSACTION_PAY_MOTOR.TransactionSetID` = the set PublicID; for a payment, `IS_CHECK_MOTOR.CheckSetID` = the same set PublicID.
- **Your understanding** ("each transaction has a transaction set") is correct. Note: the senior's reserve transactions also have their own sets (PublicID starts `mig:motorts_`), with Subtype ReserveSet according to the mapping; mine start with `mig:motorpts_`.

---------------------------------------------------------------------------------------------------
## 5. Claim-level recovery line, and `pm_other_adm`
- Claim-level = money attached to the claim itself, not to AD, TP or PA: `VEC_GW_PAY_TRANS.CASEID` equals the CLAIM KEY (`GW_HDR_CASEID`). Proc 01 calls this `CaseType = 'HDR'`.
- The reserve lookup (`MOTOR_RESERVES_LOOKUP`) has four claim-level rows: ID 1 (RESERVE, claim cost, cost category `migrated_cost`), ID 2 (RESERVE, expense, `migrated_expense`), ID 3 (RECOVERY, `pm_reinsirance_recovery_adm`, for V2 reserve type 35) and **ID 4: RECOVERY, claim cost, cost category "Other", code `pm_other_adm`, recovery category Subrogation, "Create ONLY if there are transactions..."**.
- So `pm_other_adm` is nothing special: it is the code of the cost category "Other" on the claim-level RECOVERY reserve line. That line should exist when a recovery (credit) has been booked on the claim itself.
- What the senior's reserve line proc does (`usp_Load_SS_to_IS_RESERVELINE_MOTOR`, the block that starts at line ~795): it creates the claim-level lines `migrated_cost` and `migrated_expense` for claims that have a PAYMENT on the claim itself. I searched the file for `other` and `pm_other`: there is no claim-level recovery line with `pm_other_adm`.
- Consequence: a recovery whose `CASEID` is the CLAIM KEY has no recovery reserve line to point to. In my master table it keeps `ReserveLineID` NULL (flag `NO_RECOVERY_RESERVE_LINE`) and ClaimCenter will report it. That is BA question 1 and senior item S-2: should that line be created, and by whom.
- Real example: the BA's own transcript example, the claim whose CLAIM KEY ends 9004, has 4 transactions; one is a recovery of 2 pence on the claim itself.

---------------------------------------------------------------------------------------------------
## 6. Recovery coding: what it is and the five points, one by one
**What it is.** `cc_recoverycoding` (here `IS_RECOVERYCODING_MOTOR`): one row per recovery reserve line (mapping: "Every recovery reserve line needs to be linked to a record in the Recovery coding entity"). Columns we use: `PublicID`, `ReserveLineID`, `RecoveryCategory`. A recovery transaction has a column `RecoveryCodingID` pointing to it.

**The senior's two procs that touch it**
1. `usp_Load_SS_to_IS_TRANSACTION_MOTOR` (reserve transactions): for each `RecoveryReserve` transaction it writes `RecoveryCodingID` = `'mig:motorrc_' + token + case id + '_' + cost type + '_rec'`.
2. `usp_Load_SS_to_IS_RECOVERYCODING_MOTOR` (coding rows): it reads those `RecoveryReserve` transactions and creates the coding row whose `PublicID` has the same pattern.
So the coding row exists only if the reserve transaction exists and if both procs build the same PublicID.

**Point 1. Order of procs.** The coding proc reads `IS_TRANSACTION_MOTOR WHERE Subtype = 'RecoveryReserve'`. If the transaction proc has not run yet, or did not create a `RecoveryReserve` row for a recovery line, no coding row exists. My master proc then leaves `RecoveryCodingID` NULL (flag `NO_RECOVERY_CODING`).

**Points 2 and 3. "Token".** A token is the short text in the middle of the PublicID that says what kind of line it is: for AD the text `ad` is written directly; for TP the proc translates the exposure kind: `TP_VEH` -> `tpveh`, `TP_PRO` -> `tppro`, `TP_INJ` -> `tpinj`, `TP_CLAIM` -> `tpclaim`.
- In the coding proc the TP part reads origins `'TP_VEH','TP_PRO','TP_INJ','TP_HIRE','TP_CLAIM','HDR'` (its `WHERE`), but the translation (`CASE TP.SourceOrigin_Adm`) only knows the first, second, third and fifth. For `HDR` (claim-level) and `TP_HIRE` the translation gives NULL, and `'mig:motorrc_' + NULL + ...` is NULL, so the coding row would have an empty PublicID.
- Does it matter today? Only if a `RecoveryReserve` transaction with origin `HDR` or `TP_HIRE` exists. `HDR`: not today, because the claim-level recovery line (section 5) is not created. `TP_HIRE`: the reserve line proc never puts a recovery line on hire and mobility (`RecoveryHere = 0` for H&M). So today these two points change nothing. They become a problem if the senior adds the claim-level recovery line: her transaction proc does know the token `hdr` (line 224), so the reserve transaction would point to `mig:motorrc_hdr...` but the coding proc could not create that row.

**Point 4.** Same as section 5 above.

**Point 5. "Category text".** `RecoveryCategory` is a typelist: the column must hold the CODE `subro`. "Subrogation" is only the name shown on screen (mapping row 126: "Default to Subrogation (code: 'subro')"). The senior's transaction proc writes the word `Subrogation` (`CASE WHEN RL.IsRecovery = 1 THEN 'Subrogation'`), and the coding proc copies `TX.RecoveryCategory` unchanged. So the reserve transactions and the coding rows would carry `Subrogation` where the code `subro` is needed. My procs write `subro`. Whether `Subrogation` is also accepted as a value in the typelist table is not confirmed: check `TYPELIST_TABLE_MAPPING` (file 14, part B).

**Why I said "recovery coding is wrong" in the senior's procs.** It is not wrong in design; the points above are places where it can give an empty or wrong value. The only point that affects my recoveries today is point 1 (order and completeness).

**The conflict in the BA's words (BA-9) and the PA doubt.** I could not find my original wording in the saved chat, so I rebuilt it from the files:
- (a) The mapping says the coding row is "created for the reserveline under which this recovery transaction will be created" (row 129) and the transcript says reserve line 1 has coding 22 and the recovery transaction carries coding 22 (transcript lines 77–79). That means ONE coding row per recovery reserve line, shared by all recoveries on that line. This is what my code does.
- (b) The mapping rows 95–96 (cc_recoverycoding `ReserveLineID`, `RecoveryCategory`) say "ONLY for RECOVERY TRANSACTIONS", and the transcript says "recovery code record, single if my transaction is a recovery" (line 56). Read literally this could mean one coding row per recovery transaction.
- PA doubt: reserve mapping creates no recovery reserve for PA (the senior's comment: "PA cases are all finalised, so no rec reserve"), but the payment mapping row 136 talks about recovery transactions on PA cases and says they should not be migrated. So a PA recovery would have no recovery reserve line and no recovery coding anyway.
Both are open as BA-9 and BA-15 in file 10. Tell me if your memory is a different question.

---------------------------------------------------------------------------------------------------
## 7. The status paragraph of the example
Table `VEC_GW_PAY_STATUS`: every V2 payment has several rows over time, one row each time its status changes (columns `GW_PAY_TRAN_ID`, `STATUS_TYPE`, `RECORD_DATE`, `RECORD_TIME`, `REASON`, `GCURRENT`, `ID`). The row with `GCURRENT = 'X'` is the latest one: the CURRENT status. Made-up example, V2 payment 900002:

| ID | STATUS_TYPE | RECORD_DATE | GCURRENT |
|---|---|---|---|
| 1 | AUTH | 2024-01-02 | |
| 2 | GRP_AUTH | 2024-01-03 | |
| 3 | PAID | 2024-01-05 | X |

What each is used for (mapping and BA text):
| Value | Used for | Rule |
|---|---|---|
| the row with `GCURRENT = 'X'` | `cc_transaction.Status` (and life cycle, approval status) through the typelist mapping, keyed by `STATUS_TYPE` | mapping row 125 |
| first row (lowest `ID`) | create time of the transaction, line item, set, check (kept in `LegacyCreateTime_Adm`) and the booking date | mapping rows 132, 182, 202 |
| `AUTH` or `GRP_AUTH` | `ApprovalDate` of the transaction set (latest of them; for recoveries the first row) | mapping row 209 |
| `PAID` | check `EnteredTime` and `IssueDate` | rows 33, 41 |
| `PRESENTED` | check `ChequePresentedDate_Adm` | row 18 |
| `CANX` | `ChequeStopReason_Adm` (from `REASON`) and `VoidStopUserID` | rows 19, 53 |
The plain meaning of the codes (authorised, authorised as part of a group, paid, cheque presented, cancelled) is my reading of the names; the documents only say how each is used. Not confirmed by the BA.

In the example: 900001 AUTH then PAID (current = PAID); 900002 AUTH, GRP_AUTH, PAID (current = PAID); 900003 only AUTH (current = AUTH, not yet paid); 900004 only PAID. The dissection paragraph is explained in section 3.

---------------------------------------------------------------------------------------------------
## 8. The reserve lines in the example (what the names mean)
In the guide's example I wrote labels such as `RL-AD-CC` and "TP vehicle claim cost line". They are made-up labels for real reserve lines (rows of `IS_RESERVELINE_MOTOR`). The real names come from the reserve lookup:
| Label in the example | Real meaning (lookup file) |
|---|---|
| AD claim cost line | AD exposure, cost type claim cost, cost category Vehicle Damage (`pm_vehicle_damage_adm`); PublicID pattern `mig:motorrl_ad<AD id>_claimcost` |
| AD recovery line | same exposure, Subtype RECOVERY, PublicID ends `_rec` |
| TP vehicle claim cost line | TP vehicle exposure, claim cost, category "Third Party Vehicle Damage" |
| TP vehicle expense line | same exposure, expense (`aoexpense`), category "TP Vehicle Damage Fees" |
| TP vehicle recovery line | same exposure, RECOVERY, claim cost, "Third Party Vehicle Damage" |
| TP injury lines | TP bodily injury exposure: claim cost "Injury" (`pm_injury_adm`) and expense "Third Party Solicitors Costs" |
Claim cost / expense = the two cost types. A payment of cost type claim cost goes to the claim cost line of its exposure; expense goes to the expense line; a recovery goes to the recovery line.
