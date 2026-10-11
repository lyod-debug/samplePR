# Pay contact: real source tables, columns, joins, exclusions, and the logic used

Everything below was read from the .sql files you sent (the senior's contact master, claim contact, claim contact role and four address procs), the payment mapping, the Payee_Contact mapping and the BA transcript / SQL. I did not use the IS_ layer where a real source table exists.

## 1. What the senior's procs actually read (the real source tables)

| Senior's proc | Real source tables (SourceStaging.VECCASRN unless stated) | Key joins | Exclusions / filters that matter for payments |
|---|---|---|---|
| `usp_Load_IS_CONTACT_MASTER_MOTOR` (output `CONTACT_MASTER_MOTOR`) | `VEC_GW_CF_HDR` (CONTACT RECORD, `ID`=`HDR_ID`, `GWCONTH_TYPEID`), `VEC_GW_CF_HDR_TYPE` (`PRODUCT`, `HDR_TYPE`, `COMPANY`), `VEC_GW_CF_LINK` (`GWCF_HDRID`, `GWCFLNK_TYPEID`, `GW_LOCATIONID`, `GWCF_PERSID`), `VEC_GW_CFLINK_TYPE` (`MAIN_LINK`, `GWCFHDR_TYPEID`), `VEC_GW_LOCATION`, `VEC_GW_LOC_TYPE`, person/company name tables; `GWCC_CONTACT_SUBTYPE_MOTOR`; `IS_CLAIM_MASTER` | CONTACT RECORD -> its links; claim through `GW_HDR_CASEID` | only `HDR_TYPE.PRODUCT = 'MOTOR'` (line 62); keeps MAX(`LINK_ID`) per `HDR_ID`; last line `WHERE EL.Subtype IS NOT NULL` (line 725) drops records whose kept link has no subtype row |
| `usp_Load_IS_CLAIMCONTACT` (output `IS_CLAIMCONTACT`) | `CONTACT_MASTER_MOTOR`, `IS_CLAIM_MASTER` (join on `CLAIM_REF`) | PublicID = claim PublicID + `_` + `HDR_ID`; `ContactID` = contact PublicID; `ClaimID` = claim PublicID | company subtypes fill `ContactNameDenorm`; Person, Doctor, Contact fill `PersonFirstNameDenorm` / `PersonLastNameDenorm`; no filter by role |
| `usp_Load_IS_ADDRESS_CONTACT` (output `IS_ADDRESS_CONTACT`) | `CONTACT_MASTER_MOTOR`, `VEC_GW_CF_LINK`, `VEC_GW_CFLINK_TYPE`, `VEC_GW_LOCATION` (`ADDR1`..`ADDR9`, `PCODE`), `VEC_GW_LOC_TYPE`, `TYPELIST_TABLE_MAPPING` (AddressType), policy tables for `PolicySystemId_Adm` | link -> `GW_LOCATIONID` (INNER JOIN, so links without location give no address) | claim `1112416534` excluded; address line columns are cut at 60 characters; primary address id = the contact's `PrimaryAddressID` for rank 1, else `mig:motorcon<LINK_ID>` |
| `usp_Load_IS_CONTACTADDRESS` (bridge) | `IS_ADDRESS_CONTACT`, `CONTACT_MASTER_MOTOR` | non-primary addresses only | not needed for payments (the check uses the primary address only) |
| `usp_Load_IS_ADDRESS_POLICY / LOSSLOCATION / RISKUNIT` | policy location tables, loss location, risk unit tables | n/a | not needed for payments |
| `usp_Load_IS_CLAIMCONTACTROLE_..._v6` | `CONTACT_MASTER_MOTOR`, every link's (CONTACT HEADER TYPE, LINK TYPE) through `CLAIM_CONTACT_ROLE_LOOKUP` | starts from the contact master | role PublicID `mig:motorccr<HDR_ID>_<Role>`; dummy payees are invisible to it |

## 2. Logic used for each pay contact field

| Target | Source | Logic (proc, section) |
|---|---|---|
| Payee CONTACT RECORD | `VEC_GW_PAY_TRANS.PAYEE_LINKID` | `-> VEC_GW_CF_LINK.ID -> GWCF_HDRID` (01 S10 `#PAYHDR`) |
| Payee contact PublicID | `CONTACT_MASTER_MOTOR` | `HDR_ID = GWCF_HDRID` and same `GW_HDR_CASEID` (01 S10 `#PAYCON`). PublicID is `mig:motor<HDR_ID>` |
| `cc_check.ClaimContactID`, `cc_checkpayee.ClaimContactID` | `IS_CLAIMCONTACT` | `ContactID` = payee contact PublicID and `ClaimID` = claim PublicID (01 S10 `#PAYCC`); copied by 05 and 06 |
| Dummy payee | `PAYEE_NAME`, `ADDRESS_LINE1-3`, `POST_CODE` of the same V2 row | only when `PAYEE_LINKID` is NULL / 0 / not in `VEC_GW_CF_LINK` and the row is a DEBIT; built by 01b, always Subtype `Company` |
| `cc_check.InCareOf_Adm` | `ADD_LINKID` | same route as the payee (01 S10); NULL if none |
| `cc_check.MailingAddressID` | `CONTACT_MASTER_MOTOR.PrimaryAddressID` of the in-care-of contact | only if the address exists in `IS_ADDRESS_CONTACT.CONTACT_ADDRESS_PUBLICID` (05) |
| `cc_check.MailTo` | `IS_ADDRESS_CONTACT` of the payee's `PrimaryAddressID` (real) or `IS_PAYEE_ADDRESS_PAY_MOTOR` (dummy) | only when `InCareOf_Adm` is NOT NULL; address lines, city, county, postcode joined by `, `, max 255 (05) |
| `cc_check.PayTo` | `IS_CLAIMCONTACT.PersonFirstNameDenorm`, `PersonLastNameDenorm` | first + space + last; company payees give NULL (BA-27) (05) |
| `PayeeDenormID`, `PayToDenorm` | – | not loaded (ClaimCenter fills denorm fields) |
| Role `checkpayee` | – | NOT in the payment procs; claim contact role proc, see section 3 |

## 3. Feed query for the claim contact role proc (checkpayee role)
The role is needed for every claim contact that is a check payee. Mapping: role `checkpayee`, `ExposureID` = the exposure of the transaction, `Active`, `PartyNumber` as in the role proc. Run after proc 06:

```sql
SELECT DISTINCT
       M.GW_HDR_CASEID, M.CLAIM_REF, M.ClaimPublicID
     , M.PayeeClaimContactID AS ClaimContactID
     , M.PayeeContactID      AS ContactID
     , M.PayeeHdrID          AS HDR_ID            -- NULL for a dummy payee
     , M.ExposureID
     , M.IsDummyPayee
FROM IntermediateStaging_DEV.dbo.IS_PAYMENT_MASTER_MOTOR M
INNER JOIN IntermediateStaging_DEV.dbo.IS_CHECKPAYEE_MOTOR P
        ON P.CheckID = 'mig:motorchk_' + CONVERT(VARCHAR(20), M.TranID) + M.MasterSuffix
WHERE M.DebitCredit = 'D';
```
Two open points (BA): one role per (claim contact, exposure) or per payment? The existing role PublicID pattern `mig:motorccr<HDR_ID>_<Role>` has no exposure, so two payments of the same payee on different exposures cannot both be represented without a new pattern. For dummy payees the role PublicID needs the dummy ids, e.g. `mig:motorccr_payee<TranID>_checkpayee`.

## 4. Typelist values written by the pay contact work
`Subtype = Company`, `AutoSync = Disallow`, `PreferredCurrency = gbp`, `PreferRemitChannel_Adm = email`, address `State = GB_E_Adm`, address `Subtype = Address`, `PayeeType = checkpayee`. Check each exists in `TYPELIST_TABLE_MAPPING` (01 S9 checks the check/currency ones; 01b checks `GB_E_Adm`).
Fields kept at the database default (not written): `GroupPayment_Adm`, `Injured_Adm`, `LoadRelatedContacts`, `PendingLinkMessage`, `Preferred`, `Unknown_Adm`, `UnknownFlagVisible`, `BatchGeocode`.
