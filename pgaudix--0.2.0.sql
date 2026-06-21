-- pgaudix: automatic table auditing with column mirroring and DDL sync
-- Version 0.2.0
--
-- This is the full install script for a fresh `CREATE EXTENSION pgaudix`.
-- It must always reflect the COMPLETE schema of version 0.2.0.
-- Anyone already on 0.1.0 upgrades via pgaudix--0.1.0--0.2.0.sql instead.

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
    enabled         boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_schema, source_table)
);

-- ============================================================
-- C trigger function declaration
-- ============================================================

CREATE FUNCTION pgaudix.audit_trigger()
    RETURNS trigger
    AS 'pgaudix', 'pgaudix_trigger'
    LANGUAGE c
    SECURITY DEFINER
    SET search_path = pgaudix, pg_catalog;

-- ============================================================
-- PL/pgSQL TRUNCATE trigger function (M1)
-- ============================================================

CREATE FUNCTION pgaudix.truncate_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog
AS $func$
BEGIN
    EXECUTE format(
        'INSERT INTO %I.%I (audit_operation) VALUES (''T'')',
        TG_ARGV[0], TG_ARGV[1]
    );
    RETURN NULL;
END;
$func$;

-- ============================================================
-- enable(target_table regclass)
-- ============================================================

CREATE FUNCTION pgaudix.enable(target_table regclass)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog
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
    rec         record;
