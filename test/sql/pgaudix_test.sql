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

-- Trigger should be gone
SELECT count(*) FROM pg_trigger
WHERE tgname = 'pgaudix_audit_trigger'
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
-- Test 11: Permission check for SECURITY DEFINER APIs
-- ============================================================
CREATE FUNCTION public.capture_enable_error(target_table regclass)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pgaudix.enable(target_table);
    RETURN NULL;
EXCEPTION
    WHEN OTHERS THEN
        RETURN SQLERRM;
END;
$$;

CREATE TABLE public.test_no_trigger_priv (id int);
CREATE ROLE pgaudix_no_trigger_role;
GRANT USAGE ON SCHEMA public TO pgaudix_no_trigger_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.test_no_trigger_priv TO pgaudix_no_trigger_role;

SET SESSION AUTHORIZATION pgaudix_no_trigger_role;
DO $$
DECLARE
    v_err text;
BEGIN
    v_err := public.capture_enable_error('public.test_no_trigger_priv'::regclass);
    IF NOT (
        v_err LIKE '%permission denied%'
        AND
        v_err LIKE '%test_no_trigger_priv%'
    ) THEN
        RAISE EXCEPTION 'expected permission denied for test_no_trigger_priv';
    END IF;
END;
$$;
RESET SESSION AUTHORIZATION;

SELECT count(*) FROM pgaudix.status()
WHERE source_schema = 'public' AND source_table = 'test_no_trigger_priv';

SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'test_no_trigger_priv_audit';

-- ============================================================
-- Test 12: Reject protected schemas
-- ============================================================
CREATE TABLE pgaudix.test_internal_table (id int);

DO $$
DECLARE
    v_err text;
BEGIN
    v_err := public.capture_enable_error('pgaudix.test_internal_table'::regclass);
    IF NOT (
        v_err LIKE '%auditing is not allowed for schema%'
        AND
        v_err LIKE '%pgaudix%'
    ) THEN
        RAISE EXCEPTION 'expected schema protection error for pgaudix schema';
    END IF;
END;
$$;

SELECT count(*) FROM pgaudix.status()
WHERE source_schema = 'pgaudix' AND source_table = 'test_internal_table';

SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'pgaudix' AND table_name = 'test_internal_table_audit';

DROP TABLE pgaudix.test_internal_table;
DROP FUNCTION public.capture_enable_error(regclass);

-- ============================================================
-- Cleanup
-- ============================================================
DROP OWNED BY pgaudix_no_trigger_role;
DROP TABLE public.test_no_trigger_priv;
DROP ROLE pgaudix_no_trigger_role;
DROP TABLE public.test_orders;
DROP EXTENSION pgaudix;
