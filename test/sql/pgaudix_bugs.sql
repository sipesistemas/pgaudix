-- ============================================================================
-- pgaudix — bug-confirmation tests
-- ----------------------------------------------------------------------------
-- Each block exercises ONE confirmed defect and records a verdict in
-- _bug_results.confirmed:
--   TRUE  -> the buggy behavior was observed (bug is present)
--   FALSE -> behavior was correct (bug absent / fixed)
--   NULL  -> the test itself errored (inconclusive)
--
-- Run against a database with the extension installed:
--   psql -U postgres -d pgaudix_dev -f test/sql/pgaudix_bugs.sql
--
-- These tests are written to PASS-as-CONFIRMED on the current (buggy) code.
-- After a fix, the corresponding row should flip to "not present".
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgaudix;

DROP TABLE IF EXISTS _bug_results;
CREATE TEMP TABLE _bug_results (
    bug_no    int,
    severity  text,
    title     text,
    confirmed boolean,
    detail    text
);

-- ============================================================================
-- BUG #1 (HIGH) — ddl_sync() never resets its recursion guard, so only the
-- FIRST ALTER in a transaction is synced; later ALTERs are silently skipped,
-- which then breaks DML on the audited table.
-- Source: pgaudix--0.1.0.sql:341 (set), no reset before END (:561)
-- ============================================================================
CREATE TABLE public.bug1 (id int);
SELECT pgaudix.enable('public.bug1');

BEGIN;
    ALTER TABLE public.bug1 ADD COLUMN a int;   -- synced
    ALTER TABLE public.bug1 ADD COLUMN b int;   -- guard latched -> NOT synced
COMMIT;

DO $$
DECLARE
    has_a boolean;
    has_b boolean;
    dml_broke boolean := false;
    m text := '';
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema='public' AND table_name='bug1_audit' AND column_name='a') INTO has_a;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema='public' AND table_name='bug1_audit' AND column_name='b') INTO has_b;
    BEGIN
        INSERT INTO public.bug1 (id, a, b) VALUES (1, 2, 3);
    EXCEPTION WHEN OTHERS THEN
        dml_broke := true; m := SQLERRM;
    END;
    INSERT INTO _bug_results VALUES (1, 'HIGH',
        'guard never reset: 2nd ALTER in a txn not synced',
        (has_a AND NOT has_b),
        format('audit_has_a=%s audit_has_b=%s; subsequent INSERT broke=%s (%s)',
               has_a, has_b, dml_broke, m));
END $$;

-- ============================================================================
-- BUG #2 (HIGH) — ALTER TABLE ... SET SCHEMA cannot be performed on an audited
-- table. The rename pre-pass moves the registration to the new schema but never
-- moves the audit table itself; the column-diff loop then can't find the audit
-- table in the new schema and raises "audit table ... is missing", aborting the
-- whole SET SCHEMA. A legal DDL operation is blocked with a confusing internal
-- error (RENAME and ALTER SCHEMA RENAME are handled, but SET SCHEMA is not).
-- Source: pgaudix--0.1.0.sql:349-411 (rename pre-pass) + :455-458 (raise)
-- ============================================================================
CREATE SCHEMA bug2_s1;
CREATE SCHEMA bug2_s2;
CREATE TABLE bug2_s1.t (id int, v text);
SELECT pgaudix.enable('bug2_s1.t');

DO $$
DECLARE
    set_schema_failed boolean := false;
    m text := '';
    still_in_s1 boolean;
    audit_in_s1 boolean;
BEGIN
    BEGIN
        ALTER TABLE bug2_s1.t SET SCHEMA bug2_s2;   -- legal DDL, must succeed
    EXCEPTION WHEN OTHERS THEN
        set_schema_failed := true; m := SQLERRM;     -- rolls back to savepoint
    END;
    SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid
                   WHERE n.nspname='bug2_s1' AND c.relname='t') INTO still_in_s1;
    SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid
                   WHERE n.nspname='bug2_s1' AND c.relname='t_audit') INTO audit_in_s1;
    INSERT INTO _bug_results VALUES (2, 'HIGH',
        'SET SCHEMA on audited table is blocked with an internal error',
        set_schema_failed,
        format('SET SCHEMA raised=%s (%s); table_stuck_in_old_schema=%s audit_stuck_in_old_schema=%s',
               set_schema_failed, m, still_in_s1, audit_in_s1));
END $$;

