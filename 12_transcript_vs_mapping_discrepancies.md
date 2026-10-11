# Payments: BA transcript vs mapping files - discrepancies (Motor)

How to read the references
- MAP = `payments-recoveries_source_to_target_mapping_of_each_fields.txt`. "line" = line number in that .txt file. "row" = the spreadsheet row number printed in the table. The top table (lines 15-94) is the grid; the text under it (lines 107-514) is the cut-off detail.
- LKP = `MOTOR_Payment-Recovery_LOOKUP_MAPPING_TABLE.txt` (line numbers of that .txt file).
- TR = `BA_transcripts_for_payments_motor.txt`. The file has only 84 lines and each line is a long paragraph, so I give the line number AND the words to search for.
- SQL1 / SQL2 = BA SQL part 1 / part 2. PAYEE = `Payee_contact_mapping.txt`.

## A. Real conflicts: the mapping says one thing, the transcript says another

| # | Topic | Mapping side | Transcript side | What my code does today | Ask the BA |
|---|---|---|---|---|---|
| 1 | Recovery coding: one per recovery transaction, or one per recovery reserve line? | MAP rows 95-96 (lines 48-49, 282-287): "ONLY for RECOVERY TRANSACTIONS". Row 129 (line 432-434): the transaction links to the coding "created for the reserveline". | TR line 50: "you will have one record for each one of your recovery transaction records". TR lines 73-77 ("ID number one", "number 22"): the transaction reuses the coding of its reserve line. | Reuse the reserve line's coding. No new rows. | Is coding created once per recovery reserve line and reused (TR 73-77), or one new row per recovery transaction (TR 50)? |
| 2 | Split a payment into several transactions | MAP row 174 comment (line 482): "NOT NECESSARY to split to multiple check-transactions if the check is not part of a bulk invoice". | TR line 50 (search "create two transactions"): MUST split when some dissections are claim cost and some are expense. TR line 80 (search "separate records in the transaction set"): each split gets its own set. | Split. Each split part has its own set, check and payee. | Confirm the row 174 comment is not an exception. Both split parts will carry the same cheque number (TRANS_REF). Is that OK? |
| 3 | PayeeDenormID (RESOLVED: not loaded, ClaimCenter fills it) | MAP row 87 (grid line 45): mapped from PAYEE_LINKID, "link to the contact". | TR line 82 (search "PayeeDenorm" / "not in the staging tables"): "developers ignore this for now". ClaimCenter fills it. | RESOLVED by the user: not loaded (ClaimCenter fills it). Column removed from DDL and proc 06. | None. |
| 4 | Claim-level (header case) payments and the exposure | MAP row 136 (lines 380-402) has no rule for the header case. LKP line 10 (general note 1): on an "AD or HDR" case the transaction goes "on the exposure created from the case". A header case has no exposure. | TR line 50 (search "it won't relate to an exposure"): header-case transactions go to the claim level, no exposure. | Claim-level, no exposure. | Confirm. Is ExposureID empty for claim-level transactions? |
| 5 | Hire & Mobility is missing from the exposure row | MAP row 136 lists only Vehicle / Injury / Property. Hire is in LKP rows 6, 8, 10, 34, 50, 88, 104, 106, 118, 126, 132, 140 (lines 26-160). | TR line 25-33: hire codes on a TP case go to the Hire & Mobility exposure. | Follow the transcript and the lookup. | None: just note that row 136 is incomplete. |
| 6 | PA recoveries | MAP row 136 (lines 387-389): recoveries on PA_ANCILLARY cases are not migrated. | TR line 47 (search "regardless of what case"): recoveries are done the same way on every case. No PA exception is mentioned. | Not loaded. Reported as PA_CREDIT_NOT_MIGRATED. | Confirm the final handling and the count. |
| 7 | DoesNotErodeReserves | MAP grid row 137 (line 64): default FALSE. | MAP detail line 453: "Default to TRUE (1)". TR line 80 (search "does not erode"): "default it to one". | 1. | Confirm. |
| 8 | Transfer fields | MAP row 134 (grid line 61, detail 445) and 135 (grid 62, detail 449-451): entity "Payment". Row 135 has only WHERE PAY_TYPE = T, with no debit/credit, and the default is shown as "Subrogation". | TR line 82 (search "internal CC pay reco"): the claim number is on the debit (source). The category is on the credit (target). The currency is unclear: "One is on your transaction on the source claim... the other two... No, this one on the credit side". | Debit: claim number and currency. Credit: category 'subro'. | Which side gets InternalCCPayRecoCurrency: debit, credit, or both? |
| 9 | ApprovalDate: wrong label in the mapping | MAP detail line 321-331 is printed under "208. ApprovalStatus", but the text is the ApprovalDate rule. The grid shows 208 = ApprovalStatus ("Based on cc_transaction.Status", line 93) and 209 = ApprovalDate (line 94). | TR line 83 (search "approval date" near the end): the same rule, as the final version. | Using the rule as ApprovalDate. | None: the label is misplaced. |
| 10 | ApprovalDate: three versions of the rule | SQL1 lines 45-47: AUTH only, no MAX. MAP lines 321-331: debit = latest AUTH/GRP_AUTH, else first record; credit = first record. | TR line 80 (search "status type is equal to AUTH"): AUTH only, "assume only one record". TR line 83 (search "extended the transformation logic"): the MAP version. | The MAP / TR-line-83 version. | None: later version wins. SQL1 is old. |
| 11 | Payee link table name | MAP rows 20 and 88 (lines 172-175, 272-274): "VEC_GW_CG_LINK". | SQL2 lines 181, 186, 262: VEC_GW_CF_LINK. TR line 82: "CF link table". | CF_LINK. The data-model picture also shows VEC_GW_CF_LINK, so CG is confirmed a typo. | None. |
| 12 | Date only, or date and time | MAP row 18 (lines 23, 163-166), row 33 (31, 198-203), row 41 (35, 220-223): source is RECORD_DATE only. The examples show a time. | TR line 81 (search "record date, record time"): PRESENTED, PAID entered time and issue date use record date AND record time. | Date + time. | Confirm. |
| 13 | CANX: any record, or the current status | MAP row 19 (line 168): STATUS_TYPE = CANX (any record). MAP row 53 (lines 248-250): "if the current transaction status is CANX". | TR line 81 (search "cancel status"): both described loosely. | Stop reason from any CANX record. | Void user only if current = CANX, stop reason from any CANX: confirm. |
| 14 | Cash movement and cheque number on the transaction | MAP rows 138 and 148 (lines 65, 72, 436-438): Recovery only. | TR line 63 (search "cache denorm field"): described for the CC transaction in general. | Recoveries only. Payments carry them on the check. | Confirm. |
| 15 | Check number when V2 has an empty string | MAP row 10 (lines 126-127): "If NULL in V2, leave NULL". | TR line 81 (search "empty string"): the data has empty strings, not NULLs. "It is okay." | Empty string kept as is. | Keep '' or convert to NULL? |
| 16 | MailTo / PayTo | MAP row 43 (lines 230-234): address of "cc_checkpayee.ClaimDenormID". That column does not exist in the mapping. MAP row 46 (238-240): first name + last name. | Never explained. TR line 81 only says "we will get back to those". MailingAddressID is the in-care-of contact's address (TR line 82, search "mailing address"). | NULL (pending). | What goes in MailTo and PayTo? What about company contacts (no first/last name)? |
| 17 | Role on the payee: which exposure | PAYEE row 132 (line 30): the role links to "the Exposure on which the transaction will be raised". | TR line 82 (search "check payroll"): the payee just gets a second role. No exposure mentioned. A claim-level payment has no exposure. | Pending. | Role per contact, or per contact + exposure? |
| 18 | Which lookup tab | MAP rows 140-141 (lines 67-68, 411-417): "NEW_MOTOR_Payment-Recovery". A duplicate row 140 (lines 408-409) names the old tab. LKP line 3: the file we have is `MOTOR_Payment-Recovery`. | TR line 71 (search "added a column here"): a "main reserve line" column was added. LKP line 6: columns A-I only, no such column. | Cannot use it. | Send the NEW_ tab with the main-reserve-line column. |
| 19 | Credit cost category | LKP lines 174-194 (sheet rows 154-174): credit rows say cost category "claimcost_adm". LKP line 44 (row 24): "Main recovery reserve line on the exposure". | TR line 47 and line 50: all credits go to the exposure's recovery line. The cost category depends on the exposure. | Cost category taken from the recovery reserve line. | Confirm. |
| 20 | SUC likely means SUB | LKP lines 146-147: SUB is TP-only (Hire), SUC is non-TP-only. Every other hire code comes as a pair (TP / non-TP). | Not mentioned. | SUC non-TP: normal. SUB non-TP: unmapped. | Is row 127 meant to be SUB? |
| 21 | Hire codes missing on non-TP | LKP: CDW, FSC, RVM, TEM have no non-TP row. | TR line 27: "on every other case ... mapped as a normal payment". | Unmapped, in the exception report. | What cost type? |

