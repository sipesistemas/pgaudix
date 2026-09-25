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
SELECT source_schema, source_table, audit_table
FROM pgaudix.status();

-- ============================================================
-- Test 2: INSERT audit
-- ============================================================
INSERT INTO public.test_orders (amount, status) VALUES (100.50, 'pending');

SELECT audit_operation, audit_user = session_user AS correct_user, id, amount, status
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

SELECT audit_operation, audit_user = session_user AS correct_user, id, name
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

-- ============================================================
-- Test 28: A6 — REVOKE includes TRUNCATE
-- ============================================================
-- The enable() function must REVOKE TRUNCATE in addition to INSERT/UPDATE/DELETE
-- so a future GRANT TRUNCATE TO PUBLIC is reset on re-enable.
SELECT prosrc LIKE '%REVOKE INSERT, UPDATE, DELETE, TRUNCATE%' AS revoke_includes_truncate
FROM pg_proc
WHERE proname = 'enable' AND pronamespace = 'pgaudix'::regnamespace;

-- ============================================================
-- Test 29: A4 — v_offset NULL is detected and reported
-- ============================================================
CREATE TABLE public.test_a4 (id int, v text);
SELECT pgaudix.enable('public.test_a4');

-- Manually drop audit_app_user_ip (the last metadata column, which defines the
-- offset) to force v_offset = NULL on next ddl_sync
ALTER TABLE public.test_a4_audit DROP COLUMN audit_app_user_ip;

DO $$
BEGIN
    ALTER TABLE public.test_a4 ADD COLUMN x int;
    RAISE NOTICE 'ERROR: ALTER should have failed (v_offset NULL undetected)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: % ', SQLERRM;
END;
$$;

-- Cleanup
SELECT pgaudix.disable('public.test_a4', drop_data := true);
DROP TABLE public.test_a4;

-- ============================================================
-- Test 30: A5 — enable() rejects views and materialized views
-- ============================================================
CREATE VIEW public.test_a5_view AS SELECT 1 AS v;

DO $$
BEGIN
    PERFORM pgaudix.enable('public.test_a5_view');
    RAISE NOTICE 'ERROR: enable on view should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: enable on view rejected: %', SQLERRM;
END;
$$;

DROP VIEW public.test_a5_view;

CREATE MATERIALIZED VIEW public.test_a5_mv AS SELECT 1 AS v;

DO $$
BEGIN
    PERFORM pgaudix.enable('public.test_a5_mv');
    RAISE NOTICE 'ERROR: enable on materialized view should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: enable on materialized view rejected: %', SQLERRM;
END;
$$;

DROP MATERIALIZED VIEW public.test_a5_mv;

-- ============================================================
-- Test 31: A1 — enable() rejects names that would overflow NAMEDATALEN
-- ============================================================
-- Source name 58 chars + '_audit' (6) = 64 > 63
CREATE TABLE public.tab_with_a_name_so_long_it_definitely_overflows_namedatalen (id int);

DO $$
BEGIN
    PERFORM pgaudix.enable('public.tab_with_a_name_so_long_it_definitely_overflows_namedatalen');
    RAISE NOTICE 'ERROR: enable on overlong name should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: enable on overlong name rejected: %', SQLERRM;
END;
$$;

DROP TABLE public.tab_with_a_name_so_long_it_definitely_overflows_namedatalen;

-- ============================================================
-- Test 32: M6 — CHECK constraint on audit_operation
-- ============================================================
CREATE TABLE public.test_m6 (id int);
SELECT pgaudix.enable('public.test_m6');

-- As superuser we bypass REVOKE, but CHECK constraint must reject invalid op
DO $$
BEGIN
    EXECUTE 'INSERT INTO public.test_m6_audit (audit_operation) VALUES (''X'')';
    RAISE NOTICE 'ERROR: invalid audit_operation should have been rejected';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK: invalid audit_operation rejected by CHECK constraint';
END;
$$;

SELECT pgaudix.disable('public.test_m6', drop_data := true);
DROP TABLE public.test_m6;

-- ============================================================
-- Test 33: A3 — DROP TABLE on source removes monitored_tables row
-- ============================================================
CREATE TABLE public.test_a3 (id int);
SELECT pgaudix.enable('public.test_a3');

-- Drop the source table directly
DROP TABLE public.test_a3;

-- After source DROP, monitored_tables should not have an orphaned row
SELECT count(*) AS orphan_rows
FROM pgaudix.monitored_tables
WHERE source_table = 'test_a3';

-- The audit table is dropped together with its source
SELECT count(*) AS audit_tables_left
FROM pg_catalog.pg_class
WHERE relname = 'test_a3_audit';

-- ============================================================
-- Test 34: A2 — ALTER SCHEMA RENAME keeps audit in sync
-- ============================================================
CREATE SCHEMA test_a2_old;
CREATE TABLE test_a2_old.tab (id int, v text);
SELECT pgaudix.enable('test_a2_old.tab');

-- Rename the schema
ALTER SCHEMA test_a2_old RENAME TO test_a2_new;

-- Now ALTER on the source must still sync the audit table (which lives in the renamed schema)
ALTER TABLE test_a2_new.tab ADD COLUMN x int;

-- The audit table in the new schema should have column x
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'test_a2_new' AND table_name = 'tab_audit'
  AND column_name = 'x';

-- monitored_tables should reflect the new schema name
SELECT source_schema, audit_schema
FROM pgaudix.status()
WHERE source_table = 'tab';

SELECT pgaudix.disable('test_a2_new.tab', drop_data := true);
DROP TABLE test_a2_new.tab;
DROP SCHEMA test_a2_new;

-- ============================================================
-- Test 35: M4 — status() reports integrity of audit objects
-- ============================================================
CREATE TABLE public.test_m4 (id int);
SELECT pgaudix.enable('public.test_m4');

-- Healthy state: all three integrity columns true
SELECT audit_table_exists, dml_trigger_exists, truncate_trigger_exists
FROM pgaudix.status()
WHERE source_table = 'test_m4';