-- ============================================================================
-- BUG #3 (MEDIUM) — ALTER COLUMN ... TYPE is replayed verbatim on the audit
-- table, which holds historical values the source no longer has; a perfectly
-- valid source DDL is aborted by an overflow on old audit data.
-- Source: pgaudix--0.1.0.sql:540-558 (TYPE CHANGE loop)
-- ============================================================================
CREATE TABLE public.bug3 (id int, amount numeric(10,2));
SELECT pgaudix.enable('public.bug3');
INSERT INTO public.bug3 VALUES (1, 9999.99);   -- audit keeps 9999.99
DELETE FROM public.bug3 WHERE id = 1;          -- source now empty of big value
INSERT INTO public.bug3 VALUES (2, 5.00);      -- live source data fits numeric(4,2)

DO $$
DECLARE
    aborted boolean := false;
    m text := '';
BEGIN
    BEGIN
        ALTER TABLE public.bug3 ALTER COLUMN amount TYPE numeric(4,2);  -- valid vs live data
    EXCEPTION WHEN OTHERS THEN
        aborted := true; m := SQLERRM;
    END;
    INSERT INTO _bug_results VALUES (3, 'MEDIUM',
        'TYPE change replayed on audit aborts valid source DDL',
        aborted,
        format('source ALTER aborted by audit-history overflow=%s (%s)', aborted, m));
END $$;

-- ============================================================================
-- BUG #4 (MEDIUM) — auditing silently stops under session_replication_role
-- = 'replica' (and ALTER ... DISABLE TRIGGER), yet status() still reports the
-- trigger as healthy because it ignores pg_trigger.tgenabled.
-- Source: status() pgaudix--0.1.0.sql:274-312; trigger created as ORIGIN
-- ============================================================================
CREATE TABLE public.bug4 (id int, v text);
SELECT pgaudix.enable('public.bug4');

SET session_replication_role = 'replica';
INSERT INTO public.bug4 VALUES (1, 'unaudited');   -- origin trigger suppressed
SET session_replication_role = 'origin';

DO $$
DECLARE
    audited int;
    reported_healthy boolean;
BEGIN
    SELECT count(*) FROM public.bug4_audit WHERE v='unaudited' INTO audited;
    SELECT dml_trigger_exists FROM pgaudix.status() WHERE source_table='bug4' INTO reported_healthy;
    INSERT INTO _bug_results VALUES (4, 'MEDIUM',
        'auditing stops under replica role, status() blind',
        (audited = 0 AND reported_healthy),
        format('rows_audited_under_replica=%s status.dml_trigger_exists=%s', audited, reported_healthy));
END $$;

-- ============================================================================
-- BUG #5 (MEDIUM) — TRUNCATE of an individual partition leaf produces no audit
-- row: the statement trigger lives only on the partitioned root.
-- Source: enable() relkind 'p' accepted (:84), truncate trigger on root (:196)
-- ============================================================================
CREATE TABLE public.bug5 (id int) PARTITION BY RANGE (id);
CREATE TABLE public.bug5_p1 PARTITION OF public.bug5 FOR VALUES FROM (0) TO (100);
SELECT pgaudix.enable('public.bug5');
INSERT INTO public.bug5 VALUES (1), (2);       -- audited via cloned row trigger
TRUNCATE public.bug5_p1;                       -- leaf truncate: removes rows

DO $$
DECLARE
    inserts int;
    truncates int;
BEGIN
    SELECT count(*) FROM public.bug5_audit WHERE audit_operation='I' INTO inserts;
    SELECT count(*) FROM public.bug5_audit WHERE audit_operation='T' INTO truncates;
    INSERT INTO _bug_results VALUES (5, 'MEDIUM',
        'partition-leaf TRUNCATE not audited',
        (inserts = 2 AND truncates = 0),
        format('insert_rows=%s truncate_rows_after_leaf_truncate=%s', inserts, truncates));
END $$;

-- ============================================================================
-- BUG #6 (MEDIUM) — DROP COLUMN sync permanently destroys all historical audit
-- data for that column, defeating the audit trail (compliance concern).
-- Source: pgaudix--0.1.0.sql:496-513 (DROPPED-columns loop)
-- ============================================================================
CREATE TABLE public.bug6 (id int, ssn text);
SELECT pgaudix.enable('public.bug6');
INSERT INTO public.bug6 VALUES (1, '111-22-3333');
UPDATE public.bug6 SET ssn = '999-88-7777' WHERE id = 1;

DO $$
DECLARE
    history_before int;
    col_after boolean;
