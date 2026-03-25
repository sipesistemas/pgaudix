-- pgaudix regression tests

-- Setup
CREATE EXTENSION pgaudix;

-- ============================================================
-- Test 1: Enable auditing
-- ============================================================
CREATE TABLE public.test_orders (
    id      serial PRIMARY KEY,
    amount  numeric(10,2),
    status  text
);

SELECT pgaudix.enable('public.test_orders');

-- Verify audit table exists
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_audit'
ORDER BY ordinal_position;

-- Verify registration
SELECT source_schema, source_table, audit_table, enabled
FROM pgaudix.status();

-- ============================================================
-- Test 2: INSERT audit
-- ============================================================
INSERT INTO public.test_orders (amount, status) VALUES (100.50, 'pending');

SELECT audit_operation, audit_user, id, amount, status
FROM public.test_orders_audit
ORDER BY audit_id;

-- ============================================================
-- Test 3: UPDATE audit (single row with new values)
-- ============================================================
UPDATE public.test_orders SET status = 'shipped', amount = 105.00 WHERE id = 1;

SELECT audit_operation, id, amount, status
FROM public.test_orders_audit
ORDER BY audit_id;

-- ============================================================
-- Test 4: DELETE audit
-- ============================================================
DELETE FROM public.test_orders WHERE id = 1;

SELECT audit_operation, id, amount, status
FROM public.test_orders_audit
ORDER BY audit_id;

-- ============================================================
-- Test 5: DDL sync - ADD COLUMN
-- ============================================================
ALTER TABLE public.test_orders ADD COLUMN notes text;

-- Verify the audit table also has the new column
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_audit'
  AND column_name = 'notes';

-- Test that new column is audited
INSERT INTO public.test_orders (amount, status, notes) VALUES (200.00, 'new', 'test note');

SELECT audit_operation, amount, status, notes
FROM public.test_orders_audit
WHERE audit_id = (SELECT max(audit_id) FROM public.test_orders_audit);

-- ============================================================
-- Test 6: DDL sync - RENAME COLUMN
-- ============================================================
ALTER TABLE public.test_orders RENAME COLUMN notes TO description;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_audit'
  AND column_name = 'description';

-- ============================================================
-- Test 7: DDL sync - ALTER COLUMN TYPE
-- ============================================================
ALTER TABLE public.test_orders ALTER COLUMN amount TYPE numeric(12,4);

SELECT column_name, numeric_precision, numeric_scale
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_audit'
  AND column_name = 'amount';

-- ============================================================
-- Test 8: DDL sync - DROP COLUMN
-- ============================================================
ALTER TABLE public.test_orders DROP COLUMN description;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_audit'
  AND column_name = 'description';

-- ============================================================
-- Test 9: Disable auditing (keep data)
-- ============================================================
SELECT pgaudix.disable('public.test_orders');

-- DML trigger should be gone
SELECT count(*) FROM pg_trigger
WHERE tgname = 'pgaudix_audit_trigger'
  AND tgrelid = 'public.test_orders'::regclass;

-- TRUNCATE trigger should be gone
SELECT count(*) FROM pg_trigger
WHERE tgname = 'pgaudix_truncate_trigger'
  AND tgrelid = 'public.test_orders'::regclass;

-- Audit table should still exist
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'test_orders_audit';

-- ============================================================
-- Test 10: Disable with drop_data
-- ============================================================
DROP TABLE IF EXISTS public.test_orders_audit;
SELECT pgaudix.enable('public.test_orders');
SELECT pgaudix.disable('public.test_orders', drop_data := true);

-- Audit table should be gone
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'test_orders_audit';

-- ============================================================
-- Test 11: SECURITY DEFINER search_path (H1)
-- ============================================================
SELECT proname, proconfig
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'pgaudix'
  AND p.proname IN ('enable', 'disable', 'ddl_sync', 'truncate_trigger', 'audit_trigger')
  AND proconfig::text LIKE '%search_path%'
ORDER BY proname;

-- ============================================================
-- Test 12: Duplicate enable() is rejected (H3)
-- ============================================================
SELECT pgaudix.enable('public.test_orders');

-- Try enabling again — should fail
DO $$
BEGIN
    PERFORM pgaudix.enable('public.test_orders');
    RAISE NOTICE 'ERROR: duplicate enable should have failed';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: duplicate enable rejected: %', SQLERRM;
END;
$$;

-- ============================================================
-- Test 13: TRUNCATE audit (M1)
-- ============================================================
INSERT INTO public.test_orders (amount, status) VALUES (300.00, 'active');
INSERT INTO public.test_orders (amount, status) VALUES (400.00, 'active');
TRUNCATE public.test_orders;