-- Drop the audit table directly (DROP TABLE doesn't fire ddl_sync filter)
DROP TABLE public.test_m4_audit;

-- status() should now report audit_table_exists = false
SELECT audit_table_exists
FROM pgaudix.status()
WHERE source_table = 'test_m4';

-- Cleanup (disable accepts missing audit table)
SELECT pgaudix.disable('public.test_m4');
DROP TABLE public.test_m4;

-- ============================================================
-- Test 36: registry survives pg_dump/restore
-- ============================================================
-- monitored_tables (and its sequence) must be marked for dump, otherwise
-- pg_dump skips their contents because they belong to the extension
SELECT c.relname
FROM pg_catalog.pg_extension e
CROSS JOIN LATERAL unnest(e.extconfig) AS cfg(relid)
JOIN pg_catalog.pg_class c ON c.oid = cfg.relid
WHERE e.extname = 'pgaudix'
ORDER BY 1;

CREATE TABLE public.test_restore (id int, v text);
SELECT pgaudix.enable('public.test_restore');

-- Simulate a logical restore: the registry row comes back but every relation
-- got a new OID, so the stored source_oid / audit_oid point at nothing
UPDATE pgaudix.monitored_tables
SET source_oid = 4294967295, audit_oid = 4294967294
WHERE source_table = 'test_restore';

-- DDL sync must re-resolve the table by name and keep the audit table in sync
ALTER TABLE public.test_restore ADD COLUMN w int;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_restore_audit'
  AND column_name = 'w';

INSERT INTO public.test_restore VALUES (1, 'a', 2);

SELECT audit_operation, id, v, w
FROM public.test_restore_audit
ORDER BY audit_id;

-- The registry now holds the real OIDs again
SELECT source_oid = 'public.test_restore'::regclass       AS source_oid_healed,
       audit_oid  = 'public.test_restore_audit'::regclass AS audit_oid_healed
FROM pgaudix.monitored_tables
WHERE source_table = 'test_restore';

-- status() heals too
UPDATE pgaudix.monitored_tables
SET source_oid = 4294967295, audit_oid = NULL
WHERE source_table = 'test_restore';

SELECT audit_table_exists, dml_trigger_exists
FROM pgaudix.status()
WHERE source_table = 'test_restore';

-- disable() heals too
UPDATE pgaudix.monitored_tables
SET source_oid = 4294967295, audit_oid = NULL
WHERE source_table = 'test_restore';

SELECT pgaudix.disable('public.test_restore', drop_data := true);

SELECT count(*) AS registry_rows_left
FROM pgaudix.monitored_tables
WHERE source_table = 'test_restore';

DROP TABLE public.test_restore;

-- drop_cleanup must also match by name when the stored OID is stale
CREATE TABLE public.test_restore2 (id int);
SELECT pgaudix.enable('public.test_restore2');

UPDATE pgaudix.monitored_tables
SET source_oid = 4294967295
WHERE source_table = 'test_restore2';

DROP TABLE public.test_restore2;

SELECT count(*) AS orphan_rows
FROM pgaudix.monitored_tables
WHERE source_table = 'test_restore2';

DROP TABLE public.test_restore2_audit;

-- ============================================================
-- Test 37: ALTER COLUMN TYPE that needs USING keeps the source writable
-- ============================================================
CREATE TABLE public.test_type (id int, flag int, n int, v text);
SELECT pgaudix.enable('public.test_type');
INSERT INTO public.test_type VALUES (1, 1, 1, 'a very long string');

-- int -> boolean: history converts with an explicit cast, audit follows the type
ALTER TABLE public.test_type ALTER COLUMN flag TYPE boolean USING flag <> 0;

SELECT data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_type_audit'
  AND column_name = 'flag';

INSERT INTO public.test_type VALUES (2, true, 2, 'x');

-- int -> uuid: history cannot convert; the audit column degrades to text so
-- history is kept and new (uuid) values can still be written
ALTER TABLE public.test_type ALTER COLUMN n TYPE uuid USING NULL;

SELECT data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_type_audit'
  AND column_name = 'n';

INSERT INTO public.test_type VALUES (3, false, '6d1d3e3c-0b3a-4d3a-9c1e-1f4c7a2b9e10', 'y');

-- text -> varchar(3): history is too long; a text audit column is never
-- narrowed, and later DDL must not keep warning about it
ALTER TABLE public.test_type ALTER COLUMN v TYPE varchar(3) USING left(v, 3);
ALTER TABLE public.test_type ADD COLUMN extra int;

SELECT data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_type_audit'
  AND column_name = 'v';

INSERT INTO public.test_type VALUES (4, true, NULL, 'z', 9);

SELECT audit_operation, id, flag, n, v, extra
FROM public.test_type_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_type', drop_data := true);
DROP TABLE public.test_type;

-- ============================================================
-- Test 38: source columns named like gap fillers are left alone
-- ============================================================
-- drop_me leaves a hole at attnum 2, exactly where a gap filler goes;
-- the source also has a real column with the filler's name, and one
-- that only matches the old LIKE pattern through its unescaped '_'
CREATE TABLE public.test_gapname (
    id              int,
    drop_me         int,
    _pgaudix_gap_2  int,
    xpgaudix_gap_1  text
);
ALTER TABLE public.test_gapname DROP COLUMN drop_me;

SELECT pgaudix.enable('public.test_gapname');

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_gapname_audit'
  AND column_name NOT LIKE 'audit\_%'
ORDER BY ordinal_position;

INSERT INTO public.test_gapname VALUES (1, 2, 'x');

-- attnum alignment must still hold after the fillers are dropped
ALTER TABLE public.test_gapname ADD COLUMN later int;
INSERT INTO public.test_gapname VALUES (2, 3, 'y', 4);

SELECT audit_operation, id, _pgaudix_gap_2, xpgaudix_gap_1, later
FROM public.test_gapname_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_gapname', drop_data := true);
DROP TABLE public.test_gapname;

-- ============================================================
-- Test 39: pg_temp cannot shadow the types used by the API functions
-- ============================================================
-- Fresh session: PL/pgSQL resolves DECLARE types on the first call per
-- backend, so the shadowing temp tables must exist before that call
\c
CREATE TEMP TABLE text (dummy int);
CREATE TEMP TABLE name (dummy int);

CREATE TABLE public.test_shadow (id int, v pg_catalog.text);
SELECT pgaudix.enable('public.test_shadow');

INSERT INTO public.test_shadow VALUES (1, 'a');
ALTER TABLE public.test_shadow ADD COLUMN w int;
INSERT INTO public.test_shadow VALUES (2, 'b', 3);

SELECT audit_operation, id, v, w
FROM public.test_shadow_audit
ORDER BY audit_id;

SELECT dml_trigger_exists
FROM pgaudix.status()
WHERE source_table = 'test_shadow';

SELECT pgaudix.disable('public.test_shadow', drop_data := true);
DROP TABLE public.test_shadow;
DROP TABLE pg_temp.text, pg_temp.name;

-- ============================================================
-- Test 40: DROP and ADD of the same column name in one statement
-- ============================================================
CREATE TABLE public.test_dropadd (id int, c text);
SELECT pgaudix.enable('public.test_dropadd');
INSERT INTO public.test_dropadd VALUES (1, 'old');

-- PostgreSQL runs the DROP before the ADD, so the audit table must drop its
-- old "c" before adding the new one
ALTER TABLE public.test_dropadd DROP COLUMN c, ADD COLUMN c int;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_dropadd_audit'
  AND column_name = 'c';

INSERT INTO public.test_dropadd VALUES (2, 42);

-- attnum alignment still holds afterwards
ALTER TABLE public.test_dropadd ADD COLUMN d int;
INSERT INTO public.test_dropadd VALUES (3, 43, 44);

SELECT audit_operation, id, c, d
FROM public.test_dropadd_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_dropadd', drop_data := true);
DROP TABLE public.test_dropadd;

-- ============================================================
-- Test 41: ADD COLUMN order must not depend on the pg_attribute scan plan
-- ============================================================
CREATE TABLE public.test_order (id int);
SELECT pgaudix.enable('public.test_order');

-- Force a heap scan of pg_attribute: the SET DEFAULT on "e" rewrites its
-- catalog row, so physical order becomes f, e
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan = off;
ALTER TABLE public.test_order ADD COLUMN e int, ADD COLUMN f int, ALTER COLUMN e SET DEFAULT 1;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_order_audit'
  AND column_name IN ('e', 'f')
ORDER BY ordinal_position;

INSERT INTO public.test_order VALUES (1, 2, 3);

SELECT audit_operation, id, e, f
FROM public.test_order_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_order', drop_data := true);
DROP TABLE public.test_order;

-- ============================================================
-- Test 42: DDL propagated through inheritance / partitioning is synced
-- ============================================================
-- pg_event_trigger_ddl_commands() only reports the table named in the
-- ALTER, so descendants must be expanded explicitly
CREATE TABLE public.test_parent (id int);
CREATE TABLE public.test_child (extra text) INHERITS (public.test_parent);
SELECT pgaudix.enable('public.test_child');

ALTER TABLE public.test_parent ADD COLUMN newcol int;
ALTER TABLE public.test_parent RENAME COLUMN id TO id2;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_child_audit'
  AND column_name NOT LIKE 'audit\_%'
ORDER BY ordinal_position;

INSERT INTO public.test_child VALUES (1, 'x', 2);

SELECT audit_operation, id2, extra, newcol
FROM public.test_child_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_child', drop_data := true);
DROP TABLE public.test_child;
DROP TABLE public.test_parent;

-- A partition audited directly must follow ALTERs on its root
CREATE TABLE public.test_proot (id int, k int) PARTITION BY LIST (k);
CREATE TABLE public.test_p1 PARTITION OF public.test_proot FOR VALUES IN (1);
SELECT pgaudix.enable('public.test_p1');

ALTER TABLE public.test_proot ADD COLUMN v text;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_p1_audit'
  AND column_name = 'v';

INSERT INTO public.test_proot VALUES (1, 1, 'a');

SELECT audit_operation, id, k, v
FROM public.test_p1_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_p1', drop_data := true);
DROP TABLE public.test_proot;

-- ============================================================
-- Test 43: partition-leaf TRUNCATE triggers follow RENAME, ATTACH and DETACH
-- ============================================================
CREATE TABLE public.test_pr (id int, k int) PARTITION BY LIST (k);
CREATE TABLE public.test_pr_1 PARTITION OF public.test_pr FOR VALUES IN (1);
SELECT pgaudix.enable('public.test_pr');

-- Rename the root: the leaf trigger must point at the renamed audit table
ALTER TABLE public.test_pr RENAME TO test_pr2;
TRUNCATE public.test_pr_1;

-- A partition attached after enable() must be audited too
CREATE TABLE public.test_pr_2 (id int, k int);
ALTER TABLE public.test_pr2 ATTACH PARTITION public.test_pr_2 FOR VALUES IN (2);
TRUNCATE public.test_pr_2;

SELECT count(*) AS truncate_rows
FROM public.test_pr2_audit
WHERE audit_operation = 'T';

-- A detached partition must not keep writing into the root's audit table
ALTER TABLE public.test_pr2 DETACH PARTITION public.test_pr_1;

SELECT count(*) AS leaf_triggers_after_detach
FROM pg_catalog.pg_trigger
WHERE tgrelid = 'public.test_pr_1'::regclass AND tgname = 'pgaudix_truncate_trigger';

TRUNCATE public.test_pr_1;

SELECT count(*) AS truncate_rows_after_detach
FROM public.test_pr2_audit
WHERE audit_operation = 'T';

-- disable() removes the remaining leaf trigger
SELECT pgaudix.disable('public.test_pr2', drop_data := true);

SELECT count(*) AS leaf_triggers_after_disable
FROM pg_catalog.pg_trigger
WHERE tgrelid = 'public.test_pr_2'::regclass AND tgname = 'pgaudix_truncate_trigger';

DROP TABLE public.test_pr2;
DROP TABLE public.test_pr_1;

-- ============================================================
-- Test 44: DDL sync and drop cleanup also run under replica role
-- ============================================================
-- The DML/TRUNCATE triggers are ENABLE ALWAYS (bug #4), so the event
-- triggers must be too, otherwise DDL desyncs the audit table
SELECT evtname, evtenabled
FROM pg_catalog.pg_event_trigger
WHERE evtname LIKE 'pgaudix%'
ORDER BY evtname;

CREATE TABLE public.test_replica (id int);
CREATE TABLE public.test_replica_drop (id int);
SELECT pgaudix.enable('public.test_replica');
SELECT pgaudix.enable('public.test_replica_drop');

SET session_replication_role = replica;
ALTER TABLE public.test_replica ADD COLUMN x int;
INSERT INTO public.test_replica VALUES (1, 2);
DROP TABLE public.test_replica_drop;
RESET session_replication_role;

SELECT audit_operation, id, x
FROM public.test_replica_audit
ORDER BY audit_id;

SELECT count(*) AS orphan_rows
FROM pgaudix.monitored_tables
WHERE source_table = 'test_replica_drop';

SELECT pgaudix.disable('public.test_replica', drop_data := true);
DROP TABLE public.test_replica;
DROP TABLE public.test_replica_drop_audit;

-- ============================================================
-- Test 45: the DDL sync recursion guard cannot be forged by a regular role
-- ============================================================
CREATE ROLE pgaudix_test_guard;
CREATE TABLE public.test_guard (id int);
SELECT pgaudix.enable('public.test_guard');

-- A custom GUC can be set by anyone; it must not disable the sync
SET ROLE pgaudix_test_guard;
SET pgaudix.in_ddl_sync = 'true';
RESET ROLE;

ALTER TABLE public.test_guard ADD COLUMN x int;
INSERT INTO public.test_guard VALUES (1, 2);

SELECT audit_operation, id, x
FROM public.test_guard_audit
ORDER BY audit_id;

RESET pgaudix.in_ddl_sync;
SELECT pgaudix.disable('public.test_guard', drop_data := true);
DROP TABLE public.test_guard;
DROP ROLE pgaudix_test_guard;

-- ============================================================
-- Test 46: functions are closed to PUBLIC; enable/disable check ownership
-- ============================================================
CREATE ROLE pgaudix_test_owner;
CREATE ROLE pgaudix_test_other;
GRANT USAGE ON SCHEMA pgaudix TO pgaudix_test_owner, pgaudix_test_other;
GRANT USAGE, CREATE ON SCHEMA public TO pgaudix_test_owner, pgaudix_test_other;

CREATE TABLE public.test_priv_other (id int);
CREATE TABLE public.test_priv_other2 (id int);
ALTER TABLE public.test_priv_other OWNER TO pgaudix_test_other;
ALTER TABLE public.test_priv_other2 OWNER TO pgaudix_test_other;
SELECT pgaudix.enable('public.test_priv_other');

SET ROLE pgaudix_test_owner;
CREATE TABLE public.test_priv_own (id int, v text);

-- Schema USAGE alone grants nothing: the API and the trigger functions
-- (which run as the extension owner) must not be executable by PUBLIC
SELECT pgaudix.enable('public.test_priv_own');
SELECT count(*) FROM pgaudix.status();
CREATE TRIGGER forge AFTER INSERT ON public.test_priv_own
    FOR EACH ROW EXECUTE FUNCTION pgaudix.audit_trigger('"public"."test_priv_other_audit"');
CREATE TRIGGER forge_t AFTER TRUNCATE ON public.test_priv_own
    FOR EACH STATEMENT EXECUTE FUNCTION pgaudix.truncate_trigger('public', 'test_priv_other_audit');
RESET ROLE;

-- With EXECUTE granted, a role can only manage tables it owns
GRANT EXECUTE ON FUNCTION pgaudix.enable(regclass), pgaudix.disable(regclass, boolean),
                          pgaudix.status() TO pgaudix_test_owner;
SET ROLE pgaudix_test_owner;
SELECT pgaudix.enable('public.test_priv_own');
INSERT INTO public.test_priv_own VALUES (1, 'a');
SELECT count(*) AS visible_in_status FROM pgaudix.status();
SELECT pgaudix.enable('public.test_priv_other2');
SELECT pgaudix.disable('public.test_priv_other', drop_data := true);
RESET ROLE;

-- The other table's audit data survived, and the owner's DML was audited
SELECT count(*) AS other_audit_table_exists
FROM pg_catalog.pg_class WHERE relname = 'test_priv_other_audit';

SELECT audit_operation, id, v
FROM public.test_priv_own_audit
ORDER BY audit_id;

-- Cleanup
SELECT pgaudix.disable('public.test_priv_own', drop_data := true);
SELECT pgaudix.disable('public.test_priv_other', drop_data := true);
DROP TABLE public.test_priv_own;
DROP TABLE public.test_priv_other;
DROP TABLE public.test_priv_other2;
DROP OWNED BY pgaudix_test_owner, pgaudix_test_other;
DROP ROLE pgaudix_test_owner;
DROP ROLE pgaudix_test_other;

-- ============================================================
-- Test 47: one T row per TRUNCATE statement on a partitioned table
-- ============================================================
CREATE TABLE public.test_tr (id int, k int) PARTITION BY LIST (k);
CREATE TABLE public.test_tr_1 PARTITION OF public.test_tr FOR VALUES IN (1);
CREATE TABLE public.test_tr_2 PARTITION OF public.test_tr FOR VALUES IN (2);
SELECT pgaudix.enable('public.test_tr');

-- TRUNCATE of the root fires the statement triggers of the root and of every
-- partition; only one audit row must be written
TRUNCATE public.test_tr;
SELECT count(*) AS rows_after_root_truncate
FROM public.test_tr_audit WHERE audit_operation = 'T';

-- A partition truncated directly is still audited
TRUNCATE public.test_tr_1;
SELECT count(*) AS rows_after_leaf_truncate
FROM public.test_tr_audit WHERE audit_operation = 'T';

-- Separate statements in one transaction are separate operations
BEGIN;
    TRUNCATE public.test_tr_2;
    TRUNCATE public.test_tr;
COMMIT;
SELECT count(*) AS rows_after_two_statements
FROM public.test_tr_audit WHERE audit_operation = 'T';

SELECT pgaudix.disable('public.test_tr', drop_data := true);
DROP TABLE public.test_tr;

-- ============================================================
-- Test 48: domain columns are mirrored with the domain's base type
-- ============================================================
-- A domain carries its NOT NULL / CHECK constraints with the type name, and
-- the T row leaves every mirrored column NULL, so the audit table must use
-- the underlying base type instead
CREATE DOMAIN public.test_nn_int AS int NOT NULL;
CREATE DOMAIN public.test_pos AS numeric(8,2) CHECK (VALUE > 0);
CREATE DOMAIN public.test_nested AS public.test_pos;

CREATE DOMAIN public.test_tag AS text CHECK (VALUE <> '');

CREATE TABLE public.test_dom (
    id   int,
    a    public.test_nn_int,
    b    public.test_pos,
    c    public.test_nested,
    tags public.test_tag[],
    amts public.test_pos[]
);
SELECT pgaudix.enable('public.test_dom');

SELECT column_name, data_type, numeric_precision, numeric_scale, domain_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_dom_audit'
  AND column_name IN ('a', 'b', 'c')
ORDER BY ordinal_position;

-- Arrays of a domain are mirrored as arrays of the base type
SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod) AS audit_type
FROM pg_catalog.pg_attribute a
WHERE a.attrelid = 'public.test_dom_audit'::regclass
  AND a.attname IN ('tags', 'amts')
ORDER BY a.attnum;

INSERT INTO public.test_dom VALUES (1, 2, 3.5, 4.25, ARRAY['x', 'y'], ARRAY[1.5]);
TRUNCATE public.test_dom;

-- DDL sync must apply the same rule for added and retyped columns
ALTER TABLE public.test_dom ADD COLUMN d public.test_nn_int;
ALTER TABLE public.test_dom ALTER COLUMN id TYPE public.test_nn_int USING id;
INSERT INTO public.test_dom VALUES (2, 5, 6.5, 7.25, NULL, NULL, 8);
TRUNCATE public.test_dom;

-- and must not keep trying to "convert" the audit columns afterwards
ALTER TABLE public.test_dom ADD COLUMN e int;

SELECT column_name, data_type, domain_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_dom_audit'
  AND column_name IN ('id', 'd')
ORDER BY ordinal_position;

SELECT audit_operation, id, a, b, c, tags, amts, d
FROM public.test_dom_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_dom', drop_data := true);
DROP TABLE public.test_dom;
DROP DOMAIN public.test_tag;
DROP DOMAIN public.test_nested;
DROP DOMAIN public.test_pos;
DROP DOMAIN public.test_nn_int;

-- ============================================================
-- Test 49: a broken registry row must not affect DDL on other tables
-- ============================================================
CREATE TABLE public.test_broken (id int);
CREATE TABLE public.test_conflict (id int);
CREATE TABLE public.test_unrelated (id int);
SELECT pgaudix.enable('public.test_broken');
SELECT pgaudix.enable('public.test_conflict');
SELECT pgaudix.enable('public.test_unrelated');

-- Audit table dropped behind pgaudix's back
DROP TABLE public.test_broken_audit;

-- Registry drift: the source was renamed while the sync was bypassed (only a
-- superuser can do this), and the audit name it now expects is taken
CREATE TABLE public.test_conflict2_audit (x int);
INSERT INTO pgaudix.ddl_guard (pid) VALUES (pg_backend_pid());
ALTER TABLE public.test_conflict RENAME TO test_conflict2;
DELETE FROM pgaudix.ddl_guard WHERE pid = pg_backend_pid();

-- DDL on an unrelated table: no NOTICE, no error, synced normally
ALTER TABLE public.test_unrelated ADD COLUMN x int;
INSERT INTO public.test_unrelated VALUES (1, 2);

SELECT audit_operation, id, x
FROM public.test_unrelated_audit
ORDER BY audit_id;

-- The broken tables report their own problem only when they are altered
ALTER TABLE public.test_broken ADD COLUMN y int;
ALTER TABLE public.test_conflict2 ADD COLUMN y int;

-- Cleanup
SELECT pgaudix.disable('public.test_unrelated', drop_data := true);
SELECT pgaudix.disable('public.test_broken');
SELECT pgaudix.disable('public.test_conflict2');
DROP TABLE public.test_unrelated;
DROP TABLE public.test_broken;
DROP TABLE public.test_conflict2;
DROP TABLE public.test_conflict_audit;
DROP TABLE public.test_conflict2_audit;

-- ============================================================
-- Test 50: the extension's own tables cannot be audited
-- ============================================================
DO $$
BEGIN
    PERFORM pgaudix.enable('pgaudix.monitored_tables');
    RAISE NOTICE 'ERROR: enable on pgaudix.monitored_tables should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: enable on extension table rejected: %', SQLERRM;
END;
$$;

SELECT count(*) AS registry_audit_tables
FROM pg_catalog.pg_class
WHERE relname = 'monitored_tables_audit';

-- ============================================================
-- Test 51: DDL after the first audited row in the same session
-- ============================================================
-- The C trigger caches its INSERT plan per source relation; every kind of
-- change that alters the column list must invalidate it within the session
CREATE TABLE public.test_cache (id int, a text);
SELECT pgaudix.enable('public.test_cache');
INSERT INTO public.test_cache VALUES (1, 'a');

ALTER TABLE public.test_cache ADD COLUMN b int;
INSERT INTO public.test_cache VALUES (2, 'b', 20);

ALTER TABLE public.test_cache RENAME COLUMN b TO c;
INSERT INTO public.test_cache VALUES (3, 'c', 30);

ALTER TABLE public.test_cache ALTER COLUMN c TYPE bigint;
INSERT INTO public.test_cache VALUES (4, 'd', 40);

ALTER TABLE public.test_cache DROP COLUMN a;
INSERT INTO public.test_cache VALUES (5, 50);

ALTER TABLE public.test_cache RENAME TO test_cache2;
INSERT INTO public.test_cache2 VALUES (6, 60);

SELECT audit_operation, id, c
FROM public.test_cache2_audit
ORDER BY audit_id;

-- Disable and re-enable in the same session
SELECT pgaudix.disable('public.test_cache2', drop_data := true);
INSERT INTO public.test_cache2 VALUES (7, 70);
SELECT pgaudix.enable('public.test_cache2');
INSERT INTO public.test_cache2 VALUES (8, 80);

SELECT audit_operation, id, c
FROM public.test_cache2_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_cache2', drop_data := true);
DROP TABLE public.test_cache2;

-- Partitions with different physical layouts share one audit table
CREATE TABLE public.test_cpart (id int, k int, v text) PARTITION BY LIST (k);
CREATE TABLE public.test_cpart_1 PARTITION OF public.test_cpart FOR VALUES IN (1);
CREATE TABLE public.test_cpart_2 (id int, junk int, k int, v text);
ALTER TABLE public.test_cpart_2 DROP COLUMN junk;
ALTER TABLE public.test_cpart ATTACH PARTITION public.test_cpart_2 FOR VALUES IN (2);
SELECT pgaudix.enable('public.test_cpart');

INSERT INTO public.test_cpart VALUES (1, 1, 'p1'), (2, 2, 'p2'), (3, 1, 'p1 again');
UPDATE public.test_cpart SET v = v || '!' WHERE id = 2;

SELECT audit_operation, id, k, v
FROM public.test_cpart_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_cpart', drop_data := true);
DROP TABLE public.test_cpart;

-- ============================================================
-- Test 52: audit_app_user / audit_app_user_ip record what the application sets via GUC
-- ============================================================
-- A SaaS connects with one PostgreSQL role, so audit_user cannot identify
-- the end user and audit_client_addr is the application server. The
-- application sets pgaudix.app_user and pgaudix.app_user_ip per transaction
-- and the audit row records them; NULL when nothing was set.
CREATE TABLE public.test_appuser (id int, v text);
SELECT pgaudix.enable('public.test_appuser');

INSERT INTO public.test_appuser VALUES (1, 'anonymous');

BEGIN;
    SET LOCAL pgaudix.app_user = 'user-4711';
    SET LOCAL pgaudix.app_user_ip = '203.0.113.7';
    INSERT INTO public.test_appuser VALUES (2, 'by 4711');
    UPDATE public.test_appuser SET v = 'by 4711 again' WHERE id = 2;
COMMIT;

-- SET LOCAL ends with the transaction
INSERT INTO public.test_appuser VALUES (3, 'anonymous again');

-- The IP is free text: whatever the application saw (proxy lists included)
BEGIN;
    SET LOCAL pgaudix.app_user_ip = '2001:db8::1, 10.0.0.2';
    DELETE FROM public.test_appuser WHERE id = 1;
COMMIT;

SELECT audit_operation, id, v, audit_app_user, audit_app_user_ip,
       audit_user = session_user AS pg_user_ok
FROM public.test_appuser_audit
ORDER BY audit_id;

-- psql prints NULL and '' the same way: once a session has run SET LOCAL on
-- a custom GUC, current_setting(..., true) returns '' instead of NULL for
-- the rest of the session, so an unattributed row must still be NULL (not
-- an empty string) or `WHERE audit_app_user IS NULL` misses it (pooled
-- connections reuse backends across requests).
SELECT id, audit_app_user IS NULL AS user_is_null,
       audit_app_user_ip IS NULL AS ip_is_null
FROM public.test_appuser_audit
ORDER BY audit_id;

-- Metadata columns come first, then mirrored columns; DDL sync still aligns
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_appuser_audit'
ORDER BY ordinal_position;

ALTER TABLE public.test_appuser ADD COLUMN w int;
INSERT INTO public.test_appuser VALUES (4, 'x', 40);

SELECT audit_operation, id, v, w
FROM public.test_appuser_audit
WHERE id = 4;

SELECT pgaudix.disable('public.test_appuser', drop_data := true);
DROP TABLE public.test_appuser;

-- The new metadata names are reserved
CREATE TABLE public.test_appuser_clash (id int, audit_app_user text);
DO $$
BEGIN
    PERFORM pgaudix.enable('public.test_appuser_clash');
    RAISE NOTICE 'ERROR: enable should have rejected a source column named audit_app_user';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: reserved name rejected';
END;
$$;
DROP TABLE public.test_appuser_clash;
CREATE TABLE public.test_appuser_clash (id int, audit_app_user_ip text);
DO $$
BEGIN
    PERFORM pgaudix.enable('public.test_appuser_clash');
    RAISE NOTICE 'ERROR: enable should have rejected a source column named audit_app_user_ip';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: reserved name rejected';
END;
$$;
DROP TABLE public.test_appuser_clash;

-- ============================================================
-- Test 53: dropping the source drops its audit table
-- ============================================================
CREATE TABLE public.test_dropsrc (id int);
SELECT pgaudix.enable('public.test_dropsrc');
INSERT INTO public.test_dropsrc VALUES (1);
DROP TABLE public.test_dropsrc;

SELECT count(*) AS audit_tables_left
FROM pg_catalog.pg_class
WHERE relname = 'test_dropsrc_audit';

-- A table recreated with the same name can be audited again
CREATE TABLE public.test_dropsrc (id int, v text);
SELECT pgaudix.enable('public.test_dropsrc');
INSERT INTO public.test_dropsrc VALUES (2, 'again');

SELECT audit_operation, id, v
FROM public.test_dropsrc_audit
ORDER BY audit_id;

SELECT pgaudix.disable('public.test_dropsrc', drop_data := true);
DROP TABLE public.test_dropsrc;

-- Source and audit dropped by the same statement
CREATE SCHEMA test_dropschema;
CREATE TABLE test_dropschema.t (id int);
SELECT pgaudix.enable('test_dropschema.t');
DROP SCHEMA test_dropschema CASCADE;

SELECT count(*) AS registry_rows_left
FROM pgaudix.monitored_tables
WHERE source_schema = 'test_dropschema';

-- ============================================================
-- Test 54: no dead "enabled" flag in the registry
-- ============================================================
-- Auditing is either on (registered) or off (disable()); a flag nobody sets
-- would only mislead an operator into editing the registry by hand
SELECT count(*) AS enabled_columns
FROM information_schema.columns
WHERE (table_schema = 'pgaudix' AND table_name = 'monitored_tables' AND column_name = 'enabled')
   OR (table_schema = 'pgaudix' AND table_name = 'status' AND column_name = 'enabled');

SELECT count(*) AS enabled_in_status
FROM pg_catalog.pg_proc p
CROSS JOIN LATERAL unnest(p.proargnames) AS a(name)
WHERE p.proname = 'status' AND p.pronamespace = 'pgaudix'::regnamespace
  AND a.name = 'enabled';

-- ============================================================
-- Test 55: scenarios inherited from the retired bug-confirmation script
-- ============================================================
-- Two ALTERs in one transaction are both synced (recursion guard released)
CREATE TABLE public.test_twoalter (id int);
SELECT pgaudix.enable('public.test_twoalter');
BEGIN;
    ALTER TABLE public.test_twoalter ADD COLUMN a int;
    ALTER TABLE public.test_twoalter ADD COLUMN b int;
COMMIT;
INSERT INTO public.test_twoalter VALUES (1, 2, 3);
SELECT audit_operation, id, a, b FROM public.test_twoalter_audit;
SELECT pgaudix.disable('public.test_twoalter', drop_data := true);
DROP TABLE public.test_twoalter;

-- ALTER TABLE ... SET SCHEMA moves the audit table along
CREATE SCHEMA test_ss_old;
CREATE SCHEMA test_ss_new;
CREATE TABLE test_ss_old.t (id int, v text);
SELECT pgaudix.enable('test_ss_old.t');
ALTER TABLE test_ss_old.t SET SCHEMA test_ss_new;
INSERT INTO test_ss_new.t VALUES (1, 'moved');
SELECT audit_operation, id, v FROM test_ss_new.t_audit;
SELECT source_schema, audit_schema FROM pgaudix.status() WHERE source_table = 't';
SELECT pgaudix.disable('test_ss_new.t', drop_data := true);
DROP TABLE test_ss_new.t;
DROP SCHEMA test_ss_old;
DROP SCHEMA test_ss_new;

-- The audit-name length guard counts bytes: 30 multibyte chars = 60 bytes,
-- plus "_audit" exceeds NAMEDATALEN even though it is only 36 characters
DO $$
DECLARE
    src text := repeat(chr(225), 30);
BEGIN
    EXECUTE format('CREATE TABLE public.%I (id int)', src);
    BEGIN
        PERFORM pgaudix.enable(format('public.%I', src)::regclass);
        RAISE NOTICE 'ERROR: enable should have rejected a 60-byte name';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK: multibyte name rejected';
    END;
    EXECUTE format('DROP TABLE public.%I', src);
END;
$$;

-- A source whose attnum span would overflow 1600 audit columns is rejected
-- with a pgaudix error, not the generic "tables can have at most 1600 columns"
DO $$
DECLARE
    cols  text;
    drops text;
BEGIN
    SELECT string_agg(format('c%s int', g), ', ') INTO cols FROM generate_series(1, 1595) g;
    EXECUTE format('CREATE TABLE public.test_wide (id int, %s)', cols);
    SELECT string_agg(format('DROP COLUMN c%s', g), ', ') INTO drops FROM generate_series(1, 1594) g;
    EXECUTE format('ALTER TABLE public.test_wide %s', drops);
    BEGIN
        PERFORM pgaudix.enable('public.test_wide');
        RAISE NOTICE 'ERROR: enable should have rejected the attnum span';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK: % ', SQLERRM;
    END;
    DROP TABLE public.test_wide;
END;
$$;

-- An UNLOGGED source gets an UNLOGGED audit table
CREATE UNLOGGED TABLE public.test_unlogged (id int);
SELECT pgaudix.enable('public.test_unlogged');
SELECT relname, relpersistence
FROM pg_catalog.pg_class
WHERE relname IN ('test_unlogged', 'test_unlogged_audit')
ORDER BY relname;
SELECT pgaudix.disable('public.test_unlogged', drop_data := true);
DROP TABLE public.test_unlogged;

-- ============================================================
-- Test 56: reserved metadata names in ADD / RENAME COLUMN give a clear error
-- ============================================================
CREATE TABLE public.test_reserved (id int, x int);
SELECT pgaudix.enable('public.test_reserved');

DO $$
BEGIN
    ALTER TABLE public.test_reserved RENAME COLUMN x TO audit_user;
    RAISE NOTICE 'ERROR: rename to a reserved name should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    ALTER TABLE public.test_reserved ADD COLUMN audit_id int;
    RAISE NOTICE 'ERROR: adding a reserved name should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- The table is untouched and still audited
INSERT INTO public.test_reserved VALUES (1, 2);
SELECT audit_operation, id, x FROM public.test_reserved_audit;

SELECT pgaudix.disable('public.test_reserved', drop_data := true);
DROP TABLE public.test_reserved;

-- ============================================================
-- Test 57: heal_registry() must not trust an OID that now belongs to another table
-- ============================================================
-- After pg_dump/restore the registry keeps the old OIDs. If one of them was
-- reused by an unrelated relation in the new cluster, the row still has to be
-- re-resolved by name; existence of the OID alone proves nothing.
CREATE TABLE public.test_heal_src (id int);
CREATE TABLE public.test_heal_other (id int);
CREATE TABLE public.test_heal_other_audit (id int);
SELECT pgaudix.enable('public.test_heal_src');

-- Simulate the collision: both stored OIDs exist but belong to other relations
UPDATE pgaudix.monitored_tables
SET source_oid = 'public.test_heal_other'::regclass,
    audit_oid  = 'public.test_heal_other_audit'::regclass
WHERE source_table = 'test_heal_src';

SELECT pgaudix.heal_registry();
SELECT source_oid = 'public.test_heal_src'::regclass       AS source_healed,
       audit_oid  = 'public.test_heal_src_audit'::regclass AS audit_healed
FROM pgaudix.monitored_tables
WHERE source_table = 'test_heal_src';

-- DDL on the unrelated table must not touch it or the audit table
ALTER TABLE public.test_heal_other ADD COLUMN x int;
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_heal_other_audit'
ORDER BY ordinal_position;
SELECT tgname FROM pg_catalog.pg_trigger
WHERE tgrelid = 'public.test_heal_other'::regclass AND NOT tgisinternal;

-- Dropping the unrelated table (colliding OID, no heal has run yet) must not
-- drop the real audit table nor deregister the real source
UPDATE pgaudix.monitored_tables
SET source_oid = 'public.test_heal_other'::regclass
WHERE source_table = 'test_heal_src';
DROP TABLE public.test_heal_other;
SELECT to_regclass('public.test_heal_src_audit') IS NOT NULL AS audit_exists,
       (SELECT count(*) FROM pgaudix.monitored_tables WHERE source_table = 'test_heal_src') AS registry_rows;
INSERT INTO public.test_heal_src VALUES (1);
SELECT audit_operation, id FROM public.test_heal_src_audit;

-- Same collision, but the real source lost its trigger (restore where the
-- .so was missing): the row cannot be healed, and dropping the colliding
-- table must still leave the audit table alone
CREATE TABLE public.test_heal_other (id int);
DROP TRIGGER pgaudix_audit_trigger ON public.test_heal_src;
UPDATE pgaudix.monitored_tables
SET source_oid = 'public.test_heal_other'::regclass
WHERE source_table = 'test_heal_src';
DROP TABLE public.test_heal_other;
SELECT to_regclass('public.test_heal_src_audit') IS NOT NULL AS audit_exists,
       (SELECT count(*) FROM pgaudix.monitored_tables WHERE source_table = 'test_heal_src') AS registry_rows;

-- Dropping the real source now that nothing ties it to the registration
-- (no trigger, no OID) keeps the registration and its audit table: it looks
-- exactly like an unrelated table carrying a stale registration's name
-- (test 68), and the audit table may hold history. disable() removes them.
DROP TABLE public.test_heal_src;
SELECT to_regclass('public.test_heal_src_audit') IS NOT NULL AS audit_exists,
       (SELECT count(*) FROM pgaudix.monitored_tables WHERE source_table = 'test_heal_src') AS registry_rows;
CREATE TABLE public.test_heal_src (id int);
SELECT pgaudix.disable('public.test_heal_src', drop_data := true);
SELECT to_regclass('public.test_heal_src_audit') IS NOT NULL AS audit_exists,
       (SELECT count(*) FROM pgaudix.monitored_tables WHERE source_table = 'test_heal_src') AS registry_rows;
DROP TABLE public.test_heal_src;
DROP TABLE IF EXISTS public.test_heal_other_audit;

-- ============================================================
-- Test 58: drop_cleanup() must only fall back to the name when the OID is stale
-- ============================================================
-- A registry row whose source_oid is still valid identifies its table by OID.
-- Dropping an unrelated table that merely carries the recorded name must not
-- drop the audit table nor delete the row.
CREATE TABLE public.test_dc_src (id int);
SELECT pgaudix.enable('public.test_dc_src');

-- Simulate stale names with a valid OID
UPDATE pgaudix.monitored_tables
SET source_table = 'test_dc_unrelated'
WHERE source_oid = 'public.test_dc_src'::regclass;

CREATE TABLE public.test_dc_unrelated (id int);
DROP TABLE public.test_dc_unrelated;

SELECT to_regclass('public.test_dc_src_audit') IS NOT NULL AS audit_exists,
       (SELECT count(*) FROM pgaudix.monitored_tables
        WHERE source_oid = 'public.test_dc_src'::regclass) AS registry_rows;
INSERT INTO public.test_dc_src VALUES (1);
SELECT audit_operation, id FROM public.test_dc_src_audit;

SELECT pgaudix.disable('public.test_dc_src', drop_data := true);
DROP TABLE public.test_dc_src;

-- ============================================================
-- Test 59: every TRUNCATE is recorded, also inside one top-level statement
-- ============================================================
-- The partition dedup must not swallow a second TRUNCATE of the same table
-- issued from a DO block or PL/pgSQL function (same statement_timestamp()).
CREATE TABLE public.test_trunc2 (id int);
SELECT pgaudix.enable('public.test_trunc2');

DO $$
BEGIN
    TRUNCATE public.test_trunc2;
    INSERT INTO public.test_trunc2 VALUES (1);
    TRUNCATE public.test_trunc2;
END;
$$;

SELECT audit_operation, count(*)
FROM public.test_trunc2_audit
GROUP BY audit_operation
ORDER BY audit_operation;

-- Partitioned root inside a DO block: one T per TRUNCATE statement, still
CREATE TABLE public.test_trunc2_part (id int, k int) PARTITION BY LIST (k);
CREATE TABLE public.test_trunc2_p1 PARTITION OF public.test_trunc2_part FOR VALUES IN (1);
CREATE TABLE public.test_trunc2_p2 PARTITION OF public.test_trunc2_part FOR VALUES IN (2);
SELECT pgaudix.enable('public.test_trunc2_part');

DO $$
BEGIN
    TRUNCATE public.test_trunc2_part;
    TRUNCATE public.test_trunc2_part;
END;
$$;

SELECT audit_operation, count(*)
FROM public.test_trunc2_part_audit
GROUP BY audit_operation
ORDER BY audit_operation;

-- Two-level tree: the intermediate partitioned table has no data of its
-- own but is truncated as a unit, and a statement naming a leaf together
-- with the root still counts as one TRUNCATE
CREATE TABLE public.test_trunc2_mid PARTITION OF public.test_trunc2_part
    FOR VALUES IN (3) PARTITION BY LIST (id);
CREATE TABLE public.test_trunc2_mid_a PARTITION OF public.test_trunc2_mid FOR VALUES IN (1);
CREATE TABLE public.test_trunc2_mid_b PARTITION OF public.test_trunc2_mid FOR VALUES IN (2);

SELECT tgrelid::regclass AS rel,
       CASE WHEN tgtype & 2 = 2 THEN 'BEFORE' ELSE 'AFTER' END AS timing
FROM pg_catalog.pg_trigger
WHERE tgname = 'pgaudix_truncate_trigger'
  AND tgrelid::regclass::text LIKE 'test_trunc2_%'
ORDER BY tgrelid::regclass::text;

TRUNCATE public.test_trunc2_part_audit;
TRUNCATE public.test_trunc2_part;                        -- root: 1
TRUNCATE public.test_trunc2_mid;                         -- intermediate: 1
TRUNCATE public.test_trunc2_mid_a;                       -- leaf: 1
TRUNCATE public.test_trunc2_p1, public.test_trunc2_part; -- leaf + root: 1
TRUNCATE public.test_trunc2_p1, public.test_trunc2_p2;   -- two leaves: 2
TRUNCATE public.test_trunc2_mid, public.test_trunc2_part; -- intermediate + root: 1
TRUNCATE public.test_trunc2_mid_a, public.test_trunc2_mid; -- leaf + intermediate: 1
DO $$
BEGIN
    TRUNCATE public.test_trunc2_mid;                       -- 1
    TRUNCATE public.test_trunc2_part;                      -- 1
    TRUNCATE public.test_trunc2_mid_b;                     -- 1
END;
$$;

SELECT audit_operation, count(*)
FROM public.test_trunc2_part_audit
GROUP BY audit_operation
ORDER BY audit_operation;
-- 11 T rows expected (1+1+1+1+2+1+1+3), no pending records left
SELECT count(*) AS pending_rows FROM pgaudix.truncate_pending;

SELECT pgaudix.disable('public.test_trunc2_part', drop_data := true);
DROP TABLE public.test_trunc2_part;
SELECT pgaudix.disable('public.test_trunc2', drop_data := true);
DROP TABLE public.test_trunc2;

-- ============================================================
-- Test 60: status() works in a read-only transaction
-- ============================================================
-- status() is the inspection tool; it must work on a hot standby or under
-- SET TRANSACTION READ ONLY even when the registry still has stale OIDs.
CREATE TABLE public.test_ro (id int);
SELECT pgaudix.enable('public.test_ro');

-- Simulate a stale audit OID left by a restore
UPDATE pgaudix.monitored_tables
SET audit_oid = 0
WHERE source_oid = 'public.test_ro'::regclass;

BEGIN;
SET TRANSACTION READ ONLY;
SELECT source_table, audit_table, audit_table_exists, dml_trigger_exists
FROM pgaudix.status()
WHERE source_table = 'test_ro';
COMMIT;

SELECT pgaudix.disable('public.test_ro', drop_data := true);
DROP TABLE public.test_ro;

-- ============================================================
-- Test 61: a partition created after enable() gets its TRUNCATE trigger
-- ============================================================
-- CREATE TABLE ... PARTITION OF is not an ALTER TABLE; the event trigger
-- must still reconcile the per-leaf triggers so a direct TRUNCATE of the
-- new partition is audited.
CREATE TABLE public.test_newpart (id int, k int) PARTITION BY LIST (k);
CREATE TABLE public.test_newpart_p1 PARTITION OF public.test_newpart FOR VALUES IN (1);
SELECT pgaudix.enable('public.test_newpart');
CREATE TABLE public.test_newpart_p2 PARTITION OF public.test_newpart FOR VALUES IN (2);

SELECT tgrelid::regclass AS leaf, tgenabled
FROM pg_catalog.pg_trigger
WHERE tgname = 'pgaudix_truncate_trigger'
  AND tgrelid IN ('public.test_newpart_p1'::regclass, 'public.test_newpart_p2'::regclass)
ORDER BY tgrelid::regclass::text;

TRUNCATE public.test_newpart_p2;
SELECT audit_operation, count(*)
FROM public.test_newpart_audit
GROUP BY audit_operation
ORDER BY audit_operation;

SELECT pgaudix.disable('public.test_newpart', drop_data := true);
DROP TABLE public.test_newpart;

-- ============================================================
-- Test 62: heal_registry() survives OIDs swapped between monitored tables
-- ============================================================
-- After a restore two monitored tables can hold each other's old OID (OID
-- reuse). Healing row by row under the UNIQUE on source_oid raised a
-- duplicate-key error and left the extension unusable in the database
-- (every enable()/disable()/DDL calls heal_registry()).
CREATE TABLE public.test_swap_a (id int);
CREATE TABLE public.test_swap_b (id int);
SELECT pgaudix.enable('public.test_swap_a');
SELECT pgaudix.enable('public.test_swap_b');

