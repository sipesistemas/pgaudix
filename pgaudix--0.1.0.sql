-- pgaudix: automatic table auditing with column mirroring and DDL sync
-- Version 0.1.0

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
    rec         record;
BEGIN
    -- Serialize concurrent enable() calls (H3)
    LOCK TABLE pgaudix.monitored_tables IN EXCLUSIVE MODE;

    -- Resolve schema and table name
    SELECT n.nspname, c.relname
    INTO v_schema, v_table
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.oid = target_table;

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

    -- Create the audit table
    EXECUTE format(
        'CREATE TABLE %s ('
        '    audit_id            bigserial PRIMARY KEY,'
        '    audit_operation     char(1) NOT NULL,'
        '    audit_timestamp     timestamptz NOT NULL DEFAULT clock_timestamp(),'
        '    audit_txid          bigint NOT NULL DEFAULT txid_current(),'
        '    audit_user          name NOT NULL DEFAULT session_user,'
        '    audit_client_addr   inet DEFAULT inet_client_addr(),'
        '    audit_app_name      text DEFAULT current_setting(''application_name'')'
        '    %s'
        ')',
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

    -- Restrict direct modification of audit table (M2)
    EXECUTE format(
        'REVOKE INSERT, UPDATE, DELETE ON %s FROM PUBLIC',
        v_audit_fqn
    );

    -- Create the DML audit trigger on the source table
    EXECUTE format(
        'CREATE TRIGGER pgaudix_audit_trigger '
        'AFTER INSERT OR UPDATE OR DELETE ON %I.%I '
        'FOR EACH ROW EXECUTE FUNCTION pgaudix.audit_trigger(%L)',
        v_schema, v_table, v_audit_tgarg
    );

    -- Create the TRUNCATE audit trigger (M1)
    EXECUTE format(
        'CREATE TRIGGER pgaudix_truncate_trigger '
        'AFTER TRUNCATE ON %I.%I '
        'FOR EACH STATEMENT EXECUTE FUNCTION pgaudix.truncate_trigger(%L, %L)',
        v_schema, v_table, v_schema, v_audit
    );

    -- Register in monitored_tables (with source OID for H2)
    INSERT INTO pgaudix.monitored_tables
        (source_oid, source_schema, source_table, audit_schema, audit_table)
    VALUES (target_table, v_schema, v_table, v_schema, v_audit);
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
    mon         pgaudix.monitored_tables%ROWTYPE;
BEGIN
    -- Resolve schema and table name
    SELECT n.nspname, c.relname
    INTO v_schema, v_table
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
END;
$func$;

-- ============================================================
-- status()
-- ============================================================

CREATE FUNCTION pgaudix.status()
RETURNS TABLE (
    source_schema   name,
    source_table    name,
    audit_schema    name,
    audit_table     name,
    enabled         boolean,
    created_at      timestamptz
)
LANGUAGE sql
STABLE
SET search_path = pgaudix, pg_catalog
AS $func$
    SELECT source_schema, source_table, audit_schema, audit_table,
           enabled, created_at
    FROM pgaudix.monitored_tables
    ORDER BY source_schema, source_table;
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
BEGIN
    -- Guard against recursive invocations from our own ALTERs on audit tables
    IF current_setting('pgaudix.in_ddl_sync', true) = 'true' THEN
        RETURN;
    END IF;
    PERFORM set_config('pgaudix.in_ddl_sync', 'true', true);

    FOR cmd IN
        SELECT *
        FROM pg_event_trigger_ddl_commands()
        WHERE command_tag = 'ALTER TABLE'
          AND object_type IN ('table', 'table column')
    LOOP
        -- Resolve source OID
        v_source_oid := cmd.objid;

        -- Block direct ALTER on audit tables (M3)
        IF EXISTS (
            SELECT 1 FROM pgaudix.monitored_tables mt
            WHERE mt.enabled
              AND v_source_oid = (
                  SELECT c.oid FROM pg_catalog.pg_class c
                  JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
                  WHERE n.nspname = mt.audit_schema AND c.relname = mt.audit_table
              )
        ) THEN
            RAISE WARNING 'pgaudix: direct ALTER on audit table is not recommended — changes may be overwritten by DDL sync';
            CONTINUE;
        END IF;

        -- Look up monitored table by OID (H2)
        SELECT mt.*
        INTO mon
        FROM pgaudix.monitored_tables mt
        WHERE mt.enabled AND mt.source_oid = v_source_oid;

        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        -- Detect and handle RENAME TABLE / SET SCHEMA (H2)
        SELECT n.nspname, c.relname
        INTO v_new_schema, v_new_table
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE c.oid = v_source_oid;

        IF v_new_schema != mon.source_schema OR v_new_table != mon.source_table THEN
            v_new_audit := v_new_table || '_audit';

            -- Rename the audit table to match
            IF v_new_audit != mon.audit_table THEN
                EXECUTE format(
                    'ALTER TABLE %I.%I RENAME TO %I',
                    mon.audit_schema, mon.audit_table, v_new_audit
                );
            END IF;

            -- Move audit table to new schema if schema changed
            IF v_new_schema != mon.audit_schema THEN
                EXECUTE format(
                    'ALTER TABLE %I.%I SET SCHEMA %I',
                    mon.audit_schema, v_new_audit, v_new_schema
                );
            END IF;

            -- Recreate DML trigger with updated audit table reference
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

            -- Recreate TRUNCATE trigger with updated arguments
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

            -- Update registration
            UPDATE pgaudix.monitored_tables
            SET source_schema = v_new_schema, source_table = v_new_table,
                audit_schema = v_new_schema, audit_table = v_new_audit
            WHERE id = mon.id;

            mon.source_schema := v_new_schema;
            mon.source_table := v_new_table;
            mon.audit_schema := v_new_schema;
            mon.audit_table := v_new_audit;

            RAISE NOTICE 'pgaudix: renamed audit table to %.%',
                v_new_schema, v_new_audit;
        END IF;

        v_audit_fqn := format('%I.%I', mon.audit_schema, mon.audit_table);

        -- Resolve audit table OID and attnum offset
        SELECT c.oid INTO v_audit_oid
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = mon.audit_schema AND c.relname = mon.audit_table;

        SELECT a.attnum INTO v_offset
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = v_audit_oid
          AND a.attname = 'audit_app_name'
          AND NOT a.attisdropped;

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
            EXECUTE format(
                'ALTER TABLE %s ALTER COLUMN %I TYPE %s',
                v_audit_fqn, cur.attname, cur.new_type
            );
        END LOOP;

    END LOOP;
END;
$func$;

-- Create the event trigger
CREATE EVENT TRIGGER pgaudix_ddl_sync
    ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE')
    EXECUTE FUNCTION pgaudix.ddl_sync();
