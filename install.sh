#!/bin/bash
set -euo pipefail

PG_CONFIG="${PG_CONFIG:-pg_config}"
LIBDIR=$("$PG_CONFIG" --pkglibdir)
SHAREDIR=$("$PG_CONFIG" --sharedir)

install -m 755 pgaudix.so "$LIBDIR/pgaudix.so"
install -m 644 pgaudix.control "$SHAREDIR/extension/"
install -m 644 pgaudix--*.sql "$SHAREDIR/extension/"

echo "pgaudix installed successfully."
echo "Connect to your database and run: CREATE EXTENSION pgaudix;"