-- (a restored registry holds the old OIDs, which never collide with each
-- other; the simulation releases them first because of the UNIQUE)
UPDATE pgaudix.monitored_tables
SET source_oid = NULL
WHERE source_table IN ('test_swap_a', 'test_swap_b');
UPDATE pgaudix.monitored_tables
SET source_oid = CASE source_table
                     WHEN 'test_swap_a' THEN 'public.test_swap_b'::regclass
                     ELSE 'public.test_swap_a'::regclass
                 END
WHERE source_table IN ('test_swap_a', 'test_swap_b');

ALTER TABLE public.test_swap_a ADD COLUMN x int;

SELECT source_table,
       source_oid = ('public.' || source_table)::regclass AS source_healed
FROM pgaudix.monitored_tables
WHERE source_table IN ('test_swap_a', 'test_swap_b')
ORDER BY source_table;
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_swap_a_audit'
  AND column_name NOT LIKE 'audit\_%'
ORDER BY ordinal_position;

-- The extension is still usable afterwards
CREATE TABLE public.test_swap_c (id int);
SELECT pgaudix.enable('public.test_swap_c');
INSERT INTO public.test_swap_a VALUES (1, 10);
INSERT INTO public.test_swap_b VALUES (2);
SELECT 'a' AS t, audit_operation, id FROM public.test_swap_a_audit
UNION ALL
SELECT 'b', audit_operation, id FROM public.test_swap_b_audit
ORDER BY 1;

