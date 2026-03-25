# pgaudix — PostgreSQL Audit Extension

## Context

Create a native PostgreSQL extension from scratch that provides automatic table auditing. For each monitored table, it creates a `_audit` table mirroring all columns plus audit metadata. DDL changes (ALTER TABLE) on the source table are automatically synced to the audit table via event triggers.

## Design Decisions

- **Storage model**: Single copy of columns + two rows for UPDATE (`U-` old values, `U+` new values). INSERT = 1 row, DELETE = 1 row.
- **Language**: English for all code, comments, function names, and error messages.
- **Architecture**: Hybrid C + PL/pgSQL. C for the DML trigger (performance-critical, fires every row). PL/pgSQL for API functions and DDL event trigger (runs rarely, complex dynamic SQL).

## Development Environment

Docker-based. PostgreSQL runs inside a container. The extension source is mounted as a volume, built and installed inside the container.

- **Port**: 5433 (not 5432 to avoid conflicts)
- **Files**: `Dockerfile`, `docker-compose.yml`

## File Structure

```
pgaudix/
├── Dockerfile                  # Build env: postgres + build-essential + pgxs
├── docker-compose.yml          # PostgreSQL on port 5433, source mounted
├── Makefile                    # PGXS build system
├── pgaudix.control            # Extension metadata (v0.1.0)
├── pgaudix--0.1.0.sql         # Install script (schema, functions, triggers)
├── src/
│   ├── pgaudix.h              # Shared declarations
│   └── pgaudix.c              # DML trigger function (C/SPI)
└── test/
    ├── sql/
    │   └── pgaudix_test.sql   # Regression tests
    └── expected/
        └── pgaudix_test.out   # Expected output
```

## Audit Table Schema

For source table `public.orders(id int, amount numeric, status text)`:

```sql
CREATE TABLE public.orders_audit (
    audit_id            bigserial PRIMARY KEY,
    audit_operation     char(2) NOT NULL,        -- 'I', 'U-', 'U+', 'D'
    audit_timestamp     timestamptz NOT NULL DEFAULT clock_timestamp(),
    audit_txid          bigint NOT NULL DEFAULT txid_current(),
    audit_user          name NOT NULL DEFAULT current_user,
    audit_client_addr   inet DEFAULT inet_client_addr(),
    audit_app_name      text DEFAULT current_setting('application_name'),
    -- Mirrored columns (single copy)
    id                  int,
    amount              numeric,
    status              text
);
CREATE INDEX ON public.orders_audit (audit_timestamp);
```

- INSERT → 1 row with `audit_operation = 'I'` and new values
- UPDATE → 2 rows: `'U-'` with OLD values, `'U+'` with NEW values
- DELETE → 1 row with `audit_operation = 'D'` and old values

## Implementation Steps

### Step 0: Docker setup
**Files**: `Dockerfile`, `docker-compose.yml`

- `Dockerfile`: Based on `postgres:17`, installs `build-essential`, `postgresql-server-dev-17`. Copies extension source, builds and installs it.
- `docker-compose.yml`: Service `pgaudix` on port **5433:5432**. Mounts `./` to `/pgaudix` in container. Environment: `POSTGRES_PASSWORD`, `POSTGRES_DB=pgaudix_dev`.

**Workflow**:
```bash
docker compose up --build         # Build extension + start PostgreSQL
docker compose exec pgaudix psql -U postgres -d pgaudix_dev  # Connect
docker compose exec pgaudix bash -c "cd /pgaudix && make USE_PGXS=1 install"  # Rebuild
docker compose exec pgaudix bash -c "cd /pgaudix && make USE_PGXS=1 installcheck"  # Tests
```

### Step 1: Build skeleton
**Files**: `Makefile`, `pgaudix.control`, `src/pgaudix.h`

- `Makefile` with PGXS, `MODULE_big = pgaudix`, `OBJS = src/pgaudix.o`
- `.control`: `default_version = '0.1.0'`, `schema = pgaudix`, `relocatable = false`, `superuser = true`

### Step 2: C trigger function
**File**: `src/pgaudix.c`

