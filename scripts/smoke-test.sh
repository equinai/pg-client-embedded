#!/usr/bin/env bash
# Prove the built pg_dump / pg_restore work against the SERVER they ship beside:
# the @embedded-postgres package Singularity runs. A scratch cluster gets a
# database with data (a non-ASCII row, a sequence, a foreign key, an index); it
# is dumped with -Fc, restored into a second database, and both are dumped to
# plain SQL, which must be identical.
#
# Usage: scripts/smoke-test.sh <embedded-postgres package root>
#   (the dir holding native/bin/postgres; fetched by the workflow with npm)
set -euo pipefail

SERVER_PKG="$(cd "$1" && pwd)"
SERVER_BIN="${SERVER_PKG}/native/bin"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64)        ARCH="x64"   ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_BIN="$(dirname "$SCRIPT_DIR")/packages/${OS}-${ARCH}/native/bin"

WORK="$(mktemp -d)"
DATA="${WORK}/data"
SOCK="${WORK}/sock"
PORT=54329
mkdir -p "${SOCK}"
stop() { "${SERVER_BIN}/pg_ctl" -D "${DATA}" -m immediate stop >/dev/null 2>&1 || true; rm -rf "${WORK}"; }
trap stop EXIT

"${SERVER_BIN}/postgres" --version
"${CLIENT_BIN}/pg_dump" --version
"${CLIENT_BIN}/pg_restore" --version
# The point of shipping these: client and server from ONE Postgres release.
SERVER_V="$("${SERVER_BIN}/postgres" --version | awk '{print $NF}')"
for tool in pg_dump pg_restore; do
  CLIENT_V="$("${CLIENT_BIN}/${tool}" --version | awk '{print $NF}')"
  [ "${CLIENT_V}" = "${SERVER_V}" ] \
    || { echo "ERROR: ${tool} ${CLIENT_V} != server ${SERVER_V}"; exit 1; }
done

"${SERVER_BIN}/initdb" -D "${DATA}" -U smoke --auth=trust -E UTF8 --locale=C >/dev/null

# Seed through single-user mode: no psql needed, and none is shipped.
single() { "${SERVER_BIN}/postgres" --single -D "${DATA}" "$1" >/dev/null; }
printf 'CREATE DATABASE src;\nCREATE DATABASE dst;\n' | single postgres
single src <<'SQL'
CREATE TABLE parent (id bigserial PRIMARY KEY, name text NOT NULL);
CREATE TABLE child (id bigserial PRIMARY KEY, parent_id bigint REFERENCES parent(id), note text);
CREATE INDEX child_parent_idx ON child (parent_id);
INSERT INTO parent (name) SELECT 'p' || g FROM generate_series(1, 5000) g;
INSERT INTO parent (name) VALUES ('héllo wörld ✓');
INSERT INTO child (parent_id, note) SELECT (g % 5000) + 1, repeat('x', g % 50) FROM generate_series(1, 20000) g;
SQL

"${SERVER_BIN}/pg_ctl" -D "${DATA}" -w -l "${WORK}/server.log" \
  -o "-k ${SOCK} -p ${PORT} -c listen_addresses=''" start >/dev/null

export PGHOST="${SOCK}" PGPORT="${PORT}" PGUSER=smoke
"${CLIENT_BIN}/pg_dump" -Fc -f "${WORK}/src.dump" src
"${CLIENT_BIN}/pg_restore" -d dst "${WORK}/src.dump"

# PG 18 plain dumps carry a random \restrict key per run — drop those lines.
plain() { "${CLIENT_BIN}/pg_dump" "$1" | grep -Ev '^\\(un)?restrict '; }
plain src > "${WORK}/src.sql"
plain dst > "${WORK}/dst.sql"
diff -u "${WORK}/src.sql" "${WORK}/dst.sql"
grep -q 'héllo wörld ✓' "${WORK}/dst.sql"
grep -q 'child_parent_idx' "${WORK}/dst.sql"

echo "==> smoke test OK: dump → restore round-trips ($(wc -l < "${WORK}/dst.sql") lines)"
