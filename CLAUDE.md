# pgaudix — PostgreSQL Native Audit Extension

## Project Overview

Native C PostgreSQL extension for automatic table auditing using PGXS build system.

## Architecture

- **Hybrid C + PL/pgSQL**: C for DML trigger (performance), PL/pgSQL for API and DDL event trigger (maintainability)
- **Storage model**: Single copy of mirrored columns. One row per operation with current values. Operations: `I` (insert), `U` (update, new values), `D` (delete, old values), `T` (truncate, NULL data).
- **DDL sync**: Event trigger on `ddl_command_end` (tags `ALTER TABLE`, `ALTER SCHEMA`, `CREATE TABLE`) compares source `pg_attribute` against audit `pg_attribute` using attnum offset to detect DROP/ADD/RENAME/TYPE CHANGE (in that order, by attnum). Altered tables are expanded to their inheritance children and partitions. Audit table attnums are aligned with source via gap fillers in `enable()`. Virtual generated columns (PG18+) are mirrored as live, always-NULL columns so the alignment survives pg_dump/restore (dropped slots are not dumped). Uses OID-based lookup for RENAME TABLE support; `heal_registry()` re-resolves OIDs by name after pg_dump/restore, treating an OID whose current name differs from the registered one as stale (OID reuse). `ddl_sync()`, the pre-pass and `disable()` never act on a registered OID whose relation does not carry `pgaudix_audit_trigger`. Type changes use an explicit cast and fall back to `text`; domains, and arrays of domains, are mirrored with their base type (`audit_type()`). Per-partition TRUNCATE triggers are reconciled by `sync_partition_triggers()`, only when the command touched a monitored partition tree.
- **TRUNCATE**: every member of a monitored partition tree carries `pgaudix_truncate_trigger`: BEFORE on partitioned relations (root and intermediate), AFTER on leaves and plain tables. PostgreSQL fires all BEFORE statement triggers of a TRUNCATE before any AFTER one, so the topmost truncated relation runs first: it writes one `T` row and records in `pgaudix.truncate_pending` (pid, audit table, txid, count) how many triggers of the same statement follow; those consume the count instead of writing. A direct TRUNCATE of a leaf, or a second TRUNCATE in the same transaction, finds no pending count and is recorded.
- **status()** is a read-only SQL function (resolves stale OIDs by name without writing) so it works on a hot standby.
- **Recursion guard**: `pgaudix.ddl_guard` table (one row per backend pid while `ddl_sync()`/`enable()` run their own DDL). Not a GUC, so it cannot be set by users. `drop_cleanup()` also returns early while the guard is held (the DROP TRIGGER / DROP COLUMN issued by our own DDL).
- **C plan cache**: one saved SPI plan per source relation, invalidated by a relcache callback; stale entries (including dropped partitions) are freed on the next trigger call unless the plan is executing (`in_use`).
- **Security**: All functions are SECURITY DEFINER with `SET search_path = pgaudix, pg_catalog, pg_temp` and `REVOKE EXECUTE FROM PUBLIC`; `enable()`/`disable()` check table ownership via `pgaudix.invoker()` (the `role` GUC, else `session_user`). C trigger validates tgargs format. Audit tables are write-protected (REVOKE from PUBLIC). Concurrent enable() calls are serialized. Event and DML triggers are ENABLE ALWAYS.

## Key Files

- `src/pgaudix.c` — C DML trigger function using SPI
- `pgaudix--0.3.0.sql` — full SQL install script for fresh installs (current version)
- Future versions: ship a full `pgaudix--X.Y.Z.sql` plus a `pgaudix--0.3.0--X.Y.Z.sql` delta; never rewrite a released script in place
- `Makefile` — PGXS build (`make USE_PGXS=1`)
- `pgaudix.control` — Extension metadata

## API

- `pgaudix.enable(target_table regclass)` — Start auditing a table (creates `_audit` table + trigger)
- `pgaudix.disable(target_table regclass, drop_data bool DEFAULT false)` — Stop auditing
- `pgaudix.status()` — List all monitored tables with integrity flags
- Internal helpers (not for users): `heal_registry()`, `sync_partition_triggers()`, `audit_type()`, `check_table_owner()`, `invoker()`, `reserved_columns()` (single list of the metadata column names used by `enable()` and `ddl_sync()`)

## Conventions

- All code, comments, function names, and error messages in **English**
- Audit metadata columns prefixed with `audit_` (audit_id, audit_operation, audit_timestamp, audit_txid, audit_user, audit_client_addr, audit_app_name, audit_app_user); `audit_app_user` is the last one and defines the attnum offset used by DDL sync
- `audit_app_user` comes from the `pgaudix.app_user` GUC that the application sets per transaction (`SET LOCAL`)
- Mirrored columns keep their original names
- Extension schema: `pgaudix`
- Version: 0.3.0

## Development Environment

Docker-based (Windows host). PostgreSQL 17 runs inside a container with build tools.

- **Port**: 5433 (mapped from container's 5432)
- **Database**: `pgaudix_dev`
- **User**: `postgres`

## Build & Test

```bash
# Start everything (builds extension + starts PostgreSQL)
docker compose up --build -d

# Connect to database
docker compose exec pgaudix psql -U postgres -d pgaudix_dev

# Rebuild after code changes
docker compose exec pgaudix bash -c "cd /pgaudix && make USE_PGXS=1 install"

# Run regression tests
docker compose exec pgaudix bash -c "cd /pgaudix && make USE_PGXS=1 installcheck"
```

## Testing conventions

- Bug fixes are done TDD-style: add a numbered block to `test/sql/pgaudix_test.sql`, run `installcheck` to see it fail, fix, review `regression.diffs`, then promote `results/pgaudix_test.out` to `test/expected/`.
- Scenarios pg_regress cannot drive (real pg_dump/restore, other login roles) are verified ad hoc in the container and described in the test comments.