BEGIN
    -- Serialize concurrent enable() calls (H3)
    LOCK TABLE pgaudix.monitored_tables IN EXCLUSIVE MODE;

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
                            'audit_txid', 'audit_user', 'audit_client_addr', 'audit_app_name')
    ) THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: a source column name collides with a reserved audit metadata column (audit_id, audit_operation, audit_timestamp, audit_txid, audit_user, audit_client_addr, audit_app_name)',
            v_schema, v_table;
    END IF;

    -- Reject tables whose attnum span would overflow the audit table column
    -- limit. The audit table reserves one slot per source attnum (gap fillers
    -- included) plus the fixed metadata columns (bug #9).
    SELECT max(att.attnum) INTO v_max_attnum
    FROM pg_catalog.pg_attribute att
    WHERE att.attrelid = target_table AND att.attnum > 0;
    IF v_max_attnum IS NOT NULL AND (7 + v_max_attnum) > 1600 THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: audit table would need % columns (7 metadata + % attnum span), exceeding the 1600-column limit',
            v_schema, v_table, 7 + v_max_attnum, v_max_attnum;
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
               format_type(a.atttypid, a.atttypmod) AS type_name
        FROM generate_series(
            1,
            (SELECT max(att.attnum) FROM pg_catalog.pg_attribute att
             WHERE att.attrelid = target_table AND att.attnum > 0)
        ) gs(n)
        LEFT JOIN pg_catalog.pg_attribute a
          ON a.attrelid = target_table AND a.attnum = gs.n
         AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY gs.n
    LOOP
        IF rec.attname IS NOT NULL THEN
            v_cols := v_cols || format(', %I %s', rec.attname, rec.type_name);
        ELSE
            v_cols := v_cols || format(', _pgaudix_gap_%s int', rec.src_attnum);
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
        '    audit_app_name      text DEFAULT current_setting(''application_name'')'
        '    %s'
        ')',
        CASE WHEN v_relpersist = 'u' THEN 'UNLOGGED' ELSE '' END,
        v_audit_fqn, v_cols
    );

    -- Drop gap fillers to create matching attnum holes
    PERFORM set_config('pgaudix.in_ddl_sync', 'true', true);
    FOR rec IN
        SELECT a.attname
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = v_schema AND c.relname = v_audit
          AND a.attname LIKE '_pgaudix\_gap\_%' ESCAPE '\'
          AND NOT a.attisdropped
    LOOP
        EXECUTE format('ALTER TABLE %s DROP COLUMN %I', v_audit_fqn, rec.attname);
    END LOOP;
    PERFORM set_config('pgaudix.in_ddl_sync', '', true);

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

    -- For a partitioned table, the statement-level TRUNCATE trigger on the root
    -- does NOT fire when an individual partition is truncated directly. Install a
    -- TRUNCATE trigger on every existing leaf partition too (bug #5).
    -- NOTE: partitions attached AFTER enable() are not covered automatically.
    IF v_relkind = 'p' THEN
        FOR rec IN
            SELECT pt.relid
            FROM pg_partition_tree(target_table) pt
            JOIN pg_catalog.pg_class c ON c.oid = pt.relid
            WHERE pt.isleaf AND c.relkind = 'r'
        LOOP
            EXECUTE format(
                'CREATE TRIGGER pgaudix_truncate_trigger '
                'AFTER TRUNCATE ON %s '
                'FOR EACH STATEMENT EXECUTE FUNCTION pgaudix.truncate_trigger(%L, %L)',
                rec.relid::regclass, v_schema, v_audit
            );
            EXECUTE format(
                'ALTER TABLE %s ENABLE ALWAYS TRIGGER pgaudix_truncate_trigger',
                rec.relid::regclass
            );
        END LOOP;
    END IF;

    -- Register in monitored_tables (with source + audit OID for H2 / bug #2)
    INSERT INTO pgaudix.monitored_tables
        (source_oid, source_schema, source_table, audit_schema, audit_table, audit_oid)
    VALUES (target_table, v_schema, v_table, v_schema, v_audit, v_audit_oid);
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
SET search_path = pgaudix, pg_catalog
AS $func$
DECLARE
    v_schema    name;
    v_table     name;
    v_relkind   "char";
    rec         record;
    mon         pgaudix.monitored_tables%ROWTYPE;
BEGIN
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

    -- Drop the per-leaf TRUNCATE triggers installed for partitioned roots (bug #5)
    IF v_relkind = 'p' THEN
        FOR rec IN
            SELECT pt.relid
            FROM pg_partition_tree(target_table) pt
            JOIN pg_catalog.pg_class c ON c.oid = pt.relid
            WHERE pt.isleaf AND c.relkind = 'r'
        LOOP
            EXECUTE format(
                'DROP TRIGGER IF EXISTS pgaudix_truncate_trigger ON %s',
                rec.relid::regclass
            );
        END LOOP;
    END IF;

    -- Optionally drop the audit table
    IF drop_data THEN
        EXECUTE format(
            'DROP TABLE IF EXISTS %I.%I',
            mon.audit_schema, mon.audit_table
        );
    END IF;

    -- Remove registration
    DELETE FROM pgaudix.monitored_tables WHERE id = mon.id;
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
    enabled                 boolean,
    created_at              timestamptz,
    audit_table_exists       boolean,
    dml_trigger_exists       boolean,
    dml_trigger_enabled      boolean,
    truncate_trigger_exists  boolean,
    truncate_trigger_enabled boolean
)
LANGUAGE sql
STABLE
SET search_path = pgaudix, pg_catalog
AS $func$
    SELECT
        mt.source_schema, mt.source_table, mt.audit_schema, mt.audit_table,
        mt.enabled, mt.created_at,
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
$func$;

-- ============================================================
-- DDL event trigger: sync audit table on ALTER TABLE
-- ============================================================

CREATE FUNCTION pgaudix.ddl_sync()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog
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
BEGIN
    -- Guard against recursive invocations from our own ALTERs on audit tables.
    -- The guard MUST be reset before returning (see end of function, bug #1):
    -- set_config(..., is_local := true) is scoped to the whole transaction, so
    -- without a reset the first DDL in a transaction would suppress sync for all
    -- later DDL in the same transaction.
    IF current_setting('pgaudix.in_ddl_sync', true) = 'true' THEN
        RETURN;
    END IF;
    PERFORM set_config('pgaudix.in_ddl_sync', 'true', true);

    -- ----------------------------------------------------------------
    -- Pre-pass: sync source_schema / source_table / audit_schema /
    -- audit_table for every monitored entry whose current pg_class
    -- name no longer matches the registration. Covers RENAME TABLE,
    -- SET SCHEMA and ALTER SCHEMA RENAME (A2, H2).
    -- ----------------------------------------------------------------
    FOR mon IN
        SELECT mt.* FROM pgaudix.monitored_tables mt WHERE mt.enabled
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

    FOR cmd IN
        SELECT *
        FROM pg_event_trigger_ddl_commands()
        WHERE command_tag = 'ALTER TABLE'
          AND object_type IN ('table', 'table column')
    LOOP
        -- Resolve source OID
        v_source_oid := cmd.objid;

        -- Block direct ALTER on audit tables (M3) — match by stored OID
        IF EXISTS (
            SELECT 1 FROM pgaudix.monitored_tables mt
            WHERE mt.enabled AND mt.audit_oid = v_source_oid
        ) THEN
            RAISE WARNING 'pgaudix: direct ALTER on audit table is not recommended — changes may be overwritten by DDL sync';
            CONTINUE;
        END IF;

        -- Look up monitored table by OID (H2). After the pre-pass above,
        -- mon.source_schema / source_table reflect the current names.
        SELECT mt.*
        INTO mon
        FROM pgaudix.monitored_tables mt
        WHERE mt.enabled AND mt.source_oid = v_source_oid;

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

        SELECT a.attnum INTO v_offset
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = v_audit_oid
          AND a.attname = 'audit_app_name'
          AND NOT a.attisdropped;

        IF v_offset IS NULL THEN
            RAISE EXCEPTION 'pgaudix: audit table % is corrupted (audit_app_name column missing) — cannot sync DDL',
                v_audit_fqn;
        END IF;

        -- --------------------------------------------------------
        -- Detect ADDED columns
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname, format_type(a.atttypid, a.atttypmod) AS atttype
            FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = v_source_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_attribute aud
                  WHERE aud.attrelid = v_audit_oid
                    AND aud.attnum = a.attnum + v_offset
                    AND NOT aud.attisdropped
              )
        LOOP
            EXECUTE format(
                'ALTER TABLE %s ADD COLUMN %I %s',
                v_audit_fqn, cur.attname, cur.atttype
            );
        END LOOP;

        -- --------------------------------------------------------
        -- Detect DROPPED columns
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
        LOOP
            EXECUTE format(
                'ALTER TABLE %s DROP COLUMN IF EXISTS %I',
                v_audit_fqn, cur.attname
            );
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
                   format_type(a.atttypid, a.atttypmod) AS new_type
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_attribute aud
              ON aud.attrelid = v_audit_oid
             AND aud.attnum = a.attnum + v_offset
             AND NOT aud.attisdropped
            WHERE a.attrelid = v_source_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND a.attname = aud.attname
              AND format_type(a.atttypid, a.atttypmod) != format_type(aud.atttypid, aud.atttypmod)
        LOOP
            -- The audit table is an append-only log holding historical values the
            -- source no longer has, so a narrowing TYPE change can overflow on old
            -- audit data and abort the user's (valid) source DDL. Catch that and
            -- keep the wider audit column to preserve history (bug #3).
            BEGIN
                EXECUTE format(
                    'ALTER TABLE %s ALTER COLUMN %I TYPE %s',
                    v_audit_fqn, cur.attname, cur.new_type
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'pgaudix: could not change audit column %.% to % — historical audit data is incompatible; leaving the audit column type unchanged to preserve history (%)',
                    v_audit_fqn, cur.attname, cur.new_type, SQLERRM;
            END;
        END LOOP;

    END LOOP;

    -- Release the recursion guard so later statements in the same transaction
    -- are synced normally (bug #1). On error the (sub)transaction rollback
    -- restores the GUC, so this success-path reset is sufficient.
    PERFORM set_config('pgaudix.in_ddl_sync', '', true);
END;
$func$;

-- Create the event trigger
CREATE EVENT TRIGGER pgaudix_ddl_sync
    ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE', 'ALTER SCHEMA')
    EXECUTE FUNCTION pgaudix.ddl_sync();

-- ============================================================
-- DROP cleanup: remove monitored_tables row when source is dropped (A3)
-- ============================================================

CREATE FUNCTION pgaudix.drop_cleanup()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog
AS $func$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT objid
        FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'table'
    LOOP
        DELETE FROM pgaudix.monitored_tables
        WHERE source_oid = obj.objid;
    END LOOP;
END;
$func$;

CREATE EVENT TRIGGER pgaudix_drop_cleanup
    ON sql_drop
    EXECUTE FUNCTION pgaudix.drop_cleanup();