-- One-directional reuse: the registered OID of a source that was not
-- restored now belongs to another monitored table. That row is an orphan
-- (no table carries its name) and must not borrow the other table's OID:
-- DDL on the live table used to fail trying to rename the orphan's audit
-- table over the live audit table.
ALTER EVENT TRIGGER pgaudix_drop_cleanup DISABLE;
DROP TABLE public.test_swap_c;
ALTER EVENT TRIGGER pgaudix_drop_cleanup ENABLE ALWAYS;
-- (b's own row holds its pre-restore OID, which no longer exists)
UPDATE pgaudix.monitored_tables
SET source_oid = 4294967295
WHERE source_table = 'test_swap_b';
UPDATE pgaudix.monitored_tables
SET source_oid = 'public.test_swap_b'::regclass
WHERE source_table = 'test_swap_c';

ALTER TABLE public.test_swap_b ADD COLUMN y int;

SELECT source_table, audit_table_exists, dml_trigger_exists
FROM pgaudix.status()
WHERE source_table LIKE 'test\_swap\_%'
ORDER BY source_table;
SELECT source_table, source_oid IS NULL AS source_unknown
FROM pgaudix.monitored_tables
WHERE source_table = 'test_swap_c';
INSERT INTO public.test_swap_b VALUES (3, 30);
SELECT audit_operation, id, y FROM public.test_swap_b_audit ORDER BY audit_id;

-- A new table with the orphan's name is not registered over it (its audit
-- table may still hold history); disable() removes the orphan first
CREATE TABLE public.test_swap_c (id int);
DO $$
BEGIN
    PERFORM pgaudix.enable('public.test_swap_c');
    RAISE NOTICE 'ERROR: enable should have reported the orphan registration';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;
