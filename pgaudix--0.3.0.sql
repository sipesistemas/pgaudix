-- pgaudix: automatic table auditing with column mirroring and DDL sync
-- Version 0.3.0
--
-- This is the full install script for a fresh `CREATE EXTENSION pgaudix`.
-- It must always reflect the COMPLETE schema of version 0.3.0.

\echo Use "CREATE EXTENSION pgaudix" to load this file. \quit

-- ============================================================
-- Configuration tables
-- ============================================================

CREATE TABLE pgaudix.monitored_tables (
    id              serial PRIMARY KEY,
    source_oid      oid NOT NULL UNIQUE,
    source_schema   name NOT NULL,
    source_table    name NOT NULL,
    audit_schema    name NOT NULL,
    audit_table     name NOT NULL,
    audit_oid       oid,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_schema, source_table)
);

-- Dump the registry contents with pg_dump (extension member tables are skipped
-- otherwise). OIDs change on a logical restore; heal_registry() re-resolves them.
SELECT pg_catalog.pg_extension_config_dump('pgaudix.monitored_tables', '');
SELECT pg_catalog.pg_extension_config_dump('pgaudix.monitored_tables_id_seq', '');

-- DDL-sync recursion guard. ddl_sync() and enable() run ALTER TABLE on audit
-- tables, which fires ddl_sync() again; while a backend has a row here the
-- nested invocation returns immediately. A table (owned by the extension
-- owner, no PUBLIC access) is used instead of a custom GUC because any role
-- can SET a custom GUC and silently disable the sync. Rows are always deleted
-- before the statement ends, and a rollback removes them on error.
CREATE TABLE pgaudix.ddl_guard (
    pid integer PRIMARY KEY
);

-- ============================================================
-- heal_registry(): re-resolve stale OIDs after pg_dump/restore
-- ============================================================
-- source_oid / audit_oid are the authoritative keys at runtime, but they are
-- invalid after a logical dump/restore. For every row whose OID no longer
-- exists, look the table up again by (schema, name). The source is only
-- re-bound if it still carries the pgaudix DML trigger, so an unrelated table
-- that reused the name of a dropped source is never captured.

CREATE FUNCTION pgaudix.heal_registry()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
DECLARE
    mon         record;
    v_src_oid   oid;
    v_audit_oid oid;
BEGIN
    FOR mon IN
        SELECT mt.*
        FROM pgaudix.monitored_tables mt
        WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid = mt.source_oid)
           OR mt.audit_oid IS NULL
           OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid = mt.audit_oid)
    LOOP
        SELECT c.oid INTO v_src_oid
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = mon.source_schema AND c.relname = mon.source_table
          AND EXISTS (
              SELECT 1 FROM pg_catalog.pg_trigger t
              WHERE t.tgrelid = c.oid
                AND t.tgname = 'pgaudix_audit_trigger'
                AND NOT t.tgisinternal
          );

        SELECT c.oid INTO v_audit_oid
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = mon.audit_schema AND c.relname = mon.audit_table;

        IF (v_src_oid IS NOT NULL AND v_src_oid <> mon.source_oid)
           OR v_audit_oid IS DISTINCT FROM mon.audit_oid THEN
            UPDATE pgaudix.monitored_tables
            SET source_oid = COALESCE(v_src_oid, source_oid),
                audit_oid  = v_audit_oid
            WHERE id = mon.id;
        END IF;
    END LOOP;
END;
$func$;

-- ============================================================
-- C trigger function declaration
-- ============================================================

CREATE FUNCTION pgaudix.audit_trigger()
    RETURNS trigger
    AS 'pgaudix', 'pgaudix_trigger'
    LANGUAGE c
    SECURITY DEFINER
    SET search_path = pgaudix, pg_catalog, pg_temp;

-- ============================================================
-- PL/pgSQL TRUNCATE trigger function (M1)
-- ============================================================

CREATE FUNCTION pgaudix.truncate_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
BEGIN
    -- TRUNCATE of a partitioned root fires this statement trigger on the root
    -- and again on every partition (each leaf carries its own copy so that a
    -- direct TRUNCATE of a partition is audited). All of those run inside one
    -- statement, so statement_timestamp() is the same for them: write the T
    -- row only if this statement has not written one to this audit table yet.
    -- audit_timestamp defaults to clock_timestamp(), which is never earlier
    -- than the statement start, and earlier statements in the same
    -- transaction have an earlier statement_timestamp().
    EXECUTE format(
        'INSERT INTO %I.%I (audit_operation) '
        'SELECT ''T'' WHERE NOT EXISTS ('
        '    SELECT 1 FROM %I.%I '
        '    WHERE audit_operation = ''T'' '
        '      AND audit_txid = txid_current() '
        '      AND audit_timestamp >= statement_timestamp())',
        TG_ARGV[0], TG_ARGV[1], TG_ARGV[0], TG_ARGV[1]
    );
    RETURN NULL;
END;
$func$;

-- ============================================================
-- audit_type(): the type an audit column uses for a source column
-- ============================================================
-- Domains carry NOT NULL / CHECK constraints with the type name, and audit
-- rows for TRUNCATE (and dropped history) hold NULLs, so a mirrored column
-- uses the domain's base type instead (resolved through nested domains,
-- keeping the base typmod, e.g. numeric(8,2)).

