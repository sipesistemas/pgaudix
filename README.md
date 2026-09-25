# pgaudix

A native PostgreSQL extension for automatic table auditing. It mirrors table columns into audit tables and automatically keeps them in sync when the source table structure changes.

## Features

- **Automatic audit tables**: creates a `<table>_audit` table with all columns from the source table plus audit metadata
- **DML tracking**: captures every INSERT, UPDATE, DELETE, and TRUNCATE operation
- **Single-row audit**: one audit row per operation with current values (`I`, `U`, `D`, `T`)
- **DDL sync**: automatically propagates `ALTER TABLE` changes (add/drop/rename columns, type changes) to the audit table, including table renames
- **High performance**: the DML trigger is written in C using PostgreSQL's SPI interface
- **Write-protected audit tables**: audit tables are locked down — only the trigger can write to them

## Requirements

- PostgreSQL 16+
- Docker (for development)

## Quick Start

### 1. Start the development environment

```bash
docker compose up --build -d
```

This builds the extension inside a PostgreSQL 17 container and starts it on **port 5433**.

### 2. Connect to the database

```bash
docker compose exec pgaudix psql -U postgres -d pgaudix_dev
```

Or connect from any PostgreSQL client:

| Parameter | Value           |
|-----------|-----------------|
| Host      | `localhost`     |
| Port      | `5433`          |
| Database  | `pgaudix_dev`  |
| User      | `postgres`      |
| Password  | *(none)*        |

### 3. Enable the extension

```sql
CREATE EXTENSION pgaudix;
```

> The extension must be created once per database. To make it available in every new database, install it in `template1`.

## Usage

### Enable auditing on a table

```sql
CREATE TABLE orders (
    id      serial PRIMARY KEY,
    amount  numeric(10,2),
    status  text
);

SELECT pgaudix.enable('orders');
```

This creates `orders_audit` in the same schema with:

| Column              | Type                     | Description                     |
|---------------------|--------------------------|---------------------------------|
| `audit_id`          | `bigserial`              | Unique audit row identifier     |
| `audit_operation`   | `char(1)`                | `I`, `U`, `D`, or `T`          |
| `audit_timestamp`   | `timestamptz`            | When the operation happened     |
| `audit_txid`        | `bigint`                 | Transaction ID                  |
| `audit_user`        | `name`                   | User who performed the action   |
| `audit_client_addr` | `inet`                   | Client IP address               |
| `audit_app_name`    | `text`                   | Application name                |
| `audit_app_user`    | `text`                   | Application user, see below     |
| `audit_app_user_ip` | `text`                   | Application user's IP, see below |
| `id`                | `integer`                | *(mirrored from source)*        |
| `amount`            | `numeric(10,2)`          | *(mirrored from source)*        |
| `status`            | `text`                   | *(mirrored from source)*        |

### Identifying the application user

`audit_user` is the PostgreSQL role of the connection and `audit_client_addr` is the address it came from. An application that connects with a single role (the usual SaaS setup) records that role and its own server address on every row, so it also reports the end user, and the end user's address, through session variables, once per transaction or request:

```sql
BEGIN;
SET LOCAL pgaudix.app_user = 'user-4711';       -- or: SELECT set_config('pgaudix.app_user', 'user-4711', true);
SET LOCAL pgaudix.app_user_ip = '203.0.113.7';  -- optional
UPDATE orders SET status = 'shipped' WHERE id = 1;
COMMIT;
```

The audit row stores them in `audit_app_user` and `audit_app_user_ip`; each is NULL when nothing was set (an empty string counts as unset, since PostgreSQL reports a custom setting as `''` once the session has ever set it). `SET LOCAL` ends with the transaction, so connection pools are safe. Both are free text: the values are whatever the application declares (the IP may be a proxy list such as `203.0.113.7, 10.0.0.2`), so trust them as much as you trust the application; `audit_user` and `audit_client_addr` remain the authenticated identity and connection address.

### How operations are recorded

**INSERT** — one audit row:

```sql
INSERT INTO orders (amount, status) VALUES (100.50, 'pending');

SELECT audit_operation, id, amount, status FROM orders_audit;
--  audit_operation | id | amount | status
-- ----------------+----+--------+---------
--  I               |  1 | 100.50 | pending
```

**UPDATE** — one audit row with the new values:

```sql
UPDATE orders SET status = 'shipped', amount = 105.00 WHERE id = 1;

SELECT audit_operation, id, amount, status FROM orders_audit ORDER BY audit_id;
--  audit_operation | id | amount | status
-- ----------------+----+--------+---------
--  I               |  1 | 100.50 | pending
--  U               |  1 | 105.00 | shipped
```

> The "before" values of any UPDATE are the previous audit row for that record — no need to store them twice.

**DELETE** — one audit row with the deleted values:

