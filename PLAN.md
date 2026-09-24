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
    audit_app_user      text DEFAULT current_setting('pgaudix.app_user', true),
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

### SQL install script (`pgaudix--0.2.0.sql`)
- `pgaudix.monitored_tables` — registration table with `source_oid` for OID-based lookup
- `pgaudix.enable(regclass)` — creates audit table (with attnum gap alignment), triggers, registration. Serialized with LOCK TABLE.
- `pgaudix.disable(regclass, bool)` — drops triggers, optionally drops audit table
- `pgaudix.status()` — lists monitored tables
- `pgaudix.truncate_trigger()` — PL/pgSQL AFTER TRUNCATE trigger (statement-level)
- `pgaudix.ddl_sync()` — event trigger for ALTER TABLE / ALTER SCHEMA: detects DROP/ADD/RENAME/TYPE CHANGE columns (attnum order) on the altered tables and their descendants. On RENAME TABLE / SET SCHEMA, renames the audit table and recreates triggers. Warns on direct ALTER of audit tables. Recursion guard: `pgaudix.ddl_guard` table.
- `pgaudix.drop_cleanup()` — sql_drop event trigger removing registry rows of dropped sources
- Helpers: `heal_registry()` (OIDs after restore), `sync_partition_triggers()` (per-leaf TRUNCATE triggers), `audit_type()` (domain base types), `check_table_owner()` / `invoker()` (privilege checks)

### Security
- All SECURITY DEFINER functions use `SET search_path = pgaudix, pg_catalog, pg_temp`
- All functions: `REVOKE EXECUTE FROM PUBLIC`; `enable()`/`disable()` require table ownership
- Audit tables: `REVOKE INSERT, UPDATE, DELETE, TRUNCATE FROM PUBLIC`
- C trigger validates tgargs format
- `enable()` serialized with `LOCK TABLE ... IN EXCLUSIVE MODE`
- `audit_user` uses `session_user` (not `current_user`) for authentic identity

## Test Cases (56 tests + PG18-only virtual generated columns file)

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
15. RENAME TABLE renames audit table + updates triggers + DDL sync
16. SPI error handling (audit failure aborts source DML)
17. NULL values in INSERT and UPDATE
18. Multi-row UPDATE and DELETE
19. Non-public schema
20. Transaction rollback — no audit rows
21. Same audit_txid within a transaction
22. Disable then re-enable
23. Multiple DDL changes in one ALTER
24. Source column with audit_ prefix
25. Enable on non-existent table
26. Disable on non-monitored table
27. Attnum gap alignment (enable on table with dropped columns, DML + DDL sync with gaps)
28. REVOKE includes TRUNCATE
29. Corrupted audit table (missing metadata column) is detected
30. Views and materialized views are rejected
31. Names that would overflow NAMEDATALEN are rejected
32. CHECK constraint on audit_operation
33. DROP TABLE on source removes the registry row
34. ALTER SCHEMA RENAME keeps audit in sync
35. status() integrity columns
36. Registry survives pg_dump/restore (config dump + stale OID healing)
37. ALTER COLUMN TYPE needing USING keeps the source writable (cast, text fallback)
38. Source columns named like gap fillers are left alone
39. pg_temp cannot shadow types used by the API functions
40. DROP and ADD of the same column name in one statement
41. ADD COLUMN order does not depend on the pg_attribute scan plan
42. DDL propagated through inheritance / partitioning is synced
43. Partition-leaf TRUNCATE triggers follow RENAME, ATTACH and DETACH
44. DDL sync and drop cleanup run under replica role
45. The recursion guard cannot be forged by a regular role
46. Functions closed to PUBLIC; enable/disable check ownership
47. One T row per TRUNCATE statement on a partitioned table
48. Domain columns are mirrored with the base type
49. A broken registry row does not affect DDL on other tables
50. The extension's own tables cannot be audited
51. DDL after the first audited row in the same session (plan cache invalidation, partitions)
52. audit_app_user records the application user set via the pgaudix.app_user GUC
53. Dropping the source drops its audit table
54. No dead "enabled" flag in the registry
55. Scenarios inherited from the retired bug-confirmation script (two ALTERs in one txn, SET SCHEMA, multibyte name, 1600 limit, UNLOGGED)
56. Reserved metadata names in ADD / RENAME COLUMN give a clear error