- `PG_MODULE_MAGIC`, `_PG_init()` with GUC `pgaudix.log_query` (bool, default off)
- `pgaudix_trigger()`: AFTER ROW trigger function
  - Receives audit table FQN as `tgargs[0]`
  - Determines operation from trigger event macros
  - Iterates `TupleDesc` for non-dropped columns
  - Uses `SPI_getbinval()` to get typed Datum values
  - Builds parameterized INSERT via `StringInfo` + `SPI_execute_with_args()`
  - For UPDATE: executes two INSERTs (one `U-` with OLD, one `U+` with NEW)
  - Plan caching with `SPI_prepare`/`SPI_keepplan` keyed by table OID

### Step 3: SQL install script — schema and config tables
**File**: `pgaudix--0.1.0.sql`

```sql
CREATE SCHEMA pgaudix;

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
    table_id    int REFERENCES pgaudix.monitored_tables(id) ON DELETE CASCADE,
    attnum      smallint NOT NULL,
    attname     name NOT NULL,
    atttype     text NOT NULL,
    PRIMARY KEY (table_id, attnum)
);
```

C function declaration:
```sql
CREATE FUNCTION pgaudix_trigger() RETURNS trigger
    AS '$libdir/pgaudix' LANGUAGE c;
```

### Step 4: SQL install script — `pgaudix.enable(regclass)`

PL/pgSQL function that:
1. Resolves schema/table from `regclass`
2. Checks not already monitored
3. Queries `pg_attribute` for source columns
4. Builds `CREATE TABLE <schema>.<table>_audit (...)` with audit metadata cols + mirrored cols (same names/types as source)
5. Creates index on `audit_timestamp`
6. Creates AFTER INSERT OR UPDATE OR DELETE trigger calling `pgaudix_trigger('<audit_fqn>')`
7. Inserts into `monitored_tables` and populates `column_snapshots`

### Step 5: SQL install script — DDL event trigger

PL/pgSQL event trigger function `pgaudix.ddl_sync_trigger()`:
1. Fires on `ddl_command_end` for `ALTER TABLE`
2. Uses `pg_event_trigger_ddl_commands()` to identify altered table
3. Checks if table is in `monitored_tables`
4. Compares current `pg_attribute` against `column_snapshots` by `attnum`:
   - New attnum → `ALTER TABLE audit ADD COLUMN`
   - attnum now dropped → `ALTER TABLE audit DROP COLUMN`
   - Same attnum, different name → `RENAME COLUMN`
   - Same attnum, different type → `ALTER COLUMN TYPE`
5. Updates `column_snapshots` after sync

### Step 6: SQL install script — `pgaudix.disable(regclass, drop_data bool DEFAULT false)`

1. Drops the DML trigger from source table
2. If `drop_data = true`, drops the audit table
3. Removes from `monitored_tables` (cascade deletes snapshots)

### Step 7: SQL install script — `pgaudix.status()`

Returns `SETOF pgaudix.monitored_tables` showing all monitored tables.

### Step 8: Regression tests
**Files**: `test/sql/pgaudix_test.sql`, `test/expected/pgaudix_test.out`

Test cases:
- `CREATE EXTENSION pgaudix`
- Enable auditing on a test table
- INSERT/UPDATE/DELETE and verify audit rows (especially 2 rows for UPDATE)
- ALTER TABLE: add column, drop column, rename column, change type → verify audit table synced
- Disable auditing
- Edge cases: table with no columns besides PK, column name that starts with `audit_`

## Key Design Details

- **Column name collisions**: Source columns keep their original names in audit table. Metadata columns all have `audit_` prefix. No collision possible unless source has columns starting with `audit_` — document this.
- **TRUNCATE**: Not audited (trigger doesn't fire). Documented limitation.
- **Plan caching**: C trigger caches SPI plans per table OID for performance. Plans auto-invalidate when audit table schema changes.
- **Security**: `enable()`/`disable()` are `SECURITY DEFINER`. Extension requires superuser to install (event triggers need it).

## Verification

```bash
# 1. Build and start
docker compose up --build -d

# 2. Connect and test
docker compose exec pgaudix psql -U postgres -d pgaudix_dev -c "CREATE EXTENSION pgaudix;"

# 3. Manual test: create table, enable audit, DML, check audit
docker compose exec pgaudix psql -U postgres -d pgaudix_dev

# 4. ALTER TABLE, verify audit table synced

# 5. Run regression tests
docker compose exec pgaudix bash -c "cd /pgaudix && make USE_PGXS=1 installcheck"
```
