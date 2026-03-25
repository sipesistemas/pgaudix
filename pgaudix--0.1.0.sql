-- pgaudix: automatic table auditing with column mirroring and DDL sync
-- Version 0.1.0

\echo Use "CREATE EXTENSION pgaudix" to load this file. \quit

-- ============================================================
-- Configuration tables
-- ============================================================

CREATE TABLE pgaudix.monitored_tables (
    id              serial PRIMARY KEY,
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
    LANGUAGE c;

-- ============================================================
-- enable(target_table regclass)
-- ============================================================

CREATE FUNCTION pgaudix.enable(target_table regclass)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pgaudix
AS $func$
DECLARE
    v_schema    name;
    v_table     name;
    v_audit     name;
    v_audit_fqn text;
    v_cols      text := '';
    v_mon_id    int;
    rec         record;
BEGIN
    -- Resolve schema and table name
    SELECT n.nspname, c.relname
    INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE c.oid = target_table;

    IF NOT has_table_privilege(session_user, target_table, 'TRIGGER') THEN
        RAISE EXCEPTION 'pgaudix: permission denied for table %.%', v_schema, v_table;
    END IF;

    IF v_schema = 'information_schema'
       OR v_schema = 'pgaudix'
       OR v_schema LIKE 'pg\_%' ESCAPE '\' THEN
        RAISE EXCEPTION 'pgaudix: auditing is not allowed for schema %', v_schema;
    END IF;

    v_audit := v_table || '_audit';
    v_audit_fqn := format('%I.%I', v_schema, v_audit);

    -- Check not already monitored
    IF EXISTS (
        SELECT 1 FROM pgaudix.monitored_tables
        WHERE source_schema = v_schema AND source_table = v_table
    ) THEN
        RAISE EXCEPTION 'pgaudix: table %.% is already monitored',
            v_schema, v_table;
    END IF;

    -- Check audit table does not already exist
    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = v_schema AND c.relname = v_audit
    ) THEN
        RAISE EXCEPTION 'pgaudix: audit table % already exists', v_audit_fqn;
    END IF;

    -- Build column definitions from source table
    FOR rec IN
        SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type_name,
               a.attnum
        FROM pg_attribute a
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
        '    audit_user          name NOT NULL DEFAULT current_user,'
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

    -- Create the DML audit trigger on the source table
    EXECUTE format(
        'CREATE TRIGGER pgaudix_audit_trigger '
        'AFTER INSERT OR UPDATE OR DELETE ON %I.%I '
        'FOR EACH ROW EXECUTE FUNCTION pgaudix.audit_trigger(%L)',
        v_schema, v_table, v_audit_fqn
    );

    -- Register in monitored_tables
    INSERT INTO pgaudix.monitored_tables
        (source_schema, source_table, audit_schema, audit_table)
    VALUES (v_schema, v_table, v_schema, v_audit)
    RETURNING id INTO v_mon_id;

    -- Take a column snapshot for DDL sync
    INSERT INTO pgaudix.column_snapshots (table_id, attnum, attname, atttype)
    SELECT v_mon_id, a.attnum, a.attname, format_type(a.atttypid, a.atttypmod)
    FROM pg_attribute a
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
SET search_path = pg_catalog, pgaudix
AS $func$
DECLARE
    v_schema    name;
    v_table     name;
    mon         pgaudix.monitored_tables%ROWTYPE;
BEGIN
    -- Resolve schema and table name
    SELECT n.nspname, c.relname
    INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE c.oid = target_table;

    IF NOT has_table_privilege(session_user, target_table, 'TRIGGER') THEN
        RAISE EXCEPTION 'pgaudix: permission denied for table %.%', v_schema, v_table;
    END IF;

    -- Find the registration
    SELECT * INTO mon
    FROM pgaudix.monitored_tables
    WHERE source_schema = v_schema AND source_table = v_table;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgaudix: table %.% is not monitored',
            v_schema, v_table;
    END IF;

    -- Drop the trigger
    EXECUTE format(
        'DROP TRIGGER IF EXISTS pgaudix_audit_trigger ON %I.%I',
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
SET search_path = pg_catalog, pgaudix
AS $func$
DECLARE
    cmd         record;
    mon         record;
    snap        record;
    cur         record;
    v_audit_fqn text;
    v_source_oid oid;
    v_table_identity text;
BEGIN
    FOR cmd IN
        SELECT *
        FROM pg_event_trigger_ddl_commands()
        WHERE command_tag = 'ALTER TABLE'
          AND object_type IN ('table', 'table column')
    LOOP
        -- For 'table column' events (e.g. RENAME COLUMN), the object_identity
        -- includes the column name (e.g. "public.test.col_name").
        -- We need to extract just the schema.table part.
        -- For 'table' events, object_identity is already schema.table.
        IF cmd.object_type = 'table column' THEN
            -- Get the table OID from the column's parent table
            v_source_oid := (
                SELECT a.attrelid FROM pg_attribute a WHERE a.attrelid = cmd.objid
                LIMIT 1
            );
            -- If objid is the table OID (PostgreSQL passes table OID for RENAME COLUMN)
            IF v_source_oid IS NULL THEN
                v_source_oid := cmd.objid;
            END IF;
            -- Build identity from the resolved OID
            SELECT format('%I.%I', n.nspname, c.relname)
            INTO v_table_identity
            FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE c.oid = v_source_oid;
        ELSE
            v_table_identity := cmd.object_identity;
            v_source_oid := cmd.objid;
        END IF;

        -- Check if this table is monitored
        SELECT mt.*
        INTO mon
        FROM pgaudix.monitored_tables mt
        WHERE mt.enabled
          AND v_table_identity = format('%I.%I', mt.source_schema, mt.source_table);

        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        v_audit_fqn := format('%I.%I', mon.audit_schema, mon.audit_table);

        -- --------------------------------------------------------
        -- Detect ADDED columns:
        -- attnum exists in pg_attribute but not in snapshot
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname, format_type(a.atttypid, a.atttypmod) AS atttype
            FROM pg_attribute a
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
        -- Detect DROPPED columns:
        -- attnum in snapshot but now attisdropped in pg_attribute
        -- --------------------------------------------------------
        FOR snap IN
            SELECT cs.attnum, cs.attname
            FROM pgaudix.column_snapshots cs
            WHERE cs.table_id = mon.id
              AND NOT EXISTS (
                  SELECT 1 FROM pg_attribute a
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
        -- Detect RENAMED columns:
        -- same attnum, different name
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname AS new_name,
                   cs.attname AS old_name
            FROM pg_attribute a
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
        -- Detect TYPE CHANGES:
        -- same attnum, same name, different type
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname,
                   format_type(a.atttypid, a.atttypmod) AS new_type,
                   cs.atttype AS old_type
            FROM pg_attribute a
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
        FROM pg_attribute a
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