BEGIN
    SELECT count(*) FROM public.bug6_audit WHERE ssn IS NOT NULL INTO history_before;
    ALTER TABLE public.bug6 DROP COLUMN ssn;     -- ddl_sync drops it from audit too
    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema='public' AND table_name='bug6_audit' AND column_name='ssn') INTO col_after;
    -- NOTE: #6 is an ACCEPTED design decision (audit mirrors the source schema,
    -- including column drops), not fixed. This row stays CONFIRMED on purpose.
    INSERT INTO _bug_results VALUES (6, 'INFO/design',
        'DROP COLUMN drops audit column (accepted: by design, not fixed)',
        (history_before > 0 AND NOT col_after),
        format('audit_rows_with_ssn_before=%s ssn_column_in_audit_after=%s', history_before, col_after));
END $$;

-- ============================================================================
-- BUG #7 (LOW) — a source column named like an audit metadata column makes
-- enable() fail with an opaque "specified more than once" error instead of a
-- clear pgaudix diagnostic.
-- Source: enable() CREATE TABLE :147-159
-- ============================================================================
CREATE TABLE public.bug7 (id int, audit_user text);

DO $$
DECLARE
    failed boolean := false;
    m text := '';
BEGIN
    BEGIN
        PERFORM pgaudix.enable('public.bug7');
    EXCEPTION WHEN OTHERS THEN
        failed := true; m := SQLERRM;
    END;
    -- bug = enable fails with a NON-pgaudix (opaque) error. After the fix enable
    -- still rejects the collision, but with a clear 'pgaudix:' diagnostic.
    INSERT INTO _bug_results VALUES (7, 'LOW',
        'metadata-name column collision breaks enable() with opaque error',
        (failed AND m NOT LIKE 'pgaudix:%'),
        format('enable failed=%s (%s)', failed, m));
END $$;

-- ============================================================================
-- BUG #8 (LOW) — the audit-name length guard counts CHARACTERS, not BYTES, so a
-- multibyte source name passes the check yet the audit name is silently
-- truncated past NAMEDATALEN (63 bytes).
-- Source: enable() :94-100
-- ============================================================================
DO $$
DECLARE
    src       text := repeat(chr(225), 30);   -- 30 'a-acute' chars = 60 bytes
    intended  text := src || '_audit';        -- 66 bytes
    rel       regclass;
    stored    name;
    enable_ok boolean := false;
    m text := '';
    is_bug boolean;
    det text;
BEGIN
    EXECUTE format('CREATE TABLE public.%I (id int)', src);
    rel := format('public.%I', src)::regclass;
    BEGIN
        PERFORM pgaudix.enable(rel);            -- char-counting guard passed; byte guard must reject
        enable_ok := true;
    EXCEPTION WHEN OTHERS THEN
        m := SQLERRM;
    END;
    IF enable_ok THEN
        SELECT audit_table INTO stored FROM pgaudix.monitored_tables WHERE source_oid = rel;
        -- bug = enable succeeded and the audit name was silently truncated past 63 bytes
        is_bug := (octet_length(intended) > 63 AND octet_length(stored::text) < octet_length(intended));
        det := format('enable succeeded; intended_audit_bytes=%s actual_audit_bytes=%s (silent truncation=%s)',
                      octet_length(intended), octet_length(stored::text), is_bug);
        EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', stored);
    ELSE
        -- fixed behavior: the byte-aware guard rejects the overlong name up front
        is_bug := false;
        det := format('enable correctly rejected overlong name: %s', m);
    END IF;
    EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', src);
    INSERT INTO _bug_results VALUES (8, 'LOW',
        'name-length guard counts chars not bytes (silent truncation)', is_bug, det);
END $$;

-- ============================================================================
-- BUG #9 (LOW) — the attnum-alignment strategy replays the source's entire
-- historical attnum span as physical gap-filler columns, so enable() can hit
-- the 1600-column limit and fail even when the SOURCE has very few live columns.
-- Source: enable() gap-filler build :126-159
-- ============================================================================
DO $$
DECLARE
    cols   text;
    drops  text;
    failed boolean := false;
    m text := '';
    live_cols int;