-- Should have I, I, and T rows
SELECT audit_operation, id, amount, status
FROM public.test_orders_audit
ORDER BY audit_id;

-- ============================================================
-- Test 14: Audit table permissions (M2)
-- ============================================================
-- Create a test role
CREATE ROLE pgaudix_test_user LOGIN;
GRANT USAGE ON SCHEMA public TO pgaudix_test_user;
GRANT ALL ON public.test_orders TO pgaudix_test_user;
GRANT USAGE ON SEQUENCE public.test_orders_id_seq TO pgaudix_test_user;
GRANT SELECT ON public.test_orders_audit TO pgaudix_test_user;

-- Test that direct INSERT to audit table is denied
SET ROLE pgaudix_test_user;
DO $$
BEGIN
    EXECUTE 'INSERT INTO public.test_orders_audit (audit_operation) VALUES (''X'')';
    RAISE NOTICE 'ERROR: direct audit INSERT should have been denied';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: direct audit INSERT denied';
END;
$$;

-- Test that DML on source table still works (trigger has SECURITY DEFINER)
INSERT INTO public.test_orders (amount, status) VALUES (500.00, 'test');

RESET ROLE;

-- Verify the audit row was created by the trigger (audit_user = session_user)
SELECT audit_operation, audit_user = session_user AS correct_user, amount, status
FROM public.test_orders_audit
WHERE audit_id = (SELECT max(audit_id) FROM public.test_orders_audit);

-- Cleanup test role
REVOKE ALL ON public.test_orders FROM pgaudix_test_user;
REVOKE ALL ON SEQUENCE public.test_orders_id_seq FROM pgaudix_test_user;
REVOKE ALL ON public.test_orders_audit FROM pgaudix_test_user;
REVOKE USAGE ON SCHEMA public FROM pgaudix_test_user;
DROP ROLE pgaudix_test_user;

-- ============================================================
-- Test 15: RENAME TABLE renames audit table too (H2)
-- ============================================================
-- Clear audit data for clean test
TRUNCATE public.test_orders_audit;

ALTER TABLE public.test_orders RENAME TO test_orders_renamed;

-- Verify both source and audit table names were updated
SELECT source_table, audit_table
FROM pgaudix.status();

-- Old audit table should no longer exist
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'test_orders_audit';

-- New audit table should exist
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'test_orders_renamed_audit';

-- DML on renamed table should go to the new audit table
INSERT INTO public.test_orders_renamed (amount, status) VALUES (600.00, 'renamed');

SELECT audit_operation, amount, status
FROM public.test_orders_renamed_audit
WHERE audit_id = (SELECT max(audit_id) FROM public.test_orders_renamed_audit);

-- DDL sync should still work on the renamed audit table
ALTER TABLE public.test_orders_renamed ADD COLUMN extra text;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_renamed_audit'
  AND column_name = 'extra';

-- TRUNCATE trigger should also work after rename
TRUNCATE public.test_orders_renamed;

SELECT audit_operation
FROM public.test_orders_renamed_audit
WHERE audit_id = (SELECT max(audit_id) FROM public.test_orders_renamed_audit);

-- Rename back for cleanup
ALTER TABLE public.test_orders_renamed RENAME TO test_orders;
ALTER TABLE public.test_orders DROP COLUMN extra;

-- ============================================================
-- Test 16: SPI error handling - audit failure aborts DML (C1)
-- ============================================================
-- Force an audit column mismatch by dropping a column from audit table directly
-- (Disable DDL sync guard temporarily)
SELECT pgaudix.disable('public.test_orders', drop_data := true);
SELECT pgaudix.enable('public.test_orders');
TRUNCATE public.test_orders_audit;

-- Drop a column from audit table to cause a mismatch
-- The ddl_sync will fire and warn, but the DROP proceeds
ALTER TABLE public.test_orders_audit DROP COLUMN status;

-- Now INSERT should fail because the trigger tries to write to a missing column
DO $$
BEGIN
    INSERT INTO public.test_orders (amount, status) VALUES (999.99, 'should_fail');
    RAISE NOTICE 'ERROR: INSERT should have failed due to audit column mismatch';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: INSERT aborted due to audit failure: %', SQLERRM;
END;
$$;

-- Verify no row was inserted into the source table
SELECT count(*) FROM public.test_orders WHERE amount = 999.99;

-- ============================================================
-- Test 17: NULL values in INSERT and UPDATE
-- ============================================================
SELECT pgaudix.disable('public.test_orders', drop_data := true);
SELECT pgaudix.enable('public.test_orders');

INSERT INTO public.test_orders (amount, status) VALUES (NULL, NULL);

