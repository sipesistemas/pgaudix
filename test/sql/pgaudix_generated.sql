-- pgaudix regression tests: virtual generated columns (PostgreSQL 18+ only)
-- Selected by the Makefile when pg_config reports version 18 or later.
CREATE EXTENSION pgaudix;

-- ============================================================
-- Virtual generated columns are not mirrored
-- ============================================================
-- A virtual column has no stored value, so the trigger would only ever see
-- NULL. It is left out of the audit table; its value can be derived from the
-- audited columns at any time. Stored generated columns are mirrored.
CREATE TABLE public.test_virtual (
    id int,
    a  int,
    v  int GENERATED ALWAYS AS (a * 2) VIRTUAL,
    s  int GENERATED ALWAYS AS (a * 3) STORED
);
SELECT pgaudix.enable('public.test_virtual');

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_virtual_audit'
  AND column_name NOT LIKE 'audit\_%'
ORDER BY ordinal_position;

INSERT INTO public.test_virtual (id, a) VALUES (1, 5);
UPDATE public.test_virtual SET a = 6;

-- A virtual column added later must keep the attnum alignment of the
-- columns that follow it
ALTER TABLE public.test_virtual
    ADD COLUMN w int GENERATED ALWAYS AS (a + 1) VIRTUAL,
    ADD COLUMN b text;
INSERT INTO public.test_virtual (id, a, b) VALUES (2, 7, 'x');
ALTER TABLE public.test_virtual RENAME COLUMN b TO b2;
ALTER TABLE public.test_virtual DROP COLUMN w;
ALTER TABLE public.test_virtual ADD COLUMN c int;
INSERT INTO public.test_virtual (id, a, b2, c) VALUES (3, 8, 'y', 9);

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'test_virtual_audit'
  AND column_name NOT LIKE 'audit\_%'
ORDER BY ordinal_position;

SELECT audit_operation, id, a, s, b2, c
FROM public.test_virtual_audit
ORDER BY audit_id;

-- The virtual value is derivable from the audited data
SELECT id, a * 2 AS v
FROM public.test_virtual_audit
WHERE audit_operation = 'U';

SELECT pgaudix.disable('public.test_virtual', drop_data := true);
DROP TABLE public.test_virtual;
DROP EXTENSION pgaudix;
