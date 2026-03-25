# pgaudix — Implementation Plan

## Context

Native PostgreSQL extension for automatic table auditing. For each monitored table, creates a `_audit` table mirroring all columns plus audit metadata. DDL changes on the source table are automatically synced to the audit table via event triggers.

## Design Decisions

- **Storage model**: Single copy of columns, one row per operation with current values. Operations: `I` (insert), `U` (update, new values), `D` (delete, old values), `T` (truncate, NULL data). The "before" values of any UPDATE are the previous audit row.
- **Language**: English for all code, comments, function names, and error messages.
- **Architecture**: Hybrid C + PL/pgSQL. C for DML trigger (performance-critical). PL/pgSQL for API functions, DDL event trigger, and TRUNCATE trigger.

## Audit Table Schema

For source table `public.orders(id int, amount numeric, status text)`:

```sql
CREATE TABLE public.orders_audit (
    audit_id            bigserial PRIMARY KEY,
    audit_operation     char(1) NOT NULL,        -- 'I', 'U', 'D', 'T'
    audit_timestamp     timestamptz NOT NULL DEFAULT clock_timestamp(),
    audit_txid          bigint NOT NULL DEFAULT txid_current(),
    audit_user          name NOT NULL DEFAULT session_user,
    audit_client_addr   inet DEFAULT inet_client_addr(),
    audit_app_name      text DEFAULT current_setting('application_name'),
    -- Mirrored columns
    id                  int,
    amount              numeric,
    status              text
);
CREATE INDEX ON public.orders_audit (audit_timestamp);
```

- INSERT -> 1 row with `audit_operation = 'I'` and new values
- UPDATE -> 1 row with `audit_operation = 'U'` and new values
- DELETE -> 1 row with `audit_operation = 'D'` and old values
- TRUNCATE -> 1 row with `audit_operation = 'T'` and NULL data columns

## Components

### C trigger (`src/pgaudix.c`)
- `pgaudix_trigger()`: AFTER ROW trigger for INSERT/UPDATE/DELETE
- Receives audit table FQN as `tgargs[0]` (force-quoted `"schema"."table"` format)
- Validates tgargs format against SQL injection
- Uses parameterized `SPI_execute_with_args()` with error checking
- `SECURITY DEFINER` with `SET search_path` for audit table write access

### SQL install script (`pgaudix--0.1.0.sql`)
- `pgaudix.monitored_tables` — registration table with `source_oid` for OID-based lookup
- `pgaudix.column_snapshots` — column state for DDL diff detection
- `pgaudix.enable(regclass)` — creates audit table, triggers, registration. Serialized with LOCK TABLE.
- `pgaudix.disable(regclass, bool)` — drops triggers, optionally drops audit table
- `pgaudix.status()` — lists monitored tables
- `pgaudix.truncate_trigger()` — PL/pgSQL AFTER TRUNCATE trigger (statement-level)
- `pgaudix.ddl_sync()` — event trigger for ALTER TABLE: detects ADD/DROP/RENAME/TYPE CHANGE columns and RENAME TABLE. Blocks direct ALTER on audit tables. Uses recursion guard via `set_config`.

### Security
- All SECURITY DEFINER functions use `SET search_path = pgaudix, pg_catalog`
- Audit tables: `REVOKE INSERT, UPDATE, DELETE FROM PUBLIC`
- C trigger validates tgargs format
- `enable()` serialized with `LOCK TABLE ... IN EXCLUSIVE MODE`
- `audit_user` uses `session_user` (not `current_user`) for authentic identity

## Test Cases (16 tests)

1. Enable auditing
2. INSERT audit
3. UPDATE audit (single row, new values)
4. DELETE audit
5. DDL sync: ADD COLUMN
6. DDL sync: RENAME COLUMN
7. DDL sync: ALTER COLUMN TYPE
8. DDL sync: DROP COLUMN
9. Disable auditing (keep data)
10. Disable with drop_data
11. SECURITY DEFINER search_path verification
12. Duplicate enable() rejection
13. TRUNCATE audit
14. Audit table permissions (REVOKE + SECURITY DEFINER trigger)
15. RENAME TABLE continues auditing + DDL sync
16. SPI error handling (audit failure aborts source DML)
