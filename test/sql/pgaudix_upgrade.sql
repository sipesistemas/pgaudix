-- pgaudix upgrade path: 1.0.0 -> 1.1.0

CREATE EXTENSION pgaudix VERSION '1.0.0';

CREATE TABLE public.test_upg (id int PRIMARY KEY, name text);
SELECT pgaudix.enable('public.test_upg');
INSERT INTO public.test_upg VALUES (1, 'before');

CREATE ROLE pgaudix_test_upg;
GRANT USAGE ON SCHEMA pgaudix TO pgaudix_test_upg;
GRANT EXECUTE ON FUNCTION pgaudix.enable(regclass) TO pgaudix_test_upg;

ALTER EXTENSION pgaudix UPDATE TO '1.1.0';
SELECT extversion FROM pg_extension WHERE extname = 'pgaudix';

-- Existing registrations keep following their source's schema
SELECT source_table, audit_schema, audit_table, audit_schema_pinned
FROM pgaudix.monitored_tables;
CREATE SCHEMA test_upg_src;
ALTER TABLE public.test_upg SET SCHEMA test_upg_src;
INSERT INTO test_upg_src.test_upg VALUES (2, 'after');
SELECT audit_operation, id, name FROM test_upg_src.test_upg_audit ORDER BY audit_id;

-- The GRANT on the 1.0.0 signature survives; the new one is not PUBLIC
SELECT has_function_privilege('pgaudix_test_upg', 'pgaudix.enable(regclass)', 'EXECUTE') AS one_arg,
       has_function_privilege('pgaudix_test_upg', 'pgaudix.enable(regclass, name)', 'EXECUTE') AS two_args;

-- The new signature works on an upgraded install
CREATE SCHEMA test_upg_aud;
CREATE TABLE public.test_upg2 (id int);
SELECT pgaudix.enable('public.test_upg2', audit_schema := 'test_upg_aud');
INSERT INTO public.test_upg2 VALUES (1);
SELECT audit_operation, id FROM test_upg_aud.test_upg2_audit;

-- The upgraded catalog matches a fresh 1.1.0 install
REVOKE EXECUTE ON FUNCTION pgaudix.enable(regclass) FROM pgaudix_test_upg;
CREATE TEMP TABLE upgraded AS
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
       md5(pg_get_functiondef(p.oid)) AS def, p.proacl::text AS acl
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgaudix' AND p.prokind = 'f';
CREATE TEMP TABLE upgraded_cols AS
SELECT attname, format_type(atttypid, atttypmod) AS type, attnotnull,
       pg_get_expr(d.adbin, d.adrelid) AS default_expr
FROM pg_attribute a
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE a.attrelid = 'pgaudix.monitored_tables'::regclass AND a.attnum > 0 AND NOT a.attisdropped;

SELECT pgaudix.disable('test_upg_src.test_upg', drop_data := true);
SELECT pgaudix.disable('public.test_upg2', drop_data := true);
DROP TABLE test_upg_src.test_upg, public.test_upg2;
DROP SCHEMA test_upg_src, test_upg_aud;
REVOKE ALL ON SCHEMA pgaudix FROM pgaudix_test_upg;
DROP EXTENSION pgaudix;
DROP ROLE pgaudix_test_upg;

CREATE EXTENSION pgaudix;
SELECT extversion FROM pg_extension WHERE extname = 'pgaudix';

SELECT coalesce(u.proname, f.proname) AS proname, coalesce(u.args, f.args) AS args,
       u.def IS NOT NULL AS in_upgraded, f.def IS NOT NULL AS in_fresh,
       u.def = f.def AS same_definition, u.acl IS NOT DISTINCT FROM f.acl AS same_acl
FROM upgraded u
FULL JOIN (
    SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
           md5(pg_get_functiondef(p.oid)) AS def, p.proacl::text AS acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgaudix' AND p.prokind = 'f'
) f USING (proname, args)
WHERE u.def IS DISTINCT FROM f.def OR u.acl IS DISTINCT FROM f.acl;

SELECT * FROM upgraded_cols
EXCEPT
SELECT attname, format_type(atttypid, atttypmod), attnotnull, pg_get_expr(d.adbin, d.adrelid)
FROM pg_attribute a
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE a.attrelid = 'pgaudix.monitored_tables'::regclass AND a.attnum > 0 AND NOT a.attisdropped;

DROP EXTENSION pgaudix;