CREATE FUNCTION pgaudix.audit_type(p_typid oid, p_typmod integer)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
    WITH RECURSIVE walk(typid, typmod, depth) AS (
        SELECT p_typid, p_typmod, 0
        UNION ALL
        SELECT t.typbasetype, t.typtypmod, w.depth + 1
        FROM walk w
        JOIN pg_catalog.pg_type t ON t.oid = w.typid
        WHERE t.typtype = 'd' AND w.depth < 32
    )
    SELECT format_type(w.typid, w.typmod)
    FROM walk w
    ORDER BY w.depth DESC
    LIMIT 1;
$func$;

-- ============================================================
-- Caller identification and ownership check
-- ============================================================
-- Inside a SECURITY DEFINER function current_user is already the function
-- owner, but the "role" GUC still reflects the caller's SET ROLE, so the
-- effective invoking role is that GUC when set, else session_user.

CREATE FUNCTION pgaudix.invoker()
RETURNS name
LANGUAGE sql
STABLE
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
    SELECT CASE
        WHEN current_setting('role', true) IS NULL
          OR current_setting('role', true) IN ('', 'none')
        THEN session_user
        ELSE current_setting('role', true)::name
    END;
$func$;

-- enable()/disable() run as the extension owner (superuser), so they must
-- check by themselves that the caller is allowed to manage the target table:
-- a superuser, or the table owner (directly or through role membership).
CREATE FUNCTION pgaudix.check_table_owner(target_table regclass)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
DECLARE
    v_invoker name := pgaudix.invoker();
    v_owner   oid;
BEGIN
    SELECT c.relowner INTO v_owner
    FROM pg_catalog.pg_class c
    WHERE c.oid = target_table;

    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'pgaudix: relation % does not exist', target_table::oid;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = v_invoker AND r.rolsuper)
       OR pg_catalog.pg_has_role(v_invoker, v_owner, 'USAGE') THEN
        RETURN;
    END IF;

    RAISE EXCEPTION 'pgaudix: must be owner of table % to manage its auditing', target_table
        USING ERRCODE = 'insufficient_privilege';
END;
$func$;

-- ============================================================
-- sync_partition_triggers(): reconcile per-leaf TRUNCATE triggers
-- ============================================================
-- A statement-level TRUNCATE trigger on a partitioned root does not fire when
-- a partition is truncated directly, so every leaf of a monitored partitioned
-- root carries its own pgaudix_truncate_trigger. Leaves come and go (ATTACH,
-- DETACH) and the audit table can be renamed, so instead of tracking them
-- one by one this function makes the catalog match the registry:
--   * every current leaf gets the trigger with the current audit name;
--   * any pgaudix_truncate_trigger on a table that is neither a monitored
--     source nor a leaf of a monitored partitioned root is dropped.

CREATE FUNCTION pgaudix.sync_partition_triggers()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
DECLARE
    rec       record;
    v_tgargs  bytea;
BEGIN
    -- Ensure every leaf of every monitored partitioned root has the trigger
    FOR rec IN
        SELECT pt.relid AS leaf, mt.audit_schema, mt.audit_table
        FROM pgaudix.monitored_tables mt
        JOIN pg_catalog.pg_class root ON root.oid = mt.source_oid AND root.relkind = 'p'
        CROSS JOIN LATERAL pg_catalog.pg_partition_tree(mt.source_oid) pt
        JOIN pg_catalog.pg_class c ON c.oid = pt.relid
        WHERE pt.isleaf AND c.relkind = 'r'
        ORDER BY pt.relid
    LOOP
        -- pg_trigger.tgargs stores each argument as a NUL-terminated string
        v_tgargs := convert_to(rec.audit_schema::text, getdatabaseencoding()) || '\x00'::bytea
                 || convert_to(rec.audit_table::text,  getdatabaseencoding()) || '\x00'::bytea;

        CONTINUE WHEN EXISTS (
            SELECT 1 FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid = rec.leaf
              AND t.tgname = 'pgaudix_truncate_trigger'
              AND NOT t.tgisinternal
              AND t.tgenabled = 'A'
              AND t.tgargs = v_tgargs
        );

        EXECUTE format(
            'DROP TRIGGER IF EXISTS pgaudix_truncate_trigger ON %s',
            rec.leaf::regclass
        );
        EXECUTE format(
            'CREATE TRIGGER pgaudix_truncate_trigger '
            'AFTER TRUNCATE ON %s '
            'FOR EACH STATEMENT EXECUTE FUNCTION pgaudix.truncate_trigger(%L, %L)',
            rec.leaf::regclass, rec.audit_schema, rec.audit_table
        );
        EXECUTE format(
            'ALTER TABLE %s ENABLE ALWAYS TRIGGER pgaudix_truncate_trigger',
            rec.leaf::regclass
        );
    END LOOP;

    -- Drop the trigger from tables that no longer belong to a monitored tree
    FOR rec IN
        SELECT t.tgrelid
        FROM pg_catalog.pg_trigger t
        WHERE t.tgname = 'pgaudix_truncate_trigger'
          AND NOT t.tgisinternal
          AND NOT EXISTS (
              SELECT 1 FROM pgaudix.monitored_tables mt
              WHERE mt.source_oid = t.tgrelid
          )
          AND NOT EXISTS (
              SELECT 1
              FROM pgaudix.monitored_tables mt
              JOIN pg_catalog.pg_class root ON root.oid = mt.source_oid AND root.relkind = 'p'
              CROSS JOIN LATERAL pg_catalog.pg_partition_tree(mt.source_oid) pt
              WHERE pt.relid = t.tgrelid
          )
        ORDER BY t.tgrelid
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS pgaudix_truncate_trigger ON %s',
            rec.tgrelid::regclass
        );
    END LOOP;