```sql
DELETE FROM orders WHERE id = 1;

SELECT audit_operation, id, amount, status FROM orders_audit ORDER BY audit_id;
--  audit_operation | id | amount | status
-- ----------------+----+--------+---------
--  I               |  1 | 100.50 | pending
--  U               |  1 | 105.00 | shipped
--  D               |  1 | 105.00 | shipped
```

**TRUNCATE** — one audit row with NULL data columns:

```sql
TRUNCATE orders;

SELECT audit_operation, id, amount, status FROM orders_audit ORDER BY audit_id;
--  audit_operation | id | amount | status
-- ----------------+----+--------+---------
--  ...previous rows...
--  T               |    |        |
```

> TRUNCATE cannot capture individual row values (PostgreSQL limitation), but pgaudix records that a TRUNCATE happened.

### Automatic DDL sync

When you alter the source table, the audit table is updated automatically:

```sql
-- Add a column
ALTER TABLE orders ADD COLUMN notes text;
-- orders_audit now also has a "notes" column

-- Rename a column
ALTER TABLE orders RENAME COLUMN notes TO description;
-- orders_audit column is renamed too

-- Change a column type
ALTER TABLE orders ALTER COLUMN amount TYPE numeric(12,4);
-- orders_audit column type is updated too

-- Drop a column
ALTER TABLE orders DROP COLUMN description;
-- orders_audit column is dropped too (its audit history goes with it)

-- Rename the table
ALTER TABLE orders RENAME TO orders_v2;
-- orders_audit is renamed to orders_v2_audit, triggers updated automatically
```

Details worth knowing:

- **Type changes** are applied to the audit table with an explicit cast (`USING column::newtype`). If the audit history cannot be converted (for example `int` to `uuid`, or narrowing `text` to `varchar(3)` with longer values already logged), the audit column is converted to `text` instead and a `WARNING` is raised: history is preserved and auditing keeps working. An audit column of type `text` is never changed again.
- **Domains** are mirrored with their base type (`numeric(8,2)` for a domain over it), so `NOT NULL` or `CHECK` constraints of the domain do not reject the NULL data of `T` rows.
- **Inheritance and partitions**: changes made through a parent table (`ALTER TABLE parent ADD COLUMN`) are synced to audited children and partitions.
- **Partitioned tables**: every partition gets a `TRUNCATE` trigger so that truncating a partition directly is audited. Partitions created, attached or detached later, and renames of the root, are reconciled automatically. Each `TRUNCATE` writes a single `T` row, whether it names the root or one partition, and every `TRUNCATE` is recorded, also when several run inside one function or `DO` block.
- **Generated columns**: stored generated columns are mirrored with their values. Virtual generated columns (PostgreSQL 18+) have no stored value, so their audit column is always `NULL`; derive the value from the audited columns when needed.
- **`session_replication_role = replica`**: DML, TRUNCATE and DDL sync keep working (all triggers are `ENABLE ALWAYS`).

### Check monitored tables

```sql
SELECT source_table, audit_table, audit_table_exists, dml_trigger_enabled, truncate_trigger_enabled
FROM pgaudix.status();
--  source_table | audit_table  | audit_table_exists | dml_trigger_enabled | truncate_trigger_enabled
-- --------------+--------------+--------------------+---------------------+--------------------------
--  orders       | orders_audit | t                  | t                   | t
```

`status()` returns one row per monitored table with `source_schema`, `source_table`, `audit_schema`, `audit_table`, `created_at`, plus integrity checks: `audit_table_exists`, `dml_trigger_exists`, `dml_trigger_enabled`, `truncate_trigger_exists` and `truncate_trigger_enabled`. A `false` in any of the last five means someone changed the audit objects behind pgaudix's back. `status()` is read-only, so it also works on a hot standby and inside a read-only transaction.

### Disable auditing

```sql
-- Stop auditing but keep the audit data
SELECT pgaudix.disable('orders');

-- Stop auditing and drop the audit table
SELECT pgaudix.disable('orders', drop_data := true);
```

## API Reference

| Function | Description |
|----------|-------------|
| `pgaudix.enable(target_table regclass)` | Start auditing a table. Creates the `_audit` table and triggers. Caller must own the table or be a superuser. |
| `pgaudix.disable(target_table regclass, drop_data boolean DEFAULT false)` | Stop auditing. Optionally drops the audit table. Same ownership rule. |
| `pgaudix.status()` | List all monitored tables with integrity checks. |

### Privileges

`CREATE EXTENSION pgaudix` requires a superuser. None of the functions is executable by `PUBLIC`. To let a role manage auditing of the tables it owns:

```sql
GRANT USAGE ON SCHEMA pgaudix TO app_admin;
GRANT EXECUTE ON FUNCTION pgaudix.enable(regclass),
                          pgaudix.disable(regclass, boolean),
                          pgaudix.status() TO app_admin;
```

Audit tables are owned by the extension owner. Grant `SELECT` on `<table>_audit` explicitly to whoever needs to read the log.

### Backup and restore