## B. Contradictions inside the transcript itself

| # | Where | What |
|---|---|---|
| T1 | TR line 14 (search "those reserves") | The claim-level RECOVERY transaction goes to "those" two claim-level reserve lines (cost, expense). But TR line 71 and MAP row 128 (lines 362-367) say recoveries go to a recovery reserve line. |
| T2 | TR line 35 vs TR line 50 | Line 35: "it will always have dissection information". Line 50 (search "missing the dissection code"): some debits have NULL. |
| T3 | TR line 83 (search "claim contact record, so #2") vs the same line earlier (search "pointing to your contact table") | In-care-of contact: "claim contact" in one place, "contact table" in another. MAP row 34 (lines 32, 205-207) says Contact. |
| T4 | TR line 14 vs TR line 50 | Recovery coding count (see A1). |

## C. OCR / typing errors I found

- TR line 50: "Each record ... won't translate" should be "will".
- TR line 82: "debit credit is equal to T" should be "D".
- TR line 14: "migrated cost" should be "migrated payment".
- TR lines 82-83: "check payroll" means the check payee role.
- TR line 83 (search "banked one"): garbled, no meaning.
- TR line 83: "minimum link ID" means minimum ID.
- TR line 81: "record type" should be "record time".
- MAP lines 172-175 and 272-274: "VEC_GW_CG_LINK" should be CF_LINK.
- LKP line 147: "SUC" is probably "SUB".
- MAP lines 408-413: row 140 is printed twice with two different tab names.
- MAP row 88 (line 270): "cc_check.PayeeDenormID", but PayeeDenormID is on cc_checkpayee.

## D. Other things to know

- SQL2 lines 59-62: transaction 53656976 is a HOUSEHOLD example. TR line 50 (search "household claim, you'll have to believe me") confirms it. It is not a Motor example.
- SQL1 lines 7 and 85: claims with INCIDENT_CODE = 'WINDSCREEN' are excluded. Neither the mapping nor the transcript says this. TR line 56 says eligibility is handled elsewhere.
- SQL2 lines 275-291: the dummy-payee query has no DEBIT_CREDIT filter, so it also picks up credits. TR line 82 (search "check pay is only relevant for our payment") says only payments need a payee.
- SQL2 lines 5 and 331: leftover debug filter (a hard-coded claim). Not a rule.
- TR lines 58 and 81: the transaction offset table was asked about twice. The BA said it is not mapped and she will check if it was de-scoped.
- TR lines 80 and 81: CreateTime and BookingDate may move to a "legacy create time". Stay with the mapping for now.