END;
$func$;

-- ============================================================
-- enable(target_table regclass)
-- ============================================================

CREATE FUNCTION pgaudix.enable(target_table regclass)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
DECLARE
    v_schema    name;
    v_table     name;
    v_audit     name;
    v_audit_fqn text;
    v_audit_tgarg text;
    v_cols      text := '';
    v_relkind   "char";
    v_relpersist "char";
    v_max_attnum int;
    v_audit_oid oid;
    v_gap       name;
    v_gap_cols  name[] := '{}';
    rec         record;
BEGIN
    -- The caller must own the table (or be a superuser)
    PERFORM pgaudix.check_table_owner(target_table);

    -- Serialize concurrent enable() calls (H3)
    LOCK TABLE pgaudix.monitored_tables IN EXCLUSIVE MODE;

    -- Re-bind registry rows whose OIDs went stale (pg_dump/restore)
    PERFORM pgaudix.heal_registry();

    -- Resolve schema, table name, relkind and persistence
    SELECT n.nspname, c.relname, c.relkind, c.relpersistence
    INTO v_schema, v_table, v_relkind, v_relpersist
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.oid = target_table;

    -- Reject views, materialized views, foreign tables, indexes, sequences, etc. (A5)
    -- Only ordinary tables ('r') and partitioned tables ('p') are supported.
    IF v_relkind NOT IN ('r', 'p') THEN
        RAISE EXCEPTION 'pgaudix: %.% is not a regular or partitioned table (relkind=%)',
            v_schema, v_table, v_relkind;
    END IF;

    -- Reject system catalogs to avoid catastrophic side effects
    IF v_schema IN ('pg_catalog', 'information_schema') OR v_schema LIKE 'pg\_%' ESCAPE '\' THEN
        RAISE EXCEPTION 'pgaudix: cannot audit system table %.%', v_schema, v_table;
    END IF;

    -- Reject the extension's own tables (registry, guard): auditing them would
    -- write audit rows on every enable()/disable() and on every DDL statement
    IF v_schema = 'pgaudix' THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: tables of the pgaudix schema belong to the extension',
            v_schema, v_table;
    END IF;

    -- Reject names that would silently truncate past NAMEDATALEN (63 bytes).
    -- Count BYTES, not characters, so multibyte names are handled correctly (A1, bug #8).
    IF octet_length(v_table::text) + octet_length('_audit') > 63 THEN
        RAISE EXCEPTION 'pgaudix: source table name % is too long (audit table name would exceed 63 bytes)',
            v_table;
    END IF;

    -- Reject source columns that collide with reserved audit metadata names (bug #7)
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = target_table AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname IN ('audit_id', 'audit_operation', 'audit_timestamp',
                            'audit_txid', 'audit_user', 'audit_client_addr',
                            'audit_app_name', 'audit_app_user')
    ) THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: a source column name collides with a reserved audit metadata column (audit_id, audit_operation, audit_timestamp, audit_txid, audit_user, audit_client_addr, audit_app_name, audit_app_user)',
            v_schema, v_table;
    END IF;

    -- Reject tables whose attnum span would overflow the audit table column
    -- limit. The audit table reserves one slot per source attnum (gap fillers
    -- included) plus the fixed metadata columns (bug #9).
    SELECT max(att.attnum) INTO v_max_attnum
    FROM pg_catalog.pg_attribute att
    WHERE att.attrelid = target_table AND att.attnum > 0;
    IF v_max_attnum IS NOT NULL AND (8 + v_max_attnum) > 1600 THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: audit table would need % columns (8 metadata + % attnum span), exceeding the 1600-column limit',
            v_schema, v_table, 8 + v_max_attnum, v_max_attnum;
    END IF;

    v_audit := v_table || '_audit';
    v_audit_fqn := format('%I.%I', v_schema, v_audit);

    -- Build force-quoted form for C trigger argument validation (C2)
    v_audit_tgarg := '"' || replace(v_schema::text, '"', '""')
                  || '"."' || replace(v_audit::text, '"', '""') || '"';

    -- Check not already monitored
    IF EXISTS (
        SELECT 1 FROM pgaudix.monitored_tables
        WHERE source_oid = target_table
    ) THEN
        RAISE EXCEPTION 'pgaudix: table %.% is already monitored',
            v_schema, v_table;
    END IF;

    -- Check audit table does not already exist
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = v_schema AND c.relname = v_audit
    ) THEN
        RAISE EXCEPTION 'pgaudix: audit table % already exists', v_audit_fqn;
    END IF;

    -- Build column definitions from source table (with gap fillers for attnum alignment)
    FOR rec IN
        SELECT gs.n AS src_attnum, a.attname,
               pgaudix.audit_type(a.atttypid, a.atttypmod) AS type_name
        FROM generate_series(
            1,
            (SELECT max(att.attnum) FROM pg_catalog.pg_attribute att
             WHERE att.attrelid = target_table AND att.attnum > 0)
        ) gs(n)
        LEFT JOIN pg_catalog.pg_attribute a
          ON a.attrelid = target_table AND a.attnum = gs.n
         AND a.attnum > 0 AND NOT a.attisdropped
         -- Virtual generated columns (PG18+) have no stored value: the trigger
         -- would only ever see NULL, so they are not mirrored (their attnum
         -- becomes a gap, like a dropped column)
         AND a.attgenerated <> 'v'
        ORDER BY gs.n
    LOOP
        IF rec.attname IS NOT NULL THEN
            v_cols := v_cols || format(', %I %s', rec.attname, rec.type_name);
        ELSE
            -- Gap filler: pick a name that no source column uses, and remember
            -- it so only the fillers we created are dropped below (never a real
            -- mirrored column that happens to look like one).
            v_gap := '_pgaudix_gap_' || rec.src_attnum;
            WHILE EXISTS (
                SELECT 1 FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = target_table AND a.attname = v_gap
                  AND a.attnum > 0 AND NOT a.attisdropped
            ) LOOP
                v_gap := v_gap || '_';
            END LOOP;
            v_gap_cols := v_gap_cols || v_gap;
            v_cols := v_cols || format(', %I int', v_gap);
        END IF;
    END LOOP;

    -- Create the audit table. Mirror the source table's persistence so an
    -- UNLOGGED source is not audited by a durable (permanent) table (bug #10).
    EXECUTE format(
        'CREATE %s TABLE %s ('
        '    audit_id            bigserial PRIMARY KEY,'
        '    audit_operation     char(1) NOT NULL CHECK (audit_operation IN (''I'',''U'',''D'',''T'')),'
        '    audit_timestamp     timestamptz NOT NULL DEFAULT clock_timestamp(),'
        '    audit_txid          bigint NOT NULL DEFAULT txid_current(),'
        '    audit_user          name NOT NULL DEFAULT session_user,'
        '    audit_client_addr   inet DEFAULT inet_client_addr(),'
        '    audit_app_name      text DEFAULT current_setting(''application_name''),'
        '    audit_app_user      text DEFAULT current_setting(''pgaudix.app_user'', true)'
        '    %s'
        ')',
        CASE WHEN v_relpersist = 'u' THEN 'UNLOGGED' ELSE '' END,
        v_audit_fqn, v_cols
    );

    -- Hold the DDL-sync recursion guard for the rest of enable(): the ALTERs
    -- on the audit table and the ALTER TABLE ... ENABLE ALWAYS on the source
    -- would otherwise fire ddl_sync before the table is registered.
    INSERT INTO pgaudix.ddl_guard (pid) VALUES (pg_backend_pid())
    ON CONFLICT (pid) DO NOTHING;

    -- Drop exactly the gap fillers created above to leave matching attnum holes
    FOREACH v_gap IN ARRAY v_gap_cols LOOP
        EXECUTE format('ALTER TABLE %s DROP COLUMN %I', v_audit_fqn, v_gap);
    END LOOP;

    -- Create index on audit_timestamp
    EXECUTE format(
        'CREATE INDEX ON %s (audit_timestamp)', v_audit_fqn
    );

    -- Restrict direct modification of audit table (M2, A6)
    EXECUTE format(
        'REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON %s FROM PUBLIC',
        v_audit_fqn
    );

    -- Capture the audit table OID for robust, name-independent DDL tracking (bug #2)
    SELECT c.oid INTO v_audit_oid
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = v_schema AND c.relname = v_audit;

    -- Create the DML audit trigger on the source table. ENABLE ALWAYS so auditing
    -- keeps working under session_replication_role = 'replica' (bug #4).
    EXECUTE format(
        'CREATE TRIGGER pgaudix_audit_trigger '
        'AFTER INSERT OR UPDATE OR DELETE ON %I.%I '
        'FOR EACH ROW EXECUTE FUNCTION pgaudix.audit_trigger(%L)',
        v_schema, v_table, v_audit_tgarg
    );
    EXECUTE format(
        'ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER pgaudix_audit_trigger',
        v_schema, v_table
    );

    -- Create the TRUNCATE audit trigger (M1), also ENABLE ALWAYS (bug #4)
    EXECUTE format(
        'CREATE TRIGGER pgaudix_truncate_trigger '
        'AFTER TRUNCATE ON %I.%I '
        'FOR EACH STATEMENT EXECUTE FUNCTION pgaudix.truncate_trigger(%L, %L)',
        v_schema, v_table, v_schema, v_audit
    );
    EXECUTE format(
        'ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER pgaudix_truncate_trigger',
        v_schema, v_table
    );

    -- Register in monitored_tables (with source + audit OID for H2 / bug #2)
    INSERT INTO pgaudix.monitored_tables
        (source_oid, source_schema, source_table, audit_schema, audit_table, audit_oid)
    VALUES (target_table, v_schema, v_table, v_schema, v_audit, v_audit_oid);

    -- For a partitioned table, the statement-level TRUNCATE trigger on the root
    -- does NOT fire when an individual partition is truncated directly, so each
    -- leaf gets its own trigger (bug #5). Leaves attached or detached later are
    -- reconciled by ddl_sync through the same function.
    PERFORM pgaudix.sync_partition_triggers();

    DELETE FROM pgaudix.ddl_guard WHERE pid = pg_backend_pid();
END;
$func$;

-- ============================================================
-- disable(target_table regclass, drop_data boolean)
-- ============================================================

CREATE FUNCTION pgaudix.disable(
    target_table regclass,
    drop_data boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
DECLARE
    v_schema    name;
    v_table     name;
    v_relkind   "char";
    rec         record;
    mon         pgaudix.monitored_tables%ROWTYPE;
BEGIN
    -- The caller must own the table (or be a superuser)
    PERFORM pgaudix.check_table_owner(target_table);

    -- Re-bind registry rows whose OIDs went stale (pg_dump/restore)
    PERFORM pgaudix.heal_registry();

    -- Resolve schema, table name and relkind
    SELECT n.nspname, c.relname, c.relkind
    INTO v_schema, v_table, v_relkind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.oid = target_table;

    -- Find the registration by OID (H2)
    SELECT * INTO mon
    FROM pgaudix.monitored_tables
    WHERE source_oid = target_table;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgaudix: table %.% is not monitored',
            v_schema, v_table;
    END IF;

    -- Drop the DML trigger
    EXECUTE format(
        'DROP TRIGGER IF EXISTS pgaudix_audit_trigger ON %I.%I',
        v_schema, v_table
    );

    -- Drop the TRUNCATE trigger
    EXECUTE format(
        'DROP TRIGGER IF EXISTS pgaudix_truncate_trigger ON %I.%I',
        v_schema, v_table
    );

    -- Optionally drop the audit table
    IF drop_data THEN
        EXECUTE format(
            'DROP TABLE IF EXISTS %I.%I',
            mon.audit_schema, mon.audit_table
        );
    END IF;

    -- Remove registration
    DELETE FROM pgaudix.monitored_tables WHERE id = mon.id;

    -- Drop the per-leaf TRUNCATE triggers that belonged to this root, if any:
    -- once deregistered they are orphans and the reconciliation removes them
    PERFORM pgaudix.sync_partition_triggers();
END;
$func$;

-- ============================================================
-- status()
-- ============================================================

CREATE FUNCTION pgaudix.status()
RETURNS TABLE (
    source_schema           name,
    source_table            name,
    audit_schema            name,
    audit_table             name,
    created_at              timestamptz,
    audit_table_exists       boolean,
    dml_trigger_exists       boolean,
    dml_trigger_enabled      boolean,
    truncate_trigger_exists  boolean,
    truncate_trigger_enabled boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
BEGIN
    -- Re-bind registry rows whose OIDs went stale (pg_dump/restore)
    PERFORM pgaudix.heal_registry();

    RETURN QUERY
    SELECT
        mt.source_schema, mt.source_table, mt.audit_schema, mt.audit_table,
        mt.created_at,
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
            WHERE n.nspname = mt.audit_schema AND c.relname = mt.audit_table
        ) AS audit_table_exists,
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid = mt.source_oid
              AND t.tgname = 'pgaudix_audit_trigger'
              AND NOT t.tgisinternal
        ) AS dml_trigger_exists,
        -- enabled = present AND not DISABLEd (tgenabled <> 'D'); a healthy audit
        -- trigger is 'A' (ENABLE ALWAYS) so it also fires under replica role (bug #4)
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid = mt.source_oid
              AND t.tgname = 'pgaudix_audit_trigger'
              AND NOT t.tgisinternal
              AND t.tgenabled <> 'D'
        ) AS dml_trigger_enabled,
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid = mt.source_oid
              AND t.tgname = 'pgaudix_truncate_trigger'
              AND NOT t.tgisinternal
        ) AS truncate_trigger_exists,
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid = mt.source_oid
              AND t.tgname = 'pgaudix_truncate_trigger'
              AND NOT t.tgisinternal
              AND t.tgenabled <> 'D'
        ) AS truncate_trigger_enabled
    FROM pgaudix.monitored_tables mt
    ORDER BY mt.source_schema, mt.source_table;
END;
$func$;

-- ============================================================
-- DDL event trigger: sync audit table on ALTER TABLE
-- ============================================================

CREATE FUNCTION pgaudix.ddl_sync()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
DECLARE
    cmd         record;
    mon         record;
    cur         record;
    v_audit_fqn text;
    v_source_oid oid;
    v_audit_oid  oid;
    v_offset     int;
    v_new_schema name;
    v_new_table  name;
    v_new_audit  name;
    v_new_tgarg  text;
    v_cur_audit_schema name;
    v_cur_audit_name   name;
    v_altered_tables   oid[];   -- tables named by ALTER TABLE, plus descendants
    v_affected_tables  oid[];   -- those, plus every table of a schema named by ALTER SCHEMA
BEGIN
    -- Guard against recursive invocations from our own ALTERs on audit tables
    -- (see pgaudix.ddl_guard). The row MUST be removed before returning (bug #1)
    -- so later DDL in the same transaction is synced normally.
    IF EXISTS (SELECT 1 FROM pgaudix.ddl_guard WHERE pid = pg_backend_pid()) THEN
        RETURN;
    END IF;
    INSERT INTO pgaudix.ddl_guard (pid) VALUES (pg_backend_pid());

    -- Re-bind registry rows whose OIDs went stale (pg_dump/restore)
    PERFORM pgaudix.heal_registry();

    -- pg_event_trigger_ddl_commands() reports only the table named in an
    -- ALTER TABLE. Column changes propagate to inheritance children and
    -- partitions, so expand every altered table to all its descendants.
    WITH RECURSIVE altered(relid) AS (
        SELECT c.objid
        FROM pg_event_trigger_ddl_commands() c
        WHERE c.command_tag = 'ALTER TABLE'
          AND c.object_type IN ('table', 'table column')
        UNION
        SELECT i.inhrelid
        FROM pg_catalog.pg_inherits i
        JOIN altered a ON i.inhparent = a.relid
    )
    SELECT coalesce(array_agg(relid), '{}') INTO v_altered_tables FROM altered;

    -- ALTER SCHEMA (rename) moves every table of the schema at once
    SELECT coalesce(array_agg(c.oid), '{}') || v_altered_tables
    INTO v_affected_tables
    FROM pg_event_trigger_ddl_commands() dc
    JOIN pg_catalog.pg_class c ON c.relnamespace = dc.objid
    WHERE dc.command_tag = 'ALTER SCHEMA'
      AND c.relkind IN ('r', 'p');

    -- ----------------------------------------------------------------
    -- Pre-pass: sync source_schema / source_table / audit_schema /
    -- audit_table for the monitored entries touched by this command
    -- whose current pg_class name no longer matches the registration.
    -- Covers RENAME TABLE, SET SCHEMA and ALTER SCHEMA RENAME (A2, H2).
    -- Only the affected tables are examined: a registry row that is out
    -- of sync (audit table dropped, audit name taken) must not break or
    -- lock DDL on unrelated tables.
    -- ----------------------------------------------------------------
    FOR mon IN
        SELECT mt.* FROM pgaudix.monitored_tables mt
        WHERE mt.source_oid = ANY (v_affected_tables)
        ORDER BY mt.id
    LOOP
        -- Current source location (by OID — authoritative across renames)
        SELECT n.nspname, c.relname
        INTO v_new_schema, v_new_table
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE c.oid = mon.source_oid;

        -- Source dropped — drop_cleanup will remove the row
        CONTINUE WHEN v_new_schema IS NULL;

        -- Current audit-table location (by OID — survives schema/table renames
        -- and tells us where the audit table ACTUALLY is, which differs between
        -- ALTER SCHEMA RENAME and ALTER TABLE SET SCHEMA, bug #2)
        SELECT n.nspname, c.relname
        INTO v_cur_audit_schema, v_cur_audit_name
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE c.oid = mon.audit_oid;

        -- Audit table gone: nothing to rename; status() reports it and a
        -- direct ALTER of the source raises below
        CONTINUE WHEN v_cur_audit_schema IS NULL;

        v_new_audit := v_new_table || '_audit';

        -- Nothing changed: source name/schema and audit name/schema all match
        IF v_new_schema = mon.source_schema AND v_new_table = mon.source_table
           AND v_cur_audit_schema IS NOT DISTINCT FROM v_new_schema
           AND v_cur_audit_name   IS NOT DISTINCT FROM v_new_audit THEN
            CONTINUE;
        END IF;

        -- Move the audit table into the source's (possibly new) schema. Required
        -- for ALTER TABLE ... SET SCHEMA, where only the source moves (bug #2).
        -- For ALTER SCHEMA RENAME the audit table already moved with the schema,
        -- so this is a no-op.
        IF v_cur_audit_schema IS NOT NULL AND v_cur_audit_schema <> v_new_schema THEN
            EXECUTE format(
                'ALTER TABLE %I.%I SET SCHEMA %I',
                v_cur_audit_schema, v_cur_audit_name, v_new_schema
            );
            v_cur_audit_schema := v_new_schema;
        END IF;

        -- Rename the audit table to track a source RENAME
        IF v_cur_audit_name IS NOT NULL AND v_cur_audit_name <> v_new_audit THEN
            EXECUTE format(
                'ALTER TABLE %I.%I RENAME TO %I',
                v_cur_audit_schema, v_cur_audit_name, v_new_audit
            );
        END IF;

        -- Recreate triggers so their argument points at the current audit name
        EXECUTE format(
            'DROP TRIGGER IF EXISTS pgaudix_audit_trigger ON %I.%I',
            v_new_schema, v_new_table
        );

        v_new_tgarg := '"' || replace(v_new_schema::text, '"', '""')
                    || '"."' || replace(v_new_audit::text, '"', '""') || '"';

        EXECUTE format(
            'CREATE TRIGGER pgaudix_audit_trigger '
            'AFTER INSERT OR UPDATE OR DELETE ON %I.%I '
            'FOR EACH ROW EXECUTE FUNCTION pgaudix.audit_trigger(%L)',
            v_new_schema, v_new_table, v_new_tgarg
        );
        EXECUTE format(
            'ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER pgaudix_audit_trigger',
            v_new_schema, v_new_table
        );

        EXECUTE format(
            'DROP TRIGGER IF EXISTS pgaudix_truncate_trigger ON %I.%I',
            v_new_schema, v_new_table
        );

        EXECUTE format(
            'CREATE TRIGGER pgaudix_truncate_trigger '
            'AFTER TRUNCATE ON %I.%I '
            'FOR EACH STATEMENT EXECUTE FUNCTION pgaudix.truncate_trigger(%L, %L)',
            v_new_schema, v_new_table, v_new_schema, v_new_audit
        );
        EXECUTE format(
            'ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER pgaudix_truncate_trigger',
            v_new_schema, v_new_table
        );

        UPDATE pgaudix.monitored_tables
        SET source_schema = v_new_schema, source_table = v_new_table,
            audit_schema = v_new_schema, audit_table = v_new_audit
        WHERE id = mon.id;

        RAISE NOTICE 'pgaudix: synchronized audit registration to %.%',
            v_new_schema, v_new_audit;
    END LOOP;

    -- Reconcile per-leaf TRUNCATE triggers: covers RENAME / SET SCHEMA of a
    -- partitioned root (new audit name) and ATTACH / DETACH PARTITION
    PERFORM pgaudix.sync_partition_triggers();

    -- Sync every monitored table among the altered ones and their descendants
    FOR cmd IN
        SELECT relid AS objid FROM unnest(v_altered_tables) AS t(relid) ORDER BY relid
    LOOP
        -- Resolve source OID
        v_source_oid := cmd.objid;

        -- Block direct ALTER on audit tables (M3) — match by stored OID
        IF EXISTS (
            SELECT 1 FROM pgaudix.monitored_tables mt
            WHERE mt.audit_oid = v_source_oid
        ) THEN
            RAISE WARNING 'pgaudix: direct ALTER on audit table is not recommended — changes may be overwritten by DDL sync';
            CONTINUE;
        END IF;

        -- Look up monitored table by OID (H2). After the pre-pass above,
        -- mon.source_schema / source_table reflect the current names.
        SELECT mt.*
        INTO mon
        FROM pgaudix.monitored_tables mt
        WHERE mt.source_oid = v_source_oid;

        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        v_audit_fqn := format('%I.%I', mon.audit_schema, mon.audit_table);

        -- Resolve audit table OID (authoritative, stored at enable time)
        v_audit_oid := mon.audit_oid;

        IF v_audit_oid IS NULL
           OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE oid = v_audit_oid) THEN
            RAISE EXCEPTION 'pgaudix: audit table %.% is missing — cannot sync DDL',
                mon.audit_schema, mon.audit_table;
        END IF;

        -- The offset between source and audit attnums is the attnum of the
        -- last metadata column (audit_app_user)
        SELECT a.attnum INTO v_offset
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = v_audit_oid
          AND a.attname = 'audit_app_user'
          AND NOT a.attisdropped;

        IF v_offset IS NULL THEN
            RAISE EXCEPTION 'pgaudix: audit table % is corrupted (audit_app_user column missing) — cannot sync DDL',
                v_audit_fqn;
        END IF;

        -- A source column cannot take the name of an audit metadata column:
        -- it could not be mirrored. Reject with a clear message instead of the
        -- generic "column already exists" from the audit table.
        FOR cur IN
            SELECT a.attname
            FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = v_source_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND a.attname IN ('audit_id', 'audit_operation', 'audit_timestamp',
                                'audit_txid', 'audit_user', 'audit_client_addr',
                                'audit_app_name', 'audit_app_user')
            ORDER BY a.attnum
        LOOP
            RAISE EXCEPTION 'pgaudix: column name "%" is reserved for audit metadata and cannot be used in audited table %.%',
                cur.attname, mon.source_schema, mon.source_table;
        END LOOP;

        -- --------------------------------------------------------
        -- Detect DROPPED columns (before ADDED: a single ALTER TABLE may
        -- DROP a column and ADD one with the same name, and PostgreSQL runs
        -- the DROP first, so the audit table must free the name first)
        -- --------------------------------------------------------
        FOR cur IN
            SELECT aud.attnum, aud.attname
            FROM pg_catalog.pg_attribute aud
            WHERE aud.attrelid = v_audit_oid
              AND aud.attnum > v_offset
              AND NOT aud.attisdropped
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_attribute a
                  WHERE a.attrelid = v_source_oid
                    AND a.attnum = aud.attnum - v_offset
                    AND NOT a.attisdropped
              )
            ORDER BY aud.attnum
        LOOP
            EXECUTE format(
                'ALTER TABLE %s DROP COLUMN IF EXISTS %I',
                v_audit_fqn, cur.attname
            );
        END LOOP;

        -- --------------------------------------------------------
        -- Detect ADDED columns (in attnum order, so the audit table's new
        -- attnums line up with the source's regardless of the scan plan)
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname, a.attgenerated,
                   pgaudix.audit_type(a.atttypid, a.atttypmod) AS atttype
            FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = v_source_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_attribute aud
                  WHERE aud.attrelid = v_audit_oid
                    AND aud.attnum = a.attnum + v_offset
              )
            ORDER BY a.attnum
        LOOP
            IF cur.attgenerated = 'v' THEN
                -- Virtual generated column (PG18+): not mirrored, but its attnum
                -- must be consumed on the audit side too so later columns stay
                -- aligned. Add and drop a placeholder to leave a dropped slot.
                EXECUTE format(
                    'ALTER TABLE %s ADD COLUMN %I int',
                    v_audit_fqn, '_pgaudix_gap_' || cur.attnum
                );
                EXECUTE format(
                    'ALTER TABLE %s DROP COLUMN %I',
                    v_audit_fqn, '_pgaudix_gap_' || cur.attnum
                );
            ELSE
                EXECUTE format(
                    'ALTER TABLE %s ADD COLUMN %I %s',
                    v_audit_fqn, cur.attname, cur.atttype
                );
            END IF;
        END LOOP;

        -- --------------------------------------------------------
        -- Detect RENAMED columns
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname AS new_name,
                   aud.attname AS old_name
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_attribute aud
              ON aud.attrelid = v_audit_oid
             AND aud.attnum = a.attnum + v_offset
             AND NOT aud.attisdropped
            WHERE a.attrelid = v_source_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND a.attname != aud.attname
            ORDER BY a.attnum
        LOOP
            EXECUTE format(
                'ALTER TABLE %s RENAME COLUMN %I TO %I',
                v_audit_fqn, cur.old_name, cur.new_name
            );
        END LOOP;

        -- --------------------------------------------------------
        -- Detect TYPE CHANGES
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname,
                   pgaudix.audit_type(a.atttypid, a.atttypmod)     AS new_type,
                   pgaudix.audit_type(aud.atttypid, aud.atttypmod) AS audit_type
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_attribute aud
              ON aud.attrelid = v_audit_oid
             AND aud.attnum = a.attnum + v_offset
             AND NOT aud.attisdropped
            WHERE a.attrelid = v_source_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND a.attname = aud.attname
              AND pgaudix.audit_type(a.atttypid, a.atttypmod)
                  != pgaudix.audit_type(aud.atttypid, aud.atttypmod)
              -- A text audit column accepts any value through the assignment
              -- cast the C trigger relies on, so it is never narrowed or changed
              -- again (this is also the fallback type used below).
              AND aud.atttypid <> 'pg_catalog.text'::regtype
            ORDER BY a.attnum
        LOOP
            -- The audit table is an append-only log holding historical values the
            -- source no longer has. Mirror the type change with an explicit cast
            -- (the user's USING expression is not available here). If history is
            -- incompatible with the new type, degrade the audit column to text:
            -- history is preserved (as text) and the DML trigger, which binds
            -- parameters with the source's current type, keeps working (bug #3).
            BEGIN
                EXECUTE format(
                    'ALTER TABLE %s ALTER COLUMN %I TYPE %s USING %I::%s',
                    v_audit_fqn, cur.attname, cur.new_type, cur.attname, cur.new_type
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'pgaudix: could not change audit column %.% from % to % (%); converting it to text so history is preserved and auditing keeps working',
                    v_audit_fqn, cur.attname, cur.audit_type, cur.new_type, SQLERRM;
                EXECUTE format(
                    'ALTER TABLE %s ALTER COLUMN %I TYPE pg_catalog.text USING %I::pg_catalog.text',
                    v_audit_fqn, cur.attname, cur.attname
                );
            END;
        END LOOP;

    END LOOP;

    -- Release the recursion guard so later statements in the same transaction
    -- are synced normally (bug #1). On error the transaction rollback removes
    -- the row, so this success-path delete is sufficient.
    DELETE FROM pgaudix.ddl_guard WHERE pid = pg_backend_pid();
END;
$func$;

-- Create the event trigger
CREATE EVENT TRIGGER pgaudix_ddl_sync
    ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE', 'ALTER SCHEMA')
    EXECUTE FUNCTION pgaudix.ddl_sync();

-- The DML and TRUNCATE triggers are ENABLE ALWAYS so auditing keeps working
-- under session_replication_role = 'replica'; DDL sync must follow, otherwise
-- an ALTER in that mode desyncs the audit table and later DML fails.
ALTER EVENT TRIGGER pgaudix_ddl_sync ENABLE ALWAYS;

-- ============================================================
-- DROP cleanup: drop the audit table and the registry row when the
-- source table is dropped (A3)
-- ============================================================
-- The audit table lives and dies with its source: without it, a table
-- recreated with the same name could never be audited again (enable()
-- refuses to reuse an existing audit table).

CREATE FUNCTION pgaudix.drop_cleanup()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
DECLARE
    obj record;
    mon record;
BEGIN
    FOR obj IN
        SELECT objid, schema_name, object_name
        FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'table'
    LOOP
        -- Match by OID, or by name for rows whose OID went stale after a
        -- pg_dump/restore and was not healed yet.
        FOR mon IN
            SELECT mt.*
            FROM pgaudix.monitored_tables mt
            WHERE mt.source_oid = obj.objid
               OR (mt.source_schema = obj.schema_name AND mt.source_table = obj.object_name)
        LOOP
            -- Drop the audit table if it still exists (a DROP SCHEMA ... CASCADE
            -- may have removed it in the same statement)
            IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid = mon.audit_oid) THEN
                EXECUTE format('DROP TABLE IF EXISTS %s', mon.audit_oid::regclass);
            END IF;

            DELETE FROM pgaudix.monitored_tables WHERE id = mon.id;
        END LOOP;
    END LOOP;
END;
$func$;

CREATE EVENT TRIGGER pgaudix_drop_cleanup
    ON sql_drop
    EXECUTE FUNCTION pgaudix.drop_cleanup();

ALTER EVENT TRIGGER pgaudix_drop_cleanup ENABLE ALWAYS;

-- ============================================================
-- Privileges
-- ============================================================
-- Every function runs as the extension owner (SECURITY DEFINER) or is an
-- internal helper, so none of them may be executable by PUBLIC:
--   * enable()/disable()/status(): grant EXECUTE to trusted roles; enable()
--     and disable() additionally require the caller to own the table.
--   * audit_trigger()/truncate_trigger(): only enable() creates triggers on
--     them. Trigger execution does not check EXECUTE, so revoking keeps the
--     triggers working while preventing anyone from attaching these functions
--     to their own tables to forge rows in another table's audit log.
REVOKE EXECUTE ON FUNCTION
    pgaudix.enable(regclass),
    pgaudix.disable(regclass, boolean),
    pgaudix.status(),
    pgaudix.audit_trigger(),
    pgaudix.truncate_trigger(),
    pgaudix.ddl_sync(),
    pgaudix.drop_cleanup(),
    pgaudix.heal_registry(),
    pgaudix.sync_partition_triggers(),
    pgaudix.check_table_owner(regclass),
    pgaudix.invoker(),
    pgaudix.audit_type(oid, integer)
FROM PUBLIC;