SELECT pgaudix.disable('public.test_swap_c', drop_data := true);
SELECT to_regclass('public.test_swap_c_audit') IS NULL AS orphan_audit_dropped,
       (SELECT count(*) FROM pgaudix.monitored_tables WHERE source_table = 'test_swap_c') AS registry_rows;
SELECT pgaudix.enable('public.test_swap_c');
INSERT INTO public.test_swap_c VALUES (1);
SELECT audit_operation, id FROM public.test_swap_c_audit;

SELECT pgaudix.disable('public.test_swap_a', drop_data := true);
SELECT pgaudix.disable('public.test_swap_b', drop_data := true);
SELECT pgaudix.disable('public.test_swap_c', drop_data := true);
DROP TABLE public.test_swap_a, public.test_swap_b, public.test_swap_c;

-- ============================================================
-- Test 63: heal_registry() must not bind a source to another table's audit log
-- ============================================================
-- When the registered audit name no longer resolves, a stored audit OID that
-- still exists was kept as long as the relation looked like an audit table.
-- Every audit table looks like one, so an OID reused by another monitored
-- table's audit table captured that table's log: the next DDL renamed it.
CREATE TABLE public.test_bind_c (id int);
CREATE TABLE public.test_bind_d (id int);
SELECT pgaudix.enable('public.test_bind_c');
SELECT pgaudix.enable('public.test_bind_d');
INSERT INTO public.test_bind_d VALUES (1);

