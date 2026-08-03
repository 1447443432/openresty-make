#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${BASE_DIR}"
for file in build-openresty.sh build.sh scripts/resolve-version.sh scripts/resolve-deps.sh scripts/self-check.sh; do
    bash -n "${file}"
done
if grep -RInE 'actions/checkout@v4|actions/upload-artifact@v4|actions/download-artifact@v4|softprops/action-gh-release@v2' .github/workflows; then
    echo '[ERROR] found Node.js 20 based action version'
    exit 1
fi
source config/openresty-version.conf
source config/build.conf
printf '%s' "${OPENRESTY_FALLBACK_VERSION}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
printf '%s' "${PCRE2_FALLBACK_SHA256}" | grep -qE '^[0-9a-fA-F]{64}$'
case "${ENABLE_UPSTREAM_CHECK}" in true|false) ;; *) exit 1 ;; esac
case "${ENABLE_SUBSTITUTIONS_FILTER}" in true|false) ;; *) exit 1 ;; esac
echo '[OK] project self-check passed'