SELECT audit_operation, id, amount, status
FROM public.test_orders_audit
ORDER BY audit_id;

UPDATE public.test_orders SET amount = 50.00 WHERE amount IS NULL;

SELECT audit_operation, id, amount, status
FROM public.test_orders_audit
ORDER BY audit_id;

-- ============================================================
-- Test 18: Multi-row UPDATE and DELETE
-- ============================================================
TRUNCATE public.test_orders_audit;
DELETE FROM public.test_orders;
INSERT INTO public.test_orders (amount, status) VALUES (10.00, 'a');
INSERT INTO public.test_orders (amount, status) VALUES (20.00, 'a');
INSERT INTO public.test_orders (amount, status) VALUES (30.00, 'a');
TRUNCATE public.test_orders_audit;

-- UPDATE all 3 rows — should produce 3 audit rows
UPDATE public.test_orders SET status = 'b';

SELECT count(*) AS update_audit_rows
FROM public.test_orders_audit
WHERE audit_operation = 'U';

-- DELETE all 3 rows — should produce 3 audit rows
DELETE FROM public.test_orders;

SELECT count(*) AS delete_audit_rows
FROM public.test_orders_audit
WHERE audit_operation = 'D';

-- ============================================================
-- Test 19: Non-public schema
-- ============================================================
CREATE SCHEMA test_schema;
CREATE TABLE test_schema.items (
    id serial PRIMARY KEY,
    name text
);

SELECT pgaudix.enable('test_schema.items');

INSERT INTO test_schema.items (name) VALUES ('widget');

SELECT audit_operation, audit_user, id, name
FROM test_schema.items_audit
ORDER BY audit_id;

-- DDL sync in non-public schema
ALTER TABLE test_schema.items ADD COLUMN price numeric;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'test_schema' AND table_name = 'items_audit'
  AND column_name = 'price';

SELECT pgaudix.disable('test_schema.items', drop_data := true);
DROP TABLE test_schema.items;
DROP SCHEMA test_schema;

-- ============================================================
-- Test 20: Transaction rollback — no audit rows
-- ============================================================
TRUNCATE public.test_orders_audit;

BEGIN;
    INSERT INTO public.test_orders (amount, status) VALUES (777.00, 'will_rollback');
ROLLBACK;

-- No audit row should exist for the rolled-back INSERT
SELECT count(*) FROM public.test_orders_audit;

-- ============================================================
-- Test 21: Same audit_txid within a transaction
-- ============================================================
BEGIN;
    INSERT INTO public.test_orders (amount, status) VALUES (1.00, 'tx1');
    INSERT INTO public.test_orders (amount, status) VALUES (2.00, 'tx2');
    UPDATE public.test_orders SET status = 'tx_updated' WHERE amount = 1.00;
COMMIT;

-- All 3 audit rows in the same transaction should share the same txid
SELECT count(DISTINCT audit_txid) AS distinct_txids
FROM public.test_orders_audit;

-- ============================================================
-- Test 22: Disable then re-enable
-- ============================================================
-- Disable but keep audit data
SELECT pgaudix.disable('public.test_orders');

-- Audit table should still have data
SELECT count(*) > 0 AS has_data FROM public.test_orders_audit;

-- DML after disable should NOT produce audit rows
INSERT INTO public.test_orders (amount, status) VALUES (999.00, 'no_audit');
SELECT count(*) AS rows_after_disable
FROM public.test_orders_audit
WHERE status = 'no_audit';

-- Drop stale audit table and re-enable
DROP TABLE public.test_orders_audit;
SELECT pgaudix.enable('public.test_orders');

-- DML after re-enable should work
INSERT INTO public.test_orders (amount, status) VALUES (888.00, 're_enabled');

SELECT audit_operation, amount, status
FROM public.test_orders_audit
WHERE audit_id = (SELECT max(audit_id) FROM public.test_orders_audit);

-- ============================================================
-- Test 23: Multiple DDL changes in one ALTER
-- ============================================================
ALTER TABLE public.test_orders ADD COLUMN col_a text, ADD COLUMN col_b int;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_audit'
  AND column_name IN ('col_a', 'col_b')
ORDER BY column_name;

ALTER TABLE public.test_orders DROP COLUMN col_a, DROP COLUMN col_b;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_audit'
  AND column_name IN ('col_a', 'col_b')
ORDER BY column_name;

-- ============================================================
-- Test 24: Source column with audit_ prefix
-- ============================================================
ALTER TABLE public.test_orders ADD COLUMN audit_notes text;

-- Verify both the metadata audit_ columns and the mirrored audit_notes exist
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_orders_audit'
  AND column_name LIKE 'audit_%'