DROP TABLE public.test_bind_c_audit;
UPDATE pgaudix.monitored_tables
SET audit_oid = 'public.test_bind_d_audit'::regclass
WHERE source_table = 'test_bind_c';

DO $$
BEGIN
    ALTER TABLE public.test_bind_c ADD COLUMN z int;
    RAISE NOTICE 'ERROR: DDL on a source without audit table should fail';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

SELECT to_regclass('public.test_bind_d_audit') IS NOT NULL AS d_audit_intact,
       to_regclass('public.test_bind_c_audit') IS NULL     AS c_audit_still_gone;
INSERT INTO public.test_bind_d VALUES (2);
SELECT audit_operation, id FROM public.test_bind_d_audit ORDER BY audit_id;
SELECT source_table, audit_table_exists
FROM pgaudix.status()
WHERE source_table LIKE 'test\_bind\_%'
ORDER BY source_table;

SELECT pgaudix.disable('public.test_bind_c');
SELECT pgaudix.disable('public.test_bind_d', drop_data := true);
DROP TABLE public.test_bind_c, public.test_bind_d;

-- ============================================================
-- Test 64: RENAME TABLE to a name whose audit name would overflow NAMEDATALEN
-- ============================================================
-- enable() rejects such names, but the DDL-sync pre-pass built the new audit
-- name in a `name` variable and let PostgreSQL truncate it silently.
CREATE TABLE public.test_ren_short (id int);
SELECT pgaudix.enable('public.test_ren_short');
INSERT INTO public.test_ren_short VALUES (1);

