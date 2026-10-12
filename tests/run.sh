#!/bin/sh
# Run the KindleTodo test suite with a KOReader build's LuaJIT.
#   KOREADER_DIR=/path/to/koreader tests/run.sh
# (For a Linux x86_64 KOReader tarball this is <extract>/lib/koreader.)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KOREADER_DIR:?set KOREADER_DIR to a KOReader install (the dir containing luajit)}"
OUT="${KINDLETODO_TEST_OUT:-${HERE}/out}"
rm -rf "${OUT}" && mkdir -p "${OUT}"
cd "${KOREADER_DIR}"
KINDLETODO_PLUGIN="${HERE}/../src/koreader/plugins/kindletodo.koplugin" \
KINDLETODO_TEST_OUT="${OUT}" KOREADER_DIR="${KOREADER_DIR}" \
    ./luajit "${HERE}/test_kindletodo.lua"
