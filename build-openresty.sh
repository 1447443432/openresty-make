#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${BASE_DIR}"
ARCH="${1:-amd64}"
VERSION_ARG="${2:-}"
OUTPUT_DIR="${OUTPUT_DIR:-${BASE_DIR}/output}"
SOURCE_DIR="${SOURCE_DIR:-${BASE_DIR}/sources}"
CONTAINER_OUTPUT_DIR="${CONTAINER_OUTPUT_DIR:-/output}"
DOCKER_NO_CACHE="${DOCKER_NO_CACHE:-true}"
START_TIME="$(date +%s)"
# shellcheck disable=SC1091
source config/build.conf
if [ -t 1 ] && [ -z "${GITHUB_ACTIONS:-}" ]; then INTERACTIVE=true; else INTERACTIVE=false; fi
case "${ARCH}" in
    amd64) DEFAULT_BUILDER_IMAGE="${BUILDER_IMAGE_AMD64}" ;;
    arm64) DEFAULT_BUILDER_IMAGE="${BUILDER_IMAGE_ARM64}" ;;
    *) echo "[ERROR] unsupported arch: ${ARCH}"; exit 1 ;;
esac
BUILDER_IMAGE="${BUILDER_IMAGE:-${DEFAULT_BUILDER_IMAGE}}"
OPENRESTY_VERSION="$(scripts/resolve-version.sh "${VERSION_ARG}")"
eval "$(scripts/resolve-deps.sh)"
ENABLE_UPSTREAM_CHECK="${ENABLE_UPSTREAM_CHECK:-true}"
ENABLE_SUBSTITUTIONS_FILTER="${ENABLE_SUBSTITUTIONS_FILTER:-true}"
UPSTREAM_CHECK_REF="${UPSTREAM_CHECK_REF:-87bfa66ddf16c17053ba7bbae72400c9939ecf6d}"
UPSTREAM_CHECK_PATCH="${UPSTREAM_CHECK_PATCH:-auto}"
SUB_FILTER_VERSION="${SUB_FILTER_VERSION:-0.6.4}"
OPENRESTY_PATCH_REF="${OPENRESTY_PATCH_REF:-master}"
IMAGE_NAME="openresty-builder:${OPENRESTY_VERSION}-${ARCH}"
DOCKER_LOG="${OUTPUT_DIR}/docker-build-${ARCH}.log"
validate_bool()
{
    case "$2" in true|false) ;; *) echo "[ERROR] $1 must be true or false: $2"; exit 1 ;; esac
}
validate_bool ENABLE_UPSTREAM_CHECK "${ENABLE_UPSTREAM_CHECK}"
validate_bool ENABLE_SUBSTITUTIONS_FILTER "${ENABLE_SUBSTITUTIONS_FILTER}"
mkdir -p "${OUTPUT_DIR}" "${SOURCE_DIR}"
download_file()
{
    local url="$1" file="$2" tmp
    if [ -s "${file}" ]; then
        echo "[OK] use cached source: $(basename "${file}")"
        return
    fi
    echo "[INFO] download: ${url}"
    tmp="${file}.tmp"
    rm -f "${tmp}"
    curl --fail --location --retry 5 --retry-delay 3 --connect-timeout 20 --max-time 1200 --output "${tmp}" "${url}"
    test -s "${tmp}"
    case "${file}" in
        *.tar.gz) tar tzf "${tmp}" >/dev/null ;;
    esac
    mv "${tmp}" "${file}"
}
prepare_sources()
{
    download_file "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz" "${SOURCE_DIR}/openresty-${OPENRESTY_VERSION}.tar.gz"
    download_file "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" "${SOURCE_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
    download_file "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" "${SOURCE_DIR}/pcre2-${PCRE2_VERSION}.tar.gz"
    download_file "https://raw.githubusercontent.com/openresty/openresty/${OPENRESTY_PATCH_REF}/patches/openssl-${OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch" "${SOURCE_DIR}/openssl-${OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch"
    if [ "${ENABLE_SUBSTITUTIONS_FILTER}" = "true" ]; then
        download_file "https://codeload.github.com/yaoweibin/ngx_http_substitutions_filter_module/tar.gz/refs/tags/v${SUB_FILTER_VERSION}" "${SOURCE_DIR}/ngx_http_substitutions_filter_module-${SUB_FILTER_VERSION}.tar.gz"
    fi
    if [ "${ENABLE_UPSTREAM_CHECK}" = "true" ]; then
        download_file "https://codeload.github.com/yaoweibin/nginx_upstream_check_module/tar.gz/${UPSTREAM_CHECK_REF}" "${SOURCE_DIR}/nginx_upstream_check_module-${UPSTREAM_CHECK_REF}.tar.gz"
    fi
}
print_header()
{
    cat <<INFO
========================================
OpenResty build start
arch=${ARCH}
openresty=${OPENRESTY_VERSION}
openssl=${OPENSSL_VERSION}
openssl_patch=${OPENSSL_PATCH_VERSION}
pcre2=${PCRE2_VERSION}
substitutions_filter=${ENABLE_SUBSTITUTIONS_FILTER}
upstream_check=${ENABLE_UPSTREAM_CHECK}
builder=${BUILDER_IMAGE}
output=${OUTPUT_DIR}
========================================
INFO
}
show_progress()
{
    local pid="$1" name="$2"
    if [ "${INTERACTIVE}" = "true" ]; then
        while kill -0 "${pid}" 2>/dev/null; do printf '\r[INFO] %s running...' "${name}"; sleep 1; done
        echo
    else
        echo "[INFO] ${name} running..."
        while kill -0 "${pid}" 2>/dev/null; do sleep 30; done
    fi
}
run_long_stage()
{
    local name="$1"; shift
    "$@" & local pid=$!
    show_progress "${pid}" "${name}"
    if wait "${pid}"; then echo "[OK] ${name}"; else
        echo "[ERROR] ${name}"
        [ -f "${DOCKER_LOG}" ] && tail -160 "${DOCKER_LOG}" || true
        exit 1
    fi
}
docker_build()
{
    local args=(docker build --platform "linux/${ARCH}" --build-arg "BUILDER_IMAGE=${BUILDER_IMAGE}" -t "${IMAGE_NAME}")
    if [ "${DOCKER_NO_CACHE}" = "true" ]; then args+=(--no-cache); fi
    args+=(.)
    "${args[@]}" >"${DOCKER_LOG}" 2>&1
}
docker_check()
{
    docker run --rm --platform "linux/${ARCH}" --entrypoint /bin/bash --user 0:0 "${IMAGE_NAME}" -c 'id; uname -m; ldd --version | head -1; for c in gcc make perl patch tar sha256sum; do command -v "$c" >/dev/null || { echo "missing command: $c"; exit 1; }; done'
}
docker_run()
{
    rm -f "${OUTPUT_DIR}"/openresty-"${OPENRESTY_VERSION}"-*-"${ARCH}".tar.gz*
    docker run --rm --platform "linux/${ARCH}" --user 0:0 \
        -e "OUTPUT_DIR=${CONTAINER_OUTPUT_DIR}" \
        -e "OPENRESTY_VERSION=${OPENRESTY_VERSION}" \
        -e "OPENSSL_VERSION=${OPENSSL_VERSION}" \
        -e "OPENSSL_PATCH_VERSION=${OPENSSL_PATCH_VERSION}" \
        -e "PCRE2_VERSION=${PCRE2_VERSION}" \
        -e "PCRE2_SHA256=${PCRE2_SHA256}" \
        -e "ENABLE_SUBSTITUTIONS_FILTER=${ENABLE_SUBSTITUTIONS_FILTER}" \
        -e "SUB_FILTER_VERSION=${SUB_FILTER_VERSION}" \
        -e "ENABLE_UPSTREAM_CHECK=${ENABLE_UPSTREAM_CHECK}" \
        -e "UPSTREAM_CHECK_REF=${UPSTREAM_CHECK_REF}" \
        -e "UPSTREAM_CHECK_PATCH=${UPSTREAM_CHECK_PATCH}" \
        -v "${OUTPUT_DIR}:${CONTAINER_OUTPUT_DIR}" \
        "${IMAGE_NAME}"
}
check_result()
{
    local package
    package="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name "openresty-${OPENRESTY_VERSION}-*-${ARCH}.tar.gz" -print -quit)"
    ls -lh "${OUTPUT_DIR}"
    [ -n "${package}" ] || { echo "[ERROR] package not found"; exit 1; }
    echo "========================================"
    echo "BUILD SUCCESS"
    echo "package=${package}"
    echo "total=$(( $(date +%s) - START_TIME ))s"
    echo "========================================"
}
main()
{
    print_header
    prepare_sources
    run_long_stage "docker build" docker_build
    docker_check
    run_long_stage "docker run" docker_run
    check_result
}
main "$@"
