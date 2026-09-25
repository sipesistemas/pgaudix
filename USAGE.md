# pgaudix — Usage

## Install

```sql
CREATE EXTENSION pgaudix;   -- as a superuser
```

To let a non-superuser role manage auditing of its own tables:

```sql
GRANT USAGE ON SCHEMA pgaudix TO app_admin;
GRANT EXECUTE ON FUNCTION pgaudix.enable(regclass),
                          pgaudix.disable(regclass, boolean),
                          pgaudix.status() TO app_admin;
```

## Enable auditing

```sql
SELECT pgaudix.enable('my_table');
```

## Disable auditing

```sql
-- Keep audit data
SELECT pgaudix.disable('my_table');

-- Delete audit data
SELECT pgaudix.disable('my_table', drop_data := true);
```

## Check monitored tables

```sql
SELECT * FROM pgaudix.status();
-- source_schema, source_table, audit_schema, audit_table, created_at,
-- audit_table_exists, dml_trigger_exists, dml_trigger_enabled,
-- truncate_trigger_exists, truncate_trigger_enabled
```

## Query audit data

```sql
SELECT * FROM my_table_audit ORDER BY audit_id;
```

### Filter by operation

```sql
-- Only inserts
SELECT * FROM my_table_audit WHERE audit_operation = 'I';

-- Only updates
SELECT * FROM my_table_audit WHERE audit_operation = 'U';

-- Only deletes
SELECT * FROM my_table_audit WHERE audit_operation = 'D';
```

### Filter by time

```sql
SELECT * FROM my_table_audit
WHERE audit_timestamp >= now() - interval '1 hour';
```

### Filter by user

```sql
-- PostgreSQL role of the connection
SELECT * FROM my_table_audit
WHERE audit_user = 'app_service';

-- Application user and its IP, as set by the application with
--   SET LOCAL pgaudix.app_user = 'user-4711';
--   SET LOCAL pgaudix.app_user_ip = '203.0.113.7';
SELECT * FROM my_table_audit
WHERE audit_app_user = 'user-4711';

SELECT * FROM my_table_audit
WHERE audit_app_user_ip = '203.0.113.7';
```

## Operations reference

| `audit_operation` | Meaning  | Row contains         |
|-------------------|----------|----------------------|
| `I`               | INSERT   | New values           |
| `U`               | UPDATE   | New values           |
| `D`               | DELETE   | Old values           |
| `T`               | TRUNCATE | NULLs (no row data)  |

> The "before" values of any UPDATE are the previous audit row for that record.