ORDER BY ordinal_position;

INSERT INTO public.test_orders (amount, status, audit_notes)
VALUES (42.00, 'noted', 'user note');

SELECT audit_operation, amount, status, audit_notes
FROM public.test_orders_audit
WHERE audit_id = (SELECT max(audit_id) FROM public.test_orders_audit);

ALTER TABLE public.test_orders DROP COLUMN audit_notes;

-- ============================================================
-- Test 25: Enable on non-existent table
-- ============================================================
DO $$
BEGIN
    PERFORM pgaudix.enable('public.no_such_table');
    RAISE NOTICE 'ERROR: should have failed for non-existent table';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: enable on non-existent table failed: %', SQLERRM;
END;
$$;

-- ============================================================
-- Test 26: Disable on non-monitored table
-- ============================================================
CREATE TABLE public.unmonitored (id int);

DO $$
BEGIN
    PERFORM pgaudix.disable('public.unmonitored');
    RAISE NOTICE 'ERROR: should have failed for non-monitored table';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: disable on non-monitored table failed: %', SQLERRM;
END;
$$;

DROP TABLE public.unmonitored;

-- ============================================================
-- Test 27: Attnum gap alignment (enable on table with dropped columns)
-- ============================================================
-- Cleanup from previous tests
SELECT pgaudix.disable('public.test_orders', drop_data := true);
DROP TABLE public.test_orders;

-- Create table with attnum gaps: add columns then drop them
CREATE TABLE public.test_gaps (
    id      serial PRIMARY KEY,   -- attnum 1
    col_a   text,                 -- attnum 2
    col_b   text,                 -- attnum 3
    col_c   text                  -- attnum 4
);
ALTER TABLE public.test_gaps DROP COLUMN col_b;  -- gap at attnum 3

-- Enable auditing on table with gap
SELECT pgaudix.enable('public.test_gaps');

-- Verify audit table has only non-dropped columns (not col_b)
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_gaps_audit'
  AND column_name NOT LIKE 'audit_%'
ORDER BY ordinal_position;

-- DML should work with gaps
INSERT INTO public.test_gaps (col_a, col_c) VALUES ('a1', 'c1');
UPDATE public.test_gaps SET col_a = 'a2' WHERE col_a = 'a1';
DELETE FROM public.test_gaps WHERE col_a = 'a2';

SELECT audit_operation, id, col_a, col_c
FROM public.test_gaps_audit
ORDER BY audit_id;

-- DDL sync should work with gaps: ADD COLUMN
ALTER TABLE public.test_gaps ADD COLUMN col_d text;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_gaps_audit'
  AND column_name = 'col_d';

-- DDL sync: RENAME COLUMN
ALTER TABLE public.test_gaps RENAME COLUMN col_d TO col_d_renamed;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_gaps_audit'
  AND column_name = 'col_d_renamed';

-- DDL sync: ALTER COLUMN TYPE
ALTER TABLE public.test_gaps ALTER COLUMN col_c TYPE varchar(100);

SELECT column_name, data_type, character_maximum_length
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_gaps_audit'
  AND column_name = 'col_c';

-- DDL sync: DROP COLUMN
ALTER TABLE public.test_gaps DROP COLUMN col_d_renamed;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_gaps_audit'
  AND column_name = 'col_d_renamed';

-- Multiple non-contiguous gaps: drop another column and add new ones
ALTER TABLE public.test_gaps DROP COLUMN col_a;  -- gap at attnums 2 and 3

ALTER TABLE public.test_gaps ADD COLUMN col_e text;
ALTER TABLE public.test_gaps ADD COLUMN col_f text;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_gaps_audit'
  AND column_name IN ('col_e', 'col_f')
ORDER BY column_name;

-- Full DML cycle after multiple gaps
INSERT INTO public.test_gaps (col_c, col_e, col_f) VALUES ('cc', 'ee', 'ff');

SELECT audit_operation, col_c, col_e, col_f
FROM public.test_gaps_audit
WHERE audit_id = (SELECT max(audit_id) FROM public.test_gaps_audit);

-- Cleanup test_gaps
SELECT pgaudix.disable('public.test_gaps', drop_data := true);
DROP TABLE public.test_gaps;

-- Re-create test_orders for final cleanup block
CREATE TABLE public.test_orders (
    id      serial PRIMARY KEY,
    amount  numeric(10,2),
    status  text
);
SELECT pgaudix.enable('public.test_orders');

-- ============================================================
-- Cleanup
-- ============================================================
SELECT pgaudix.disable('public.test_orders', drop_data := true);
DROP TABLE public.test_orders;
DROP EXTENSION pgaudix;
