# pgaudix — PostgreSQL Native Audit Extension

## Project Overview

Native C PostgreSQL extension for automatic table auditing using PGXS build system.

## Architecture

- **Hybrid C + PL/pgSQL**: C for DML trigger (performance), PL/pgSQL for API and DDL event trigger (maintainability)
- **Storage model**: Single copy of mirrored columns. One row per operation with current values. Operations: `I` (insert), `U` (update, new values), `D` (delete, old values).
- **DDL sync**: Event trigger on `ddl_command_end` compares `pg_attribute` against stored `column_snapshots` by `attnum` to detect ADD/DROP/RENAME/TYPE CHANGE

## Key Files

- `src/pgaudix.c` — C DML trigger function using SPI, plan caching
- `pgaudix--0.1.0.sql` — SQL install script (schema, PL/pgSQL functions, event triggers)
- `Makefile` — PGXS build (`make USE_PGXS=1`)
- `pgaudix.control` — Extension metadata
- `PLAN.md` — Detailed implementation plan

## API

- `pgaudix.enable(target_table regclass)` — Start auditing a table (creates `_audit` table + trigger)
- `pgaudix.disable(target_table regclass, drop_data bool DEFAULT false)` — Stop auditing
- `pgaudix.status()` — List all monitored tables

## Conventions

- All code, comments, function names, and error messages in **English**
- Audit metadata columns prefixed with `audit_` (audit_id, audit_operation, audit_timestamp, etc.)
- Mirrored columns keep their original names
- Extension schema: `uadix` (PostgreSQL reserves `pg_` prefix for system schemas)
- Version: 0.1.0

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
