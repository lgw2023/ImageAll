#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/Vendor/LibRaw"
DIST="${ROOT}/Vendor/LibRawDist"
VERSION="0.21.2"
TARBALL_URL="https://github.com/LibRaw/LibRaw/archive/refs/tags/${VERSION}.tar.gz"

if [[ ! -f "${SRC}/Makefile.dist" ]]; then
  mkdir -p "${ROOT}/Vendor"
  TMP="$(mktemp -d)"
  curl -L --fail -o "${TMP}/libraw.tgz" "${TARBALL_URL}"
  tar -xzf "${TMP}/libraw.tgz" -C "${TMP}"
  rm -rf "${SRC}"
  mv "${TMP}/LibRaw-${VERSION}" "${SRC}"
  rm -rf "${TMP}"
fi

make -C "${SRC}" -f Makefile.dist library \
  CFLAGS='-O2 -I. -w -fPIC' \
  CXXFLAGS='-O2 -I. -w -fPIC -std=c++14'

mkdir -p "${DIST}/include/libraw" "${DIST}/lib"
cp -f "${SRC}/lib/libraw_r.a" "${DIST}/lib/"
cp -f "${SRC}/libraw/"*.h "${DIST}/include/libraw/"
cp -f "${SRC}/LICENSE.LGPL" "${SRC}/LICENSE.CDDL" "${SRC}/COPYRIGHT" "${DIST}/"
echo "Updated ${DIST}"
