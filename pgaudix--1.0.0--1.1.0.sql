-- pgaudix: upgrade from 1.0.0 to 1.1.0
--
-- Adds enable(target_table, audit_schema): the audit table can live in a
-- schema of its own instead of next to the source.

\echo Use "ALTER EXTENSION pgaudix UPDATE TO '1.1.0'" to load this file. \quit

-- Existing registrations keep the 1.0.0 behaviour: the audit table follows
-- the source's schema.
ALTER TABLE pgaudix.monitored_tables
    ADD COLUMN audit_schema_pinned boolean NOT NULL DEFAULT false;

CREATE FUNCTION pgaudix.enable(target_table regclass, audit_schema name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
DECLARE
    v_pinned    boolean := enable.audit_schema IS NOT NULL;
    v_audit_schema name := enable.audit_schema;
    v_invoker   name;
    v_schema    name;
    v_table     name;
    v_audit     name;
    v_audit_fqn text;
    v_audit_tgarg text;
    v_cols      text := '';
    v_relkind   "char";
    v_relpersist "char";
    v_relispart boolean;
    v_inherit   text;
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

    -- Resolve schema, table name, relkind, persistence and partition status
    SELECT n.nspname, c.relname, c.relkind, c.relpersistence, c.relispartition
    INTO v_schema, v_table, v_relkind, v_relpersist, v_relispart
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.oid = target_table;

    -- Partitioned tables and table inheritance are not supported: a
    -- pg_dump/pg_restore of an audited partition tree can lose rows, and one
    -- of an audited inheritance child can leave it unaudited. ddl_sync()
    -- keeps an audited table from joining either later.
    IF v_relkind = 'p' THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: partitioned tables are not supported',
            v_schema, v_table
            USING ERRCODE = 'feature_not_supported';
    END IF;
    IF v_relispart THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: it is a partition of %; partitioned tables are not supported',
            v_schema, v_table,
            (SELECT i.inhparent::regclass FROM pg_catalog.pg_inherits i WHERE i.inhrelid = target_table)
            USING ERRCODE = 'feature_not_supported';
    END IF;

    -- Reject views, materialized views, foreign tables, indexes, sequences, etc. (A5)
    -- Only ordinary tables ('r') are supported.
    IF v_relkind <> 'r' THEN
        RAISE EXCEPTION 'pgaudix: %.% is not a regular table (relkind=%)',
            v_schema, v_table, v_relkind;
    END IF;

    SELECT string_agg(i.inhparent::regclass::text, ', ' ORDER BY i.inhseqno)
    INTO v_inherit
    FROM pg_catalog.pg_inherits i
    WHERE i.inhrelid = target_table;
    IF v_inherit IS NOT NULL THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: it inherits from %; table inheritance (INHERITS) is not supported',
            v_schema, v_table, v_inherit
            USING ERRCODE = 'feature_not_supported';
    END IF;

    SELECT string_agg(i.inhrelid::regclass::text, ', ' ORDER BY i.inhrelid::regclass::text)
    INTO v_inherit
    FROM pg_catalog.pg_inherits i
    WHERE i.inhparent = target_table;
    IF v_inherit IS NOT NULL THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: inherited by %; table inheritance (INHERITS) is not supported',
            v_schema, v_table, v_inherit
            USING ERRCODE = 'feature_not_supported';
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

    IF NOT v_pinned THEN
        v_audit_schema := v_schema;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.nspname = v_audit_schema) THEN
            RAISE EXCEPTION 'pgaudix: audit schema % does not exist', v_audit_schema
                USING ERRCODE = 'invalid_schema_name';
        END IF;
        IF v_audit_schema IN ('pg_catalog', 'information_schema', 'pgaudix')
           OR v_audit_schema LIKE 'pg\_%' ESCAPE '\' THEN
            RAISE EXCEPTION 'pgaudix: % cannot hold audit tables', v_audit_schema;
        END IF;
        -- enable() creates the audit table as the extension owner, so the
        -- schema's own CREATE privilege would never be checked: a table owner
        -- could drop its log into any schema of the database.
        v_invoker := pgaudix.invoker();
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = v_invoker AND r.rolsuper)
           AND NOT pg_catalog.has_schema_privilege(v_invoker, v_audit_schema, 'CREATE') THEN
            RAISE EXCEPTION 'pgaudix: must have CREATE on schema % to put audit tables there', v_audit_schema
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    -- Reject names that would silently truncate past NAMEDATALEN (63 bytes)
    v_audit := pgaudix.audit_name(v_table);

    -- Reject source columns that collide with reserved audit metadata names (bug #7)
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = target_table AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = ANY (pgaudix.reserved_columns())
    ) THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: a source column name collides with a reserved audit metadata column (%)',
            v_schema, v_table, array_to_string(pgaudix.reserved_columns(), ', ');
    END IF;

    -- Reject tables whose attnum span would overflow the audit table column
    -- limit. The audit table reserves one slot per source attnum (gap fillers
    -- included) plus the fixed metadata columns (bug #9).
    SELECT max(att.attnum) INTO v_max_attnum
    FROM pg_catalog.pg_attribute att
    WHERE att.attrelid = target_table AND att.attnum > 0;
    IF v_max_attnum IS NOT NULL AND (9 + v_max_attnum) > 1600 THEN
        RAISE EXCEPTION 'pgaudix: cannot audit %.%: audit table would need % columns (9 metadata + % attnum span), exceeding the 1600-column limit',
            v_schema, v_table, 9 + v_max_attnum, v_max_attnum;
    END IF;

    v_audit_fqn := format('%I.%I', v_audit_schema, v_audit);

    -- Force-quoted form for C trigger argument validation (C2)
    v_audit_tgarg := pgaudix.audit_tgarg(v_audit_schema, v_audit);

    -- Check not already monitored
    IF EXISTS (
        SELECT 1 FROM pgaudix.monitored_tables
        WHERE source_oid = target_table
    ) THEN
        RAISE EXCEPTION 'pgaudix: table %.% is already monitored',
            v_schema, v_table;
    END IF;

    -- A row registered under this name whose source could not be found
    -- (restore that left the table out) is an orphan; its audit table may
    -- still hold history, so it is not silently replaced
    IF EXISTS (
        SELECT 1 FROM pgaudix.monitored_tables
        WHERE (source_schema, source_table) = (v_schema, v_table)
    ) THEN
        RAISE EXCEPTION 'pgaudix: a stale registration of %.% exists (its source table was not found); run pgaudix.disable(%) first',
            v_schema, v_table, quote_literal(format('%I.%I', v_schema, v_table));
    END IF;

    -- Check audit table does not already exist
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = v_audit_schema AND c.relname = v_audit
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
         -- Virtual generated columns (PG18+) have no stored value, so the C
         -- trigger never writes them: they are mirrored as always-NULL columns.
         -- A live column (not a dropped slot) keeps the attnum alignment
         -- across pg_dump/restore, which does not recreate dropped columns.
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

    -- Hold the DDL-sync recursion guard for the rest of enable(): the CREATE
    -- TABLE of the audit table, the ALTERs on it and the ALTER TABLE ...
    -- ENABLE ALWAYS on the source would otherwise fire ddl_sync before the
    -- table is registered.
    INSERT INTO pgaudix.ddl_guard (pid) VALUES (pg_backend_pid())
    ON CONFLICT (pid) DO NOTHING;

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
        '    audit_app_user      text DEFAULT nullif(current_setting(''pgaudix.app_user'', true), ''''),'
        '    audit_app_user_ip   text DEFAULT nullif(current_setting(''pgaudix.app_user_ip'', true), '''')'
        '    %s'
        ')',
        CASE WHEN v_relpersist = 'u' THEN 'UNLOGGED' ELSE '' END,
        v_audit_fqn, v_cols
    );

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
    WHERE n.nspname = v_audit_schema AND c.relname = v_audit;

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

    -- Create the TRUNCATE audit trigger (M1), also ENABLE ALWAYS (bug #4).
    -- BEFORE on a partitioned table, AFTER on a plain one (see truncate_trigger())
    EXECUTE format(
        'CREATE TRIGGER pgaudix_truncate_trigger '
        '%s TRUNCATE ON %I.%I '
        'FOR EACH STATEMENT EXECUTE FUNCTION pgaudix.truncate_trigger(%L, %L)',
        CASE WHEN v_relkind = 'p' THEN 'BEFORE' ELSE 'AFTER' END,
        v_schema, v_table, v_audit_schema, v_audit
    );
    EXECUTE format(
        'ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER pgaudix_truncate_trigger',
        v_schema, v_table
    );

    -- Register in monitored_tables (with source + audit OID for H2 / bug #2)
    INSERT INTO pgaudix.monitored_tables
        (source_oid, source_schema, source_table, audit_schema, audit_table, audit_oid,
         audit_schema_pinned)
    VALUES (target_table, v_schema, v_table, v_audit_schema, v_audit, v_audit_oid, v_pinned);

    -- For a partitioned table, the statement-level TRUNCATE trigger on the root
    -- does NOT fire when an individual partition is truncated directly, so each
    -- leaf gets its own trigger (bug #5). Leaves attached or detached later are
    -- reconciled by ddl_sync through the same function.
    PERFORM pgaudix.sync_partition_triggers();

    DELETE FROM pgaudix.ddl_guard WHERE pid = pg_backend_pid();
END;
$func$;

-- The 1.0.0 signature, kept so existing GRANTs on it keep working
CREATE OR REPLACE FUNCTION pgaudix.enable(target_table regclass)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pgaudix, pg_catalog, pg_temp
AS $func$
    SELECT pgaudix.enable(target_table, NULL::pg_catalog.name);
$func$;

CREATE OR REPLACE FUNCTION pgaudix.ddl_sync()
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
    v_new_audit_schema name;
    v_cur_audit_schema name;
    v_cur_audit_name   name;
    v_altered_tables   oid[];   -- tables named by ALTER TABLE, plus descendants
    v_affected_tables  oid[];   -- those, plus every table of a schema named by ALTER SCHEMA
    v_created_tables   oid[];   -- tables named by CREATE TABLE (new partitions)
BEGIN
    -- Guard against recursive invocations from our own ALTERs on audit tables
    -- (see pgaudix.ddl_guard). The row MUST be removed before returning (bug #1)
    -- so later DDL in the same transaction is synced normally.
    IF EXISTS (SELECT 1 FROM pgaudix.ddl_guard WHERE pid = pg_backend_pid()) THEN
        RETURN;
    END IF;

    -- One pass over the command list. pg_event_trigger_ddl_commands()
    -- reports only the table named in an ALTER TABLE: column changes
    -- propagate to inheritance children and partitions, so every altered
    -- table is expanded to all its descendants. ALTER SCHEMA (rename) moves
    -- every table of the schema at once. CREATE TABLE ... PARTITION OF adds
    -- a leaf to a tree; it only matters for the per-leaf TRUNCATE trigger
    -- reconciliation below.
    WITH RECURSIVE cmds AS (
        SELECT dc.command_tag, dc.object_type, dc.objid
        FROM pg_event_trigger_ddl_commands() dc
        WHERE (dc.command_tag = 'ALTER TABLE' AND dc.object_type IN ('table', 'table column'))
           OR dc.command_tag = 'ALTER SCHEMA'
           OR (dc.command_tag = 'CREATE TABLE' AND dc.object_type = 'table')
    ),
    altered(relid) AS (
        SELECT objid FROM cmds WHERE command_tag = 'ALTER TABLE'
        UNION
        SELECT i.inhrelid
        FROM pg_catalog.pg_inherits i
        JOIN altered a ON i.inhparent = a.relid
    ),
    in_schema(relid) AS (
        SELECT c.oid
        FROM cmds
        JOIN pg_catalog.pg_class c ON c.relnamespace = cmds.objid
        WHERE cmds.command_tag = 'ALTER SCHEMA'
          AND c.relkind IN ('r', 'p')
    )
    SELECT (SELECT coalesce(array_agg(relid), '{}') FROM altered),
           (SELECT coalesce(array_agg(relid), '{}') FROM in_schema)
               || (SELECT coalesce(array_agg(relid), '{}') FROM altered),
           (SELECT coalesce(array_agg(objid), '{}') FROM cmds WHERE command_tag = 'CREATE TABLE')
    INTO v_altered_tables, v_affected_tables, v_created_tables;

    -- Nothing to do unless the command touched a monitored table, an audit
    -- table, or a relation under a monitored partitioned root. Matched by
    -- OID and by name (after a restore the registered OIDs are stale). This
    -- keeps every unrelated CREATE TABLE / ALTER TABLE in the database (temp
    -- tables included) free of registry writes and the guard row.
    IF NOT EXISTS (
        WITH RECURSIVE up(relid) AS (
            SELECT relid FROM unnest(v_affected_tables || v_created_tables) AS t(relid)
            UNION
            SELECT i.inhparent
            FROM pg_catalog.pg_inherits i
            JOIN up ON i.inhrelid = up.relid
        ),
        named AS (
            SELECT up.relid, n.nspname, c.relname
            FROM up
            JOIN pg_catalog.pg_class c ON c.oid = up.relid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        )
        SELECT 1
        FROM pgaudix.monitored_tables mt
        JOIN named ON named.relid IN (mt.source_oid, mt.audit_oid)
                   OR (named.nspname, named.relname) IN ((mt.source_schema, mt.source_table),
                                                         (mt.audit_schema, mt.audit_table))
    ) THEN
        RETURN;
    END IF;

    INSERT INTO pgaudix.ddl_guard (pid) VALUES (pg_backend_pid());

    -- Re-bind registry rows whose OIDs went stale (pg_dump/restore)
    PERFORM pgaudix.heal_registry();

    -- Partitioned tables and table inheritance are not supported (see
    -- enable()): refuse a command that made an audited table a partition,
    -- an inheritance child or an inheritance parent (ATTACH PARTITION,
    -- INHERIT, CREATE TABLE ... INHERITS). The command's tables, their
    -- descendants and their ancestors cover every way in.
    FOR cur IN
        SELECT mt.source_schema, mt.source_table
        FROM pgaudix.monitored_tables mt
        WHERE mt.source_oid IN (
                  WITH RECURSIVE up(relid) AS (
                      SELECT relid FROM unnest(v_affected_tables || v_created_tables) AS t(relid)
                      UNION
                      SELECT i.inhparent
                      FROM pg_catalog.pg_inherits i
                      JOIN up ON i.inhrelid = up.relid
                  )
                  SELECT relid FROM up
              )
          AND EXISTS (
                  SELECT 1 FROM pg_catalog.pg_inherits i
                  WHERE i.inhrelid = mt.source_oid OR i.inhparent = mt.source_oid
              )
        ORDER BY mt.id
    LOOP
        RAISE EXCEPTION 'pgaudix: %.% is audited and cannot be part of a partition tree or an inheritance hierarchy (not supported); run pgaudix.disable(%) first',
            cur.source_schema, cur.source_table,
            quote_literal(format('%I.%I', cur.source_schema, cur.source_table))
            USING ERRCODE = 'feature_not_supported';
    END LOOP;

    -- ----------------------------------------------------------------
    -- Pre-pass: sync source_schema / source_table / audit_schema /
    -- audit_table for the monitored entries touched by this command
    -- whose current pg_class name no longer matches the registration.
    -- Covers RENAME TABLE, SET SCHEMA and ALTER SCHEMA RENAME (A2, H2),
    -- of the source and of its audit table (a pinned audit schema is
    -- renamed apart from the source's). Only the affected tables are
    -- examined: a registry row that is out of sync (audit table dropped,
    -- audit name taken) must not break or lock DDL on unrelated tables.
    -- ----------------------------------------------------------------
    FOR mon IN
        SELECT mt.* FROM pgaudix.monitored_tables mt
        WHERE mt.source_oid = ANY (v_affected_tables)
           OR mt.audit_oid = ANY (v_affected_tables)
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

        -- Not our table (stale OID reused after a restore): leave it alone
        CONTINUE WHEN NOT pgaudix.is_source_of(mon.source_oid, mon.audit_schema, mon.audit_table);

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

        -- Raises if the new source name leaves no room for the suffix
        v_new_audit := pgaudix.audit_name(v_new_table);

        -- A pinned audit table stays in whatever schema it is in now (moved
        -- or renamed along with its schema); otherwise it follows the source
        v_new_audit_schema := CASE WHEN mon.audit_schema_pinned
                                   THEN v_cur_audit_schema ELSE v_new_schema END;

        -- Nothing changed: source name/schema and audit name/schema all match
        -- the catalog and the registration
        IF v_new_schema = mon.source_schema AND v_new_table = mon.source_table
           AND v_cur_audit_schema = v_new_audit_schema
           AND v_cur_audit_name   = v_new_audit
           AND mon.audit_schema   = v_new_audit_schema
           AND mon.audit_table    = v_new_audit THEN
            CONTINUE;
        END IF;

        -- The new name must be free. A stale registration of it (source lost
        -- on a restore) may still own an audit table with history: adopting
        -- that name would leave two rows claiming one table. A relation
        -- already using the new audit name is refused for the same reason,
        -- with a clearer message than the RENAME's own.
        IF EXISTS (
            SELECT 1 FROM pgaudix.monitored_tables o
            WHERE o.id <> mon.id
              AND (o.source_schema, o.source_table) = (v_new_schema, v_new_table)
        ) THEN
            RAISE EXCEPTION 'pgaudix: cannot rename %.% to %.%: a stale registration of that name exists (its source table was not found); run pgaudix.disable(%) first',
                mon.source_schema, mon.source_table, v_new_schema, v_new_table,
                quote_literal(format('%I.%I', v_new_schema, v_new_table));
        END IF;
        IF EXISTS (
            SELECT 1 FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
            WHERE n.nspname = v_new_audit_schema AND c.relname = v_new_audit
              AND c.oid <> mon.audit_oid
        ) THEN
            RAISE EXCEPTION 'pgaudix: cannot rename %.% to %.%: audit table %.% already exists',
                mon.source_schema, mon.source_table, v_new_schema, v_new_table,
                v_new_audit_schema, v_new_audit;
        END IF;

        -- Move an unpinned audit table into the source's (possibly new) schema.
        -- Required for ALTER TABLE ... SET SCHEMA, where only the source moves
        -- (bug #2). For ALTER SCHEMA RENAME the audit table already moved with
        -- the schema, so this is a no-op.
        IF v_cur_audit_schema <> v_new_audit_schema THEN
            EXECUTE format(
                'ALTER TABLE %I.%I SET SCHEMA %I',
                v_cur_audit_schema, v_cur_audit_name, v_new_audit_schema
            );
            v_cur_audit_schema := v_new_audit_schema;
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

        v_new_tgarg := pgaudix.audit_tgarg(v_new_audit_schema, v_new_audit);

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
            '%s TRUNCATE ON %I.%I '
            'FOR EACH STATEMENT EXECUTE FUNCTION pgaudix.truncate_trigger(%L, %L)',
            (SELECT CASE WHEN c.relkind = 'p' THEN 'BEFORE' ELSE 'AFTER' END
             FROM pg_catalog.pg_class c WHERE c.oid = mon.source_oid),
            v_new_schema, v_new_table, v_new_audit_schema, v_new_audit
        );
        EXECUTE format(
            'ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER pgaudix_truncate_trigger',
            v_new_schema, v_new_table
        );

        UPDATE pgaudix.monitored_tables
        SET source_schema = v_new_schema, source_table = v_new_table,
            audit_schema = v_new_audit_schema, audit_table = v_new_audit
        WHERE id = mon.id;

        RAISE NOTICE 'pgaudix: synchronized audit registration to %.%',
            v_new_audit_schema, v_new_audit;
    END LOOP;

    -- Reconcile per-leaf TRUNCATE triggers: covers RENAME / SET SCHEMA of a
    -- partitioned root (new audit name), ATTACH / DETACH PARTITION and
    -- CREATE TABLE ... PARTITION OF. Only when the command touched a monitored
    -- partitioned root or a table under one (walking up pg_inherits from the
    -- affected tables is cheap; scanning every monitored tree on every ALTER
    -- TABLE in the database is not).
    IF EXISTS (
        WITH RECURSIVE up(relid) AS (
            SELECT relid FROM unnest(v_affected_tables || v_created_tables) AS t(relid)
            UNION
            SELECT i.inhparent
            FROM pg_catalog.pg_inherits i
            JOIN up ON i.inhrelid = up.relid
        )
        SELECT 1
        FROM up
        JOIN pgaudix.monitored_tables mt ON mt.source_oid = up.relid
        JOIN pg_catalog.pg_class c ON c.oid = mt.source_oid
        WHERE c.relkind = 'p'
    ) THEN
        PERFORM pgaudix.sync_partition_triggers();
    END IF;

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

        -- A registered OID that was reused by another relation after a
        -- restore (and could not be healed because the real source lost its
        -- trigger) must not have its columns mirrored into the audit table.
        IF NOT pgaudix.is_source_of(v_source_oid, mon.audit_schema, mon.audit_table) THEN
            RAISE WARNING 'pgaudix: %.% is registered but carries no pgaudix_audit_trigger; DDL not synced to the audit table',
                mon.source_schema, mon.source_table;
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
        -- last metadata column (audit_app_user_ip)
        SELECT a.attnum INTO v_offset
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = v_audit_oid
          AND a.attname = 'audit_app_user_ip'
          AND NOT a.attisdropped;

        IF v_offset IS NULL THEN
            RAISE EXCEPTION 'pgaudix: audit table % is corrupted (audit_app_user_ip column missing) — cannot sync DDL',
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
              AND a.attname = ANY (pgaudix.reserved_columns())
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
        -- attnums line up with the source's regardless of the scan plan).
        -- A dropped attribute at the source column's slot is not a mirror
        -- of it: the DML trigger would fail on the missing column.
        -- --------------------------------------------------------
        FOR cur IN
            SELECT a.attnum, a.attname,
                   pgaudix.audit_type(a.atttypid, a.atttypmod) AS atttype
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
            ORDER BY a.attnum
        LOOP
            -- A virtual generated column (PG18+) is added like any other: the
            -- C trigger never writes it, so it stays NULL, but as a live column
            -- it keeps the attnum alignment across pg_dump/restore.
            EXECUTE format(
                'ALTER TABLE %s ADD COLUMN %I %s',
                v_audit_fqn, cur.attname, cur.atttype
            );

            -- The new column must land on the source column's slot, or the
            -- attnum mapping that drives RENAME / TYPE detection is lost for
            -- good (attnums are never recycled). The slot is taken when a
            -- column was added and dropped, or a mirrored column dropped,
            -- directly on the audit table. Refuse the DDL rather than leave a
            -- misaligned mirror whose columns would later be renamed astray.
            IF (SELECT aud.attnum FROM pg_catalog.pg_attribute aud
                WHERE aud.attrelid = v_audit_oid AND aud.attname = cur.attname
                  AND NOT aud.attisdropped) <> cur.attnum + v_offset THEN
                RAISE EXCEPTION 'pgaudix: audit table % is out of alignment with %.%: column % cannot take attnum % (the slot belongs to a column dropped directly from the audit table); rename the audit table to keep its history, then run pgaudix.disable(%) and pgaudix.enable(%) to rebuild it',
                    v_audit_fqn, mon.source_schema, mon.source_table,
                    cur.attname, cur.attnum + v_offset,
                    quote_literal(format('%I.%I', mon.source_schema, mon.source_table)),
                    quote_literal(format('%I.%I', mon.source_schema, mon.source_table));
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
            SELECT p.attnum, p.attname, p.new_type, p.audit_type
            FROM (
                -- audit_type() walks pg_type recursively: evaluate it once
                -- per column pair (OFFSET 0 keeps the planner from inlining
                -- the subquery and repeating the calls in the filter)
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
                  -- A text audit column accepts any value through the
                  -- assignment cast the C trigger relies on, so it is never
                  -- narrowed or changed again (this is also the fallback
                  -- type used below).
                  AND aud.atttypid <> 'pg_catalog.text'::regtype
                OFFSET 0
            ) p
            WHERE p.new_type != p.audit_type
            ORDER BY p.attnum
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

REVOKE EXECUTE ON FUNCTION pgaudix.enable(regclass, name) FROM PUBLIC;
