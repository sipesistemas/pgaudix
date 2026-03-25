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

CREATE TABLE pgaudix.column_snapshots (
    table_id    int NOT NULL REFERENCES pgaudix.monitored_tables(id) ON DELETE CASCADE,
    attnum      smallint NOT NULL,
    attname     name NOT NULL,
    atttype     text NOT NULL,
    PRIMARY KEY (table_id, attnum)
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
    v_mon_id    int;
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

    -- Build column definitions from source table
    FOR rec IN
        SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type_name,
               a.attnum
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = target_table
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        v_cols := v_cols || format(', %I %s', rec.attname, rec.type_name);
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
    VALUES (target_table, v_schema, v_table, v_schema, v_audit)
    RETURNING id INTO v_mon_id;

    -- Take a column snapshot for DDL sync
    INSERT INTO pgaudix.column_snapshots (table_id, attnum, attname, atttype)
    SELECT v_mon_id, a.attnum, a.attname, format_type(a.atttypid, a.atttypmod)
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = target_table
      AND a.attnum > 0
      AND NOT a.attisdropped;
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

    -- Remove registration (cascades to column_snapshots)
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
    snap        record;
    cur         record;
    v_audit_fqn text;
    v_source_oid oid;
    v_new_schema name;
    v_new_table  name;
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

        -- Detect and handle RENAME TABLE (H2)
        SELECT n.nspname, c.relname
        INTO v_new_schema, v_new_table
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE c.oid = v_source_oid;

        IF v_new_schema != mon.source_schema OR v_new_table != mon.source_table THEN
            UPDATE pgaudix.monitored_tables
            SET source_schema = v_new_schema, source_table = v_new_table
            WHERE id = mon.id;

            mon.source_schema := v_new_schema;
            mon.source_table := v_new_table;

            RAISE NOTICE 'pgaudix: updated registration for renamed table %.% (audit table unchanged: %.%)',
                v_new_schema, v_new_table, mon.audit_schema, mon.audit_table;
        END IF;

        v_audit_fqn := format('%I.%I', mon.audit_schema, mon.audit_table);

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
                  SELECT 1 FROM pgaudix.column_snapshots cs
                  WHERE cs.table_id = mon.id AND cs.attnum = a.attnum
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
        FOR snap IN
            SELECT cs.attnum, cs.attname
            FROM pgaudix.column_snapshots cs
            WHERE cs.table_id = mon.id
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_attribute a
                  WHERE a.attrelid = v_source_oid
                    AND a.attnum = cs.attnum
                    AND NOT a.attisdropped
              )
        LOOP
            EXECUTE format(
                'ALTER TABLE %s DROP COLUMN IF EXISTS %I',
                v_audit_fqn, snap.attname
            );
        END LOOP;

        -- --------------------------------------------------------
        -- Detect RENAMED columns
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname AS new_name,
                   cs.attname AS old_name
            FROM pg_catalog.pg_attribute a
            JOIN pgaudix.column_snapshots cs
              ON cs.table_id = mon.id AND cs.attnum = a.attnum
            WHERE a.attrelid = v_source_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND a.attname != cs.attname
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
                   format_type(a.atttypid, a.atttypmod) AS new_type,
                   cs.atttype AS old_type
            FROM pg_catalog.pg_attribute a
            JOIN pgaudix.column_snapshots cs
              ON cs.table_id = mon.id AND cs.attnum = a.attnum
            WHERE a.attrelid = v_source_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND a.attname = cs.attname
              AND format_type(a.atttypid, a.atttypmod) != cs.atttype
        LOOP
            EXECUTE format(
                'ALTER TABLE %s ALTER COLUMN %I TYPE %s',
                v_audit_fqn, cur.attname, cur.new_type
            );
        END LOOP;

        -- --------------------------------------------------------
        -- Refresh the column snapshot
        -- --------------------------------------------------------
        DELETE FROM pgaudix.column_snapshots WHERE table_id = mon.id;

        INSERT INTO pgaudix.column_snapshots (table_id, attnum, attname, atttype)
        SELECT mon.id, a.attnum, a.attname, format_type(a.atttypid, a.atttypmod)
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = v_source_oid
          AND a.attnum > 0
          AND NOT a.attisdropped;

    END LOOP;
END;
$func$;

-- Create the event trigger
CREATE EVENT TRIGGER pgaudix_ddl_sync
    ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE')
    EXECUTE FUNCTION pgaudix.ddl_sync();