The registry is dumped by `pg_dump` together with the audit tables and triggers. After a restore, pgaudix re-resolves the tables by name on first use (also when an old OID was reused by an unrelated table in the new cluster), so `status()`, `disable()` and DDL sync keep working without manual steps. A registration whose source table was not restored is kept as an orphan (`status()` shows it without a DML trigger); `pgaudix.disable('schema.table', drop_data := true)` removes it, and is required before a new table of that name can be enabled.

## Development

### Rebuild after code changes

```bash
docker compose exec pgaudix bash -c "cd /pgaudix && make USE_PGXS=1 install"
```

Then reconnect or reload the extension:

```sql
-- In a new psql session, the updated .so is loaded automatically
```

### Run regression tests

```bash
docker compose exec pgaudix bash -c "cd /pgaudix && make USE_PGXS=1 installcheck"
```

### Benchmark

`make USE_PGXS=1 bench` runs `test/bench.sql`: 200k-row INSERT, UPDATE and DELETE on a 6-column table with and without auditing, best of three rounds. It is a measurement, not a CI test: numbers depend on the machine, so compare runs on the same host. Reference on a developer laptop (PostgreSQL 17 in Docker):

| Operation | No audit | Audited | Audit cost per row |
|-----------|---------:|--------:|-------------------:|
| INSERT    |    84 ms | 1319 ms |             6.2 µs |
| UPDATE    |   110 ms | 1375 ms |             6.3 µs |
| DELETE    |    37 ms | 1294 ms |             6.3 µs |

The remaining cost is the INSERT into the audit table (primary key and timestamp index); the trigger caches its plan per relation.

### Project structure

```
pgaudix/
├── Dockerfile                  # Build environment (postgres:17 + build tools)
├── docker-compose.yml          # Dev environment on port 5433
├── Makefile                    # PGXS build system
├── pgaudix.control            # Extension metadata
├── pgaudix--0.3.0.sql         # SQL install script (PL/pgSQL functions, event triggers)
├── install.sh / install.bat   # Install a release build (Linux/macOS, Windows)
├── src/
│   ├── pgaudix.h              # Constants and declarations
│   └── pgaudix.c              # C trigger function (SPI-based DML auditing)
├── test/
│   ├── bench.sql                   # Benchmark (make bench)
│   ├── sql/
│   │   ├── pgaudix_test.sql        # Regression test input
│   │   └── pgaudix_generated.sql   # PostgreSQL 18+ only (virtual generated columns)
│   └── expected/
│       ├── pgaudix_test.out
│       └── pgaudix_generated.out
└── .github/workflows/          # CI (tests on PG 16/17/18) and release builds
```

## Security

- All functions use `SECURITY DEFINER` with `SET search_path = pgaudix, pg_catalog, pg_temp` (`pg_temp` last, so temporary objects cannot shadow types or functions)
- No function is executable by `PUBLIC`; `enable()` and `disable()` also require the caller to own the target table (see *Privileges*)
- The trigger functions cannot be attached to other tables by non-superusers, so audit rows cannot be forged
- The C trigger function validates its arguments against injection attacks
- Audit tables are protected: `INSERT`, `UPDATE`, `DELETE` and `TRUNCATE` are revoked from `PUBLIC` — only the trigger (running as `SECURITY DEFINER`) can write audit rows
- The DDL-sync recursion guard is a table in the `pgaudix` schema, not a settable parameter, so it cannot be used to switch the sync off
- The `audit_user` column captures `session_user` (the authenticated identity) rather than `current_user`, so it cannot be spoofed via `SET ROLE`
- Concurrent `enable()` calls are serialized with an explicit lock to prevent race conditions
- The `enable()` function rejects duplicate registrations
- Direct `ALTER TABLE` on audit tables produces a warning

## Known Limitations

- TRUNCATE is audited at the statement level (operation `T`) but individual row values cannot be captured (PostgreSQL limitation)
- Source columns starting with `audit_` will work but may cause confusion when reading the audit table; the nine metadata names themselves (see `pgaudix.reserved_columns()`) are rejected
- The audit table reserves one column slot per source attnum (dropped columns included) plus 9 metadata columns, so the source's highest attnum must be at most 1591 (PostgreSQL limit is 1600)
- Dropping a source column drops the mirrored column and its history; dropping a source table drops its audit table (use `disable()` first to keep the data)
- An UPDATE that moves a row between partitions is recorded as `D` + `I` (PostgreSQL fires no UPDATE trigger for it)
- `audit_user` is `session_user`; actions performed after `SET ROLE` are attributed to the login role (use `audit_app_user` to identify the acting user)
- The Windows build is compiled with MSYS2/mingw and tested against the MSYS2 PostgreSQL; loading it into an EDB (MSVC) installation has not been verified
- There is no automatic retention: audit tables grow until a superuser deletes old rows (`DELETE FROM orders_audit WHERE audit_timestamp < ...`). Renaming an audit table by hand is reverted by the DDL sync on purpose; use `disable()` first if you need to move it

## License

MIT
