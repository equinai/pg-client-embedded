#!/usr/bin/env bash
# Build pg_dump + pg_restore for the host platform from the official PostgreSQL
# source tarball, with libpq (and, on Linux, zlib) linked statically so the
# binaries need nothing beyond the OS C library.
#
# Output: packages/<platform>/native/bin/{pg_dump,pg_restore}
set -euo pipefail

PG_VERSION="18.3"
PG_SHA256="d95663fbbf3a80f81a9d98d895266bdcb74ba274bcc04ef6d76630a72dee016f"
PG_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64)        ARCH="x64"   ;;
  *) echo "Unsupported arch: $(uname -m)" && exit 1 ;;
esac
PLATFORM="${OS}-${ARCH}"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.logicalcpu)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${REPO_ROOT}/.build/${PLATFORM}"
OUT_DIR="${REPO_ROOT}/packages/${PLATFORM}/native/bin"
SRC="${BUILD_DIR}/src/postgresql-${PG_VERSION}"

echo "==> Building PostgreSQL ${PG_VERSION} client tools for ${PLATFORM}"
mkdir -p "${BUILD_DIR}/src" "${OUT_DIR}"

# ── 1. Source (checksum-verified) ─────────────────────────────────────────
TARBALL="${BUILD_DIR}/postgresql-${PG_VERSION}.tar.bz2"
if [ ! -f "${TARBALL}" ]; then
  curl -fsSL "${PG_URL}" -o "${TARBALL}.part"
  mv "${TARBALL}.part" "${TARBALL}"
fi
if command -v sha256sum >/dev/null; then
  echo "${PG_SHA256}  ${TARBALL}" | sha256sum -c -
else
  echo "${PG_SHA256}  ${TARBALL}" | shasum -a 256 -c -
fi
[ -d "${SRC}" ] || tar xjf "${TARBALL}" -C "${BUILD_DIR}/src"

# ── 2. Configure ──────────────────────────────────────────────────────────
# These tools only reach a local cluster (Unix socket, or localhost TCP), so no
# SSL / GSSAPI / ICU / readline. zlib stays: -Fc archives are zlib-compressed,
# and a client without it cannot restore one.
#
# Linux: zlib is linked statically by giving the linker a directory holding
# ONLY libz.a ahead of the system dirs (it takes the first dir with a match).
STATIC_LIBS="${BUILD_DIR}/static-libs"
if [ "$OS" = "linux" ]; then
  mkdir -p "${STATIC_LIBS}"
  LIBZ_A="$(gcc -print-file-name=libz.a)"
  [ -f "${LIBZ_A}" ] || { echo "libz.a not found (install zlib1g-dev)"; exit 1; }
  cp "${LIBZ_A}" "${STATIC_LIBS}/libz.a"
  export LDFLAGS="-L${STATIC_LIBS}"
fi
export CFLAGS="-O2"
# macOS: run on releases older than the build runner's.
if [ "$OS" = "darwin" ]; then export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"; fi

cd "${SRC}"
if [ ! -f config.status ]; then
  ./configure \
    --prefix="${BUILD_DIR}/prefix" \
    --without-icu \
    --without-readline \
    --without-openssl \
    --without-gssapi \
    --without-ldap \
    --without-lz4 \
    --without-zstd \
    --with-zlib
fi

# ── 3. Build only what pg_dump / pg_restore need ─────────────────────────
make -j"${JOBS}" -C src/backend generated-headers
make -j"${JOBS}" -C src/common
make -j"${JOBS}" -C src/port
make -j"${JOBS}" -C src/interfaces/libpq
make -j"${JOBS}" -C src/fe_utils

# Link libpq statically: point `$(libpq)` (what `-lpq` comes from in
# Makefile.global) at the archive itself. Deleting the shared library is not
# enough — the pg_dump makefile re-runs libpq's `all`, which rebuilds it.
# libpq.a carries no pgcommon/pgport objects: the shared libpq links the
# `_shlib` variants in and EXPORTS some of them (pg_char_to_encoding, …), which
# frontend programs expect from libpq — their own -lpgcommon renames its copies
# to *_private. So the `_shlib` archives go right after libpq.a.
LIBPQ_A="${SRC}/src/interfaces/libpq/libpq.a"
[ -f "${LIBPQ_A}" ] || { echo "libpq.a was not built"; exit 1; }
rm -f src/bin/pg_dump/pg_dump src/bin/pg_dump/pg_restore
make -j"${JOBS}" -C src/bin/pg_dump pg_dump pg_restore \
  libpq="${LIBPQ_A} -L${SRC}/src/common -L${SRC}/src/port -lpgcommon_shlib -lpgport_shlib -lpthread"

# ── 4. Copy, strip, sign ─────────────────────────────────────────────────
for tool in pg_dump pg_restore; do
  cp "src/bin/pg_dump/${tool}" "${OUT_DIR}/${tool}"
  strip "${OUT_DIR}/${tool}"
  # Stripping invalidates the linker's ad-hoc signature; arm64 macOS refuses
  # to run an unsigned binary.
  if [ "$OS" = "darwin" ]; then codesign -s - --force "${OUT_DIR}/${tool}"; fi
  chmod 755 "${OUT_DIR}/${tool}"
done

# ── 5. Prove the link: no libpq / ssl / icu / (linux) zlib dependency ────
for tool in pg_dump pg_restore; do
  BIN="${OUT_DIR}/${tool}"
  if [ "$OS" = "darwin" ]; then DEPS="$(otool -L "${BIN}")"; else DEPS="$(ldd "${BIN}" || true)"; fi
  echo "${DEPS}"
  if echo "${DEPS}" | grep -Eiq 'libpq|libssl|libcrypto|libicu'; then
    echo "ERROR: ${tool} links a library it must not"; exit 1
  fi
  if [ "$OS" = "linux" ] && echo "${DEPS}" | grep -q 'libz\.so'; then
    echo "ERROR: ${tool} links zlib dynamically"; exit 1
  fi
  "${BIN}" --version | grep -q "(PostgreSQL) ${PG_VERSION}\$" \
    || { echo "ERROR: ${tool} --version is not ${PG_VERSION}"; "${BIN}" --version; exit 1; }
done

echo "==> Done: ${OUT_DIR}"
ls -lh "${OUT_DIR}"
