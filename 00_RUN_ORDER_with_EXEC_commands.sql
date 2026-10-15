/* =====================================================================================================
   RUN ORDER WITH EXEC COMMANDS  (Oct 15, 2026, version 5)  Motor payments + recoveries
   Database: IntermediateStaging_DEV.  Not executed on SQL Server.

   NAMING RULE: usp_Load_IS_<table>        = loads an intermediate table
                usp_Load_SS_to_IS_<table>  = loads a MAIN IS table (IS_TRANSACTION, IS_CHECK, IS_CONTACT ...)
   WHAT CHANGES IN YOUR EXISTING ORDER (everything else stays as it is today):
     1. The five MAIN procs (usp_Load_SS_to_IS_TRANSACTION, _TRANSACTIONSET, _TRANSACTIONLINEITEM, _CHECK, _CHECKPAYEE) now get one
        extra INSERT at the end (file 15) that reads my intermediate payment tables. So they must run AFTER Part C and Part D below.
     2. usp_Load_IS_CLAIMCONTACTROLE moves to the end (Part F): its step 5B reads IS_PAYMENT_MASTER_MOTOR.
   ===================================================================================================== */

/* STEP 0 (ONCE): run 00_DDL_payment_tables_motor.sql (only CREATE TABLE statements; it does NOT create the main tables) */

/* =================== PART A: contacts and addresses, as SSIS runs them today (unchanged) =================== */
EXEC dbo.[<your IS_CLAIM_MASTER proc>];
EXEC dbo.usp_Load_IS_CONTACT_MASTER_MOTOR;
EXEC dbo.usp_Load_IS_ADDRESS_CONTACT;
EXEC dbo.usp_Load_IS_ADDRESS_POLICY;
EXEC dbo.usp_Load_IS_ADDRESS_RISKUNIT;
EXEC dbo.usp_Load_IS_ADDRESS_LOSSLOCATION;
EXEC dbo.usp_Load_SS_to_IS_ADDRESS;
EXEC dbo.usp_Load_SS_to_IS_CONTACT;
EXEC dbo.usp_Load_IS_CONTACTADDRESS;
EXEC dbo.usp_Load_IS_CLAIMCONTACT;

/* =================== PART B: exposure and reserves: intermediate tables (unchanged) =================== */
EXEC dbo.usp_Load_IS_EXPOSURE_MOTOR;
EXEC dbo.usp_Load_SS_to_IS_RESERVELINE_MOTOR;
EXEC dbo.usp_Load_SS_to_IS_TRANSACTION_MOTOR;
EXEC dbo.usp_Load_SS_to_IS_TRANSACTIONLINEITEM_MOTOR;
EXEC dbo.usp_Load_SS_to_IS_TRANSACTIONSET_MOTOR;
EXEC dbo.usp_Load_SS_to_IS_RECOVERYCODING_MOTOR;
/* If SSIS today runs your main procs usp_Load_SS_to_IS_TRANSACTION / _TRANSACTIONSET / _TRANSACTIONLINEITEM / _CHECK / _CHECKPAYEE
   (and usp_Load_IS_CLAIMCONTACTROLE) at this place: MOVE them to Part E / Part F. */

/* =================== PART C: payments, intermediate tables (my procs) =================== */
/* 01 PROD: file 01_usp_Load_IS_PAYMENT_MASTER_MOTOR.sql (git, no exception logic).
   Your DEV copy is named usp_Load_IS_PAYMENT_MASTER_MOTOR_2: use that name in your EXEC if you keep it.
   01 TEST (dev only): file 01_TEST_..._TEST.sql, proc usp_Load_IS_PAYMENT_MASTER_MOTOR_TEST. Run it INSTEAD of PROD, never both. */
EXEC dbo.usp_Load_IS_PAYMENT_MASTER_MOTOR;                 /* 01 PROD; or EXEC dbo.usp_Load_IS_PAYMENT_MASTER_MOTOR_TEST for dev */
EXEC dbo.usp_Load_IS_DUMMY_PAYEE_MOTOR;                    /* 01b: fills IS_DUMMY_PAYEE_ADDRESS_MOTOR, IS_DUMMY_PAYEE_CONTACT_MOTOR, IS_DUMMY_PAYEE_CLAIMCONTACT_MOTOR */
EXEC dbo.usp_Load_IS_TRANSACTION_PAY_MOTOR;                /* 02  */
EXEC dbo.usp_Load_IS_TRANSACTIONLINEITEM_PAY_MOTOR;        /* 03  */
EXEC dbo.usp_Load_IS_TRANSACTIONSET_PAY_MOTOR;             /* 04  */
EXEC dbo.usp_Load_IS_CHECK_MOTOR;                          /* 05  */
EXEC dbo.usp_Load_IS_CHECKPAYEE_MOTOR;                     /* 06  */
/* 07 TEST only (needs the TEST master proc; not for git): */
/* EXEC dbo.usp_Load_IS_PAYMENT_EXCEPTION_MOTOR; */      /* 07: report only */

/* =================== PART D: dummy payees into the main contact tables (append only, no truncate) =================== */
EXEC dbo.usp_Load_SS_to_IS_ADDRESS_DUMMY_PAYEE_MOTOR;      /* 01c: IS_ADDRESS      += dummy payee addresses */
EXEC dbo.usp_Load_SS_to_IS_CONTACT_DUMMY_PAYEE_MOTOR;      /* 01d: IS_CONTACT      += dummy payee contacts */
EXEC dbo.usp_Load_SS_to_IS_CLAIMCONTACT_DUMMY_PAYEE_MOTOR; /* 01e: IS_CLAIMCONTACT += dummy payee claim contacts (after 01d) */

/* =================== PART E: MAIN IS tables (YOUR procs, each with my insert block from file 15 at its end) =================== */
EXEC dbo.usp_Load_SS_to_IS_TRANSACTION;                    /* reserves + (block 1) Motor payments and recoveries */
EXEC dbo.usp_Load_SS_to_IS_TRANSACTIONSET;                 /* (block 2) */
EXEC dbo.usp_Load_SS_to_IS_TRANSACTIONLINEITEM;            /* (block 3) */
EXEC dbo.usp_Load_SS_to_IS_CHECK;                          /* (block 4) */
EXEC dbo.usp_Load_SS_to_IS_CHECKPAYEE;                     /* (block 5) */

/* =================== PART F: roles =================== */
EXEC dbo.usp_Load_IS_CLAIMCONTACTROLE;                     /* v7: mandatory roles + lookup roles + step 5B checkpayee roles */

/* =================== PART G: checks (queries, not procs) ===================
   08_validation_queries_payments_motor.sql  (also copied into 24_FINAL_TODO_open_questions_and_checks.md)
   14_typelist_queries_payments_motor.sql    (T0c, T0d)                                              */