DO $$
BEGIN
    ALTER TABLE public.test_ren_short
        RENAME TO renamed_to_a_name_so_long_that_its_audit_name_overflows_63;
    RAISE NOTICE 'ERROR: rename to an overlong name should have been rejected';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: rename rejected: %', SQLERRM;
END;
$$;

-- Nothing changed: source keeps its name, audit table and trigger intact
SELECT source_table, audit_table, audit_table_exists, dml_trigger_exists
FROM pgaudix.status()
WHERE source_table LIKE 'test\_ren\_%' OR source_table LIKE 'renamed\_%';
INSERT INTO public.test_ren_short VALUES (2);
SELECT audit_operation, id FROM public.test_ren_short_audit ORDER BY audit_id;

-- A rename that still fits works as before (57 bytes + '_audit' = 63)
ALTER TABLE public.test_ren_short
    RENAME TO renamed_to_a_name_that_fits_exactly_in_sixty_three_bytes_;
SELECT source_table, audit_table
FROM pgaudix.status()
WHERE source_table LIKE 'renamed\_%';

SELECT pgaudix.disable('public.renamed_to_a_name_that_fits_exactly_in_sixty_three_bytes_',
                       drop_data := true);
DROP TABLE public.renamed_to_a_name_that_fits_exactly_in_sixty_three_bytes_;

-- ============================================================
-- Test 65: a partition trigger that will not fire is not counted
-- ============================================================
-- The root's TRUNCATE trigger counts the descendants' triggers that will
-- follow in the statement. One in state 'R' (ENABLE REPLICA) under the
-- default replication role does not fire, so the count never reached zero
-- and a later TRUNCATE of a sibling in the same transaction consumed the
-- leftover instead of being recorded. sync_partition_triggers() resets the
-- state on any DDL of the tree, so the state is forced through the catalog.
CREATE TABLE public.test_tgstate (id int) PARTITION BY RANGE (id);
CREATE TABLE public.test_tgstate_p1 PARTITION OF public.test_tgstate FOR VALUES FROM (0) TO (10);
CREATE TABLE public.test_tgstate_p2 PARTITION OF public.test_tgstate FOR VALUES FROM (10) TO (20);
SELECT pgaudix.enable('public.test_tgstate');

UPDATE pg_catalog.pg_trigger SET tgenabled = 'R'
WHERE tgrelid = 'public.test_tgstate_p1'::regclass AND tgname = 'pgaudix_truncate_trigger';

BEGIN;
    TRUNCATE public.test_tgstate;
    TRUNCATE public.test_tgstate_p2;
COMMIT;
SELECT audit_operation, count(*)
FROM public.test_tgstate_audit
GROUP BY audit_operation;
SELECT count(*) AS pending_rows FROM pgaudix.truncate_pending;

-- Under replica role only 'A' and 'R' triggers fire
UPDATE pg_catalog.pg_trigger SET tgenabled = 'O'
WHERE tgrelid = 'public.test_tgstate_p1'::regclass AND tgname = 'pgaudix_truncate_trigger';
SET session_replication_role = replica;
BEGIN;
    TRUNCATE public.test_tgstate;
    TRUNCATE public.test_tgstate_p2;
COMMIT;
RESET session_replication_role;
SELECT audit_operation, count(*)
FROM public.test_tgstate_audit
GROUP BY audit_operation;
SELECT count(*) AS pending_rows FROM pgaudix.truncate_pending;

