# pgaudix

A native PostgreSQL extension for automatic table auditing. It mirrors table columns into audit tables and automatically keeps them in sync when the source table structure changes.

## Features

- **Automatic audit tables**: creates a `<table>_audit` table with all columns from the source table plus audit metadata
- **DML tracking**: captures every INSERT, UPDATE, and DELETE operation
- **UPDATE detail**: stores two rows per UPDATE — one with old values (`U-`) and one with new values (`U+`)
- **DDL sync**: automatically propagates `ALTER TABLE` changes (add/drop/rename columns, type changes) to the audit table
- **High performance**: the DML trigger is written in C using PostgreSQL's SPI interface

## Requirements

- PostgreSQL 17+
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
| `audit_operation`   | `char(1)`                | `I`, `U`, or `D`               |
| `audit_timestamp`   | `timestamptz`            | When the operation happened     |
| `audit_txid`        | `bigint`                 | Transaction ID                  |
| `audit_user`        | `name`                   | User who performed the action   |
| `audit_client_addr` | `inet`                   | Client IP address               |
| `audit_app_name`    | `text`                   | Application name                |
| `id`                | `integer`                | *(mirrored from source)*        |
| `amount`            | `numeric(10,2)`          | *(mirrored from source)*        |
| `status`            | `text`                   | *(mirrored from source)*        |

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
-- orders_audit column is dropped too
```

### Check monitored tables

```sql
SELECT * FROM pgaudix.status();
--  source_schema | source_table | audit_schema |    audit_table    | enabled |          created_at
-- ---------------+--------------+--------------+-------------------+---------+-------------------------------
--  public        | orders       | public       | orders_audit      | t       | 2026-03-25 12:00:00.000000+00
```

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
| `pgaudix.enable(target_table regclass)` | Start auditing a table. Creates the `_audit` table and trigger. |
| `pgaudix.disable(target_table regclass, drop_data boolean DEFAULT false)` | Stop auditing. Optionally drops the audit table. |
| `pgaudix.status()` | List all monitored tables with their status. |

## Configuration

| GUC Parameter | Default | Description |
|---------------|---------|-------------|
| `pgaudix.log_query` | `off` | When enabled, captures the SQL query text in audit rows. |

```sql
SET pgaudix.log_query = on;
```

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

### Project structure

```
pgaudix/
├── Dockerfile                  # Build environment (postgres:17 + build tools)
├── docker-compose.yml          # Dev environment on port 5433
├── Makefile                    # PGXS build system
├── pgaudix.control            # Extension metadata
├── pgaudix--0.1.0.sql         # SQL install script (PL/pgSQL functions, event triggers)
├── src/
│   ├── pgaudix.h              # Constants and declarations
│   └── pgaudix.c              # C trigger function (SPI-based DML auditing)
└── test/
    ├── sql/
    │   └── pgaudix_test.sql   # Regression test input
    └── expected/
        └── pgaudix_test.out   # Expected test output
```

## Known Limitations

- **TRUNCATE** is not audited (PostgreSQL row-level triggers do not fire for TRUNCATE)
- Source columns starting with `audit_` will work but may cause confusion when reading the audit table
- Maximum of ~796 columns per source table (audit table has mirrored columns + 7 metadata columns, PostgreSQL limit is 1600)

## License

MIT
