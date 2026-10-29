#!/bin/bash
# Starts a container from the given image and checks that the extension
# installs and reports the version in pgaudix.control.
#   docker/smoke-test.sh <image>
set -euo pipefail

IMAGE="$1"
EXPECTED="$(sed -nE "s/^default_version = '([^']+)'$/\1/p" "$(dirname "$0")/../pgaudix.control")"
NAME="pgaudix-smoke-$$"

trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null

# The entrypoint runs a temporary server during initdb; wait for the final
# one (it listens on TCP, the temporary one only on the socket).
for _ in $(seq 1 60); do
    if docker exec "$NAME" pg_isready -h 127.0.0.1 -U postgres -q; then
        break
    fi
    sleep 1
done

docker exec "$NAME" psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -q -c 'CREATE EXTENSION pgaudix'
ACTUAL="$(docker exec "$NAME" psql -h 127.0.0.1 -U postgres -At -c "SELECT extversion FROM pg_extension WHERE extname = 'pgaudix'")"

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "ERROR: pgaudix ${ACTUAL:-<missing>} installed, expected $EXPECTED" >&2
    docker logs "$NAME" >&2
    exit 1
fi
echo "pgaudix $ACTUAL OK on $(docker exec "$NAME" postgres --version)"