SELECT pgaudix.disable('public.test_tgstate', drop_data := true);
DROP TABLE public.test_tgstate;

-- ============================================================
-- Test 66: a nested audit trigger survives a plan invalidated mid-execution
-- ============================================================
-- A user trigger on the audit table writes back to the source while the
-- source's cached audit plan is executing. If a relcache invalidation for
-- the source arrives in between (ANALYZE here; VACUUM or a concurrent DDL
-- in general), the nested trigger call found the entry stale and in use and
-- aborted the outer DML instead of preparing a private plan.
CREATE TABLE public.test_nested (id int, v text);
SELECT pgaudix.enable('public.test_nested');

CREATE FUNCTION public.test_nested_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.v = 'outer' THEN
        ANALYZE public.test_nested;
        INSERT INTO public.test_nested VALUES (NEW.id + 100, 'inner');
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER test_nested_tg AFTER INSERT ON public.test_nested_audit
    FOR EACH ROW EXECUTE FUNCTION public.test_nested_fn();

INSERT INTO public.test_nested VALUES (1, 'outer');
SELECT audit_operation, id, v FROM public.test_nested_audit ORDER BY audit_id;

-- The rebuilt cached plan keeps working afterwards, also after DDL
INSERT INTO public.test_nested VALUES (2, 'plain');
ALTER TABLE public.test_nested ADD COLUMN w int;
INSERT INTO public.test_nested VALUES (3, 'outer', 30);
SELECT audit_operation, id, v, w FROM public.test_nested_audit ORDER BY audit_id;

SELECT pgaudix.disable('public.test_nested', drop_data := true);
DROP TABLE public.test_nested;
DROP FUNCTION public.test_nested_fn();

-- ============================================================
-- Test 67: a dropped slot in the audit table must not swallow a new column
-- ============================================================
-- ADD-column detection treated a DROPPED audit attribute at the source
-- column's slot as "already mirrored": the new source column was never added
-- and every DML on the source failed (column missing in the audit table).
-- A dropped slot cannot be reused (attnums are never recycled), so the DDL
-- is refused with a message that says how to rebuild the audit table, and
-- the source keeps being audited as it was.
CREATE TABLE public.test_slot (id int, a int);
SELECT pgaudix.enable('public.test_slot');
INSERT INTO public.test_slot VALUES (1, 10);

-- A column added and dropped directly on the audit table (only a WARNING)
-- leaves a dropped attribute exactly where the next source column would land
ALTER TABLE public.test_slot_audit ADD COLUMN junk int;
ALTER TABLE public.test_slot_audit DROP COLUMN junk;

DO $$
BEGIN
    ALTER TABLE public.test_slot ADD COLUMN b int;
    RAISE NOTICE 'ERROR: the ALTER should have been refused (audit table out of alignment)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- The source is unchanged and still audited
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_slot'
ORDER BY ordinal_position;
INSERT INTO public.test_slot VALUES (2, 20);
UPDATE public.test_slot SET a = 21 WHERE id = 2;
SELECT audit_operation, id, a FROM public.test_slot_audit ORDER BY audit_id;

-- Rebuilding as the message says (keeping the old log aside) works
SELECT pgaudix.disable('public.test_slot');
ALTER TABLE public.test_slot_audit RENAME TO test_slot_audit_old;
SELECT pgaudix.enable('public.test_slot');
ALTER TABLE public.test_slot ADD COLUMN b int;
INSERT INTO public.test_slot VALUES (3, 30, 300);
SELECT audit_operation, id, a, b FROM public.test_slot_audit ORDER BY audit_id;
SELECT count(*) AS old_log_rows FROM public.test_slot_audit_old;

SELECT pgaudix.disable('public.test_slot', drop_data := true);
DROP TABLE public.test_slot, public.test_slot_audit_old;

-- ============================================================
-- Test 68: dropping an unrelated table must not remove an orphan's audit table
-- ============================================================
-- drop_cleanup() matched an orphan registration (source lost on a restore,
-- source_oid NULL) by name alone: creating and dropping an unrelated table
-- with that name dropped the orphan's audit table and its history, which
-- enable() refuses to replace precisely because it may hold history. Only a
-- table that carried the pgaudix DML trigger was a source.
CREATE TABLE public.test_orph (id int);
SELECT pgaudix.enable('public.test_orph');
INSERT INTO public.test_orph VALUES (1), (2);

-- Restore that left the source out: the registry row and the audit table
-- survive, the source does not
ALTER EVENT TRIGGER pgaudix_drop_cleanup DISABLE;
DROP TABLE public.test_orph;
ALTER EVENT TRIGGER pgaudix_drop_cleanup ENABLE ALWAYS;

-- An unrelated table takes the name and goes away again
CREATE TABLE public.test_orph (a text);
DROP TABLE public.test_orph;

SELECT to_regclass('public.test_orph_audit') IS NOT NULL AS orphan_audit_kept,
       (SELECT count(*) FROM pgaudix.monitored_tables
        WHERE source_table = 'test_orph') AS registry_rows;
SELECT audit_operation, id FROM public.test_orph_audit ORDER BY audit_id;
SELECT source_table, audit_table_exists, dml_trigger_exists
FROM pgaudix.status()
WHERE source_table = 'test_orph';

-- disable() is still the way to remove the orphan
CREATE TABLE public.test_orph (a text);
SELECT pgaudix.disable('public.test_orph', drop_data := true);
SELECT to_regclass('public.test_orph_audit') IS NULL AS orphan_audit_dropped,
       (SELECT count(*) FROM pgaudix.monitored_tables
        WHERE source_table = 'test_orph') AS registry_rows;

-- A real source drop still cleans up after itself
SELECT pgaudix.enable('public.test_orph');
DROP TABLE public.test_orph;
SELECT to_regclass('public.test_orph_audit') IS NULL AS audit_dropped,
       (SELECT count(*) FROM pgaudix.monitored_tables
        WHERE source_table = 'test_orph') AS registry_rows;

-- ============================================================
-- Test 69: RENAME onto an orphan's name must not hand the table to the orphan
-- ============================================================
-- heal_registry() re-bound a registration by name to any relation carrying
-- pgaudix_audit_trigger. Renaming a monitored table onto the name of an
-- orphan registration gave the orphan the live table's OID and turned the
-- live registration into the orphan: the trigger kept writing to the old
-- audit table while status() reported the orphan's. A relation is the source
-- of a registration only if its trigger names that registration's audit
-- table; the rename is refused while the stale registration exists.
CREATE TABLE public.test_ren_y (id int);
SELECT pgaudix.enable('public.test_ren_y');
INSERT INTO public.test_ren_y VALUES (1);
ALTER EVENT TRIGGER pgaudix_drop_cleanup DISABLE;
DROP TABLE public.test_ren_y;
ALTER EVENT TRIGGER pgaudix_drop_cleanup ENABLE ALWAYS;

CREATE TABLE public.test_ren_x (id int);
SELECT pgaudix.enable('public.test_ren_x');
INSERT INTO public.test_ren_x VALUES (10);

DO $$
BEGIN
    ALTER TABLE public.test_ren_x RENAME TO test_ren_y;
    RAISE NOTICE 'ERROR: the RENAME should have been refused (stale registration)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- Same when the orphan's audit table is already gone: the registry row alone
-- blocks the name
DROP TABLE public.test_ren_y_audit;
DO $$
BEGIN
    ALTER TABLE public.test_ren_x RENAME TO test_ren_y;
    RAISE NOTICE 'ERROR: the RENAME should have been refused (stale registration)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: %', SQLERRM;
END;
$$;

-- Nothing moved: x is still bound to its own table, y is still the orphan
SELECT source_table,
       source_oid = 'public.test_ren_x'::regclass AS bound_to_x,
       source_oid IS NULL AS orphan
FROM pgaudix.monitored_tables
WHERE source_table LIKE 'test\_ren\_%'
ORDER BY source_table;
INSERT INTO public.test_ren_x VALUES (11);
SELECT audit_operation, id FROM public.test_ren_x_audit ORDER BY audit_id;

-- Once the orphan is removed the rename goes through and is tracked
CREATE TABLE public.test_ren_y (id int);
SELECT pgaudix.disable('public.test_ren_y');
DROP TABLE public.test_ren_y;
ALTER TABLE public.test_ren_x RENAME TO test_ren_y;
INSERT INTO public.test_ren_y VALUES (12);
SELECT audit_operation, id FROM public.test_ren_y_audit ORDER BY audit_id;
SELECT source_table, audit_table, audit_table_exists, dml_trigger_exists
FROM pgaudix.status()
WHERE source_table LIKE 'test\_ren\_%'
ORDER BY source_table;

SELECT pgaudix.disable('public.test_ren_y', drop_data := true);
DROP TABLE public.test_ren_y;

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
