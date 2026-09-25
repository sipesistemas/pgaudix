#!/bin/bash
set -euo pipefail

PG_CONFIG="${PG_CONFIG:-pg_config}"
LIBDIR=$("$PG_CONFIG" --pkglibdir)
SHAREDIR=$("$PG_CONFIG" --sharedir)

# The loadable-module suffix is platform-dependent: .so on Linux,
# .dylib on macOS. Install whichever shared library was shipped under
# its own name so PostgreSQL finds it as $libdir/pgaudix<DLSUFFIX>.
if [ -f pgaudix.dylib ]; then
    SHLIB=pgaudix.dylib
elif [ -f pgaudix.so ]; then
    SHLIB=pgaudix.so
else
    echo "ERROR: no pgaudix shared library (pgaudix.so / pgaudix.dylib) found next to install.sh" >&2
    exit 1
fi

install -m 755 "$SHLIB" "$LIBDIR/$SHLIB"
install -m 644 pgaudix.control "$SHAREDIR/extension/"
install -m 644 pgaudix--*.sql "$SHAREDIR/extension/"

echo "pgaudix installed successfully ($SHLIB -> $LIBDIR)."
echo "Connect to your database and run: CREATE EXTENSION pgaudix;"