BEGIN
    -- source: id + c1..c1595 (1596 columns, max attnum 1596) -- within the limit
    SELECT string_agg(format('c%s int', g), ', ') FROM generate_series(1, 1595) g INTO cols;
    EXECUTE format('CREATE TABLE public.bug9 (id int, %s)', cols);
    -- drop almost all, leaving only id + c1595 live (2 live cols, max attnum still 1596)
    SELECT string_agg(format('DROP COLUMN c%s', g), ', ') FROM generate_series(1, 1594) g INTO drops;
    EXECUTE format('ALTER TABLE public.bug9 %s', drops);
    SELECT count(*) FROM pg_attribute
        WHERE attrelid='public.bug9'::regclass AND attnum>0 AND NOT attisdropped INTO live_cols;
    BEGIN
        PERFORM pgaudix.enable('public.bug9');
    EXCEPTION WHEN OTHERS THEN
        failed := true; m := SQLERRM;
    END;
    -- bug = enable fails with a NON-pgaudix (opaque "at most 1600 columns") error.
    -- After the fix enable still rejects, but with a clear 'pgaudix:' diagnostic.
    INSERT INTO _bug_results VALUES (9, 'LOW',
        'gap-filler replay can exhaust the 1600-column limit',
        (failed AND m NOT LIKE 'pgaudix:%'),
        format('source_live_columns=%s enable_failed=%s (%s)', live_cols, failed, m));
    EXECUTE 'DROP TABLE IF EXISTS public.bug9 CASCADE';
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _bug_results VALUES (9, 'LOW',
        'gap-filler replay can exhaust the 1600-column limit',
        NULL, 'test error: ' || SQLERRM);
END $$;

-- ============================================================================
-- BUG #10 (LOW) — an UNLOGGED source is mirrored by a LOGGED (permanent) audit
-- table; after crash recovery the source is truncated but the audit asserts
-- inserts that no longer exist (durability mismatch).
-- Source: enable() CREATE TABLE :147-159
-- ============================================================================
CREATE UNLOGGED TABLE public.bug10 (id int);
SELECT pgaudix.enable('public.bug10');

DO $$
DECLARE
    src_p   "char";
    audit_p "char";
BEGIN
    SELECT relpersistence FROM pg_class WHERE oid='public.bug10'::regclass INTO src_p;
    SELECT relpersistence FROM pg_class WHERE oid='public.bug10_audit'::regclass INTO audit_p;
    INSERT INTO _bug_results VALUES (10, 'LOW',
        'UNLOGGED source mirrored by LOGGED audit (durability mismatch)',
        (src_p = 'u' AND audit_p = 'p'),
        format('source_relpersistence=%s audit_relpersistence=%s', src_p, audit_p));
END $$;

-- ============================================================================
-- RESULTS
-- ============================================================================
SELECT bug_no AS "#",
       severity AS sev,
       CASE WHEN confirmed IS NULL THEN 'INCONCLUSIVE'
            WHEN confirmed THEN 'CONFIRMED'
            ELSE 'not present' END AS status,
       title,
       detail
FROM _bug_results
ORDER BY bug_no;

SELECT count(*) FILTER (WHERE confirmed) AS bugs_confirmed,
       count(*) FILTER (WHERE confirmed IS FALSE) AS not_present,
       count(*) FILTER (WHERE confirmed IS NULL) AS inconclusive,
       count(*) AS total_tests
FROM _bug_results;

-- ============================================================================
-- Cleanup
-- ============================================================================
DROP TABLE IF EXISTS public.bug1 CASCADE;
DROP TABLE IF EXISTS public.bug1_audit CASCADE;
DROP TABLE IF EXISTS bug2_s2.t CASCADE;
DROP TABLE IF EXISTS bug2_s1.t_audit CASCADE;
DROP SCHEMA IF EXISTS bug2_s1 CASCADE;
DROP SCHEMA IF EXISTS bug2_s2 CASCADE;
DROP TABLE IF EXISTS public.bug3 CASCADE;
DROP TABLE IF EXISTS public.bug3_audit CASCADE;
DROP TABLE IF EXISTS public.bug4 CASCADE;
DROP TABLE IF EXISTS public.bug4_audit CASCADE;
DROP TABLE IF EXISTS public.bug5 CASCADE;
DROP TABLE IF EXISTS public.bug5_audit CASCADE;
DROP TABLE IF EXISTS public.bug6 CASCADE;
DROP TABLE IF EXISTS public.bug6_audit CASCADE;
DROP TABLE IF EXISTS public.bug7 CASCADE;
DROP TABLE IF EXISTS public.bug7_audit CASCADE;
DROP TABLE IF EXISTS public.bug10 CASCADE;
DROP TABLE IF EXISTS public.bug10_audit CASCADE;
-- clear any leftover registrations from broken-state tables
DELETE FROM pgaudix.monitored_tables
WHERE source_table IN ('bug1','t','bug3','bug4','bug5','bug6','bug7','bug9','bug10')
   OR source_schema LIKE 'bug2_%';
