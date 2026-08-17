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

case "${ARCH}" in
    amd64)
        DEFAULT_BUILDER_IMAGE="${BUILDER_IMAGE_AMD64}"
        EXPECTED_ARCH="x86_64"
        ;;
    arm64)
        DEFAULT_BUILDER_IMAGE="${BUILDER_IMAGE_ARM64}"
        EXPECTED_ARCH="aarch64"
        ;;
    *)
        echo "[ERROR] unsupported arch: ${ARCH}" >&2
        exit 1
        ;;
esac

# BUILDER_IMAGE 环境变量优先于架构默认 Builder。
BUILDER_IMAGE="${BUILDER_IMAGE:-${DEFAULT_BUILDER_IMAGE}}"

if [ -t 1 ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

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
DOCKER_RUN_LOG="${OUTPUT_DIR}/docker-run-${ARCH}.log"

validate_bool()
{
    local name="$1"
    local value="$2"

    case "${value}" in
        true|false)
            ;;
        *)
            echo "[ERROR] ${name} must be true or false: ${value}" >&2
            exit 1
            ;;
    esac
}

validate_bool ENABLE_UPSTREAM_CHECK "${ENABLE_UPSTREAM_CHECK}"
validate_bool ENABLE_SUBSTITUTIONS_FILTER "${ENABLE_SUBSTITUTIONS_FILTER}"

mkdir -p "${OUTPUT_DIR}" "${SOURCE_DIR}"

download_file()
{
    local url="$1"
    local file="$2"
    local tmp

    if [ -s "${file}" ]; then
        echo "[OK] use cached source: $(basename "${file}")"
        return 0
    fi

    echo "[INFO] download: ${url}"

    tmp="${file}.tmp"

    rm -f "${tmp}"

    curl \
        --fail \
        --location \
        --retry 5 \
        --retry-delay 3 \
        --connect-timeout 20 \
        --max-time 1200 \
        --output "${tmp}" \
        "${url}"

    if [ ! -s "${tmp}" ]; then
        echo "[ERROR] downloaded file is empty: ${url}" >&2
        rm -f "${tmp}"
        return 1
    fi

    case "${file}" in
        *.tar.gz)
            if ! tar tzf "${tmp}" >/dev/null 2>&1; then
                echo "[ERROR] invalid tar.gz file: ${url}" >&2
                rm -f "${tmp}"
                return 1
            fi
            ;;
    esac

    mv "${tmp}" "${file}"

    echo "[OK] downloaded: $(basename "${file}")"
}

prepare_sources()
{
    download_file \
        "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz" \
        "${SOURCE_DIR}/openresty-${OPENRESTY_VERSION}.tar.gz"

    download_file \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        "${SOURCE_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"

    download_file \
        "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" \
        "${SOURCE_DIR}/pcre2-${PCRE2_VERSION}.tar.gz"

    download_file \
        "https://raw.githubusercontent.com/openresty/openresty/${OPENRESTY_PATCH_REF}/patches/openssl-${OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch" \
        "${SOURCE_DIR}/openssl-${OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch"

    if [ "${ENABLE_SUBSTITUTIONS_FILTER}" = "true" ]; then
        download_file \
            "https://codeload.github.com/yaoweibin/ngx_http_substitutions_filter_module/tar.gz/refs/tags/v${SUB_FILTER_VERSION}" \
            "${SOURCE_DIR}/ngx_http_substitutions_filter_module-${SUB_FILTER_VERSION}.tar.gz"
    fi

    if [ "${ENABLE_UPSTREAM_CHECK}" = "true" ]; then
        download_file \
            "https://codeload.github.com/yaoweibin/nginx_upstream_check_module/tar.gz/${UPSTREAM_CHECK_REF}" \
            "${SOURCE_DIR}/nginx_upstream_check_module-${UPSTREAM_CHECK_REF}.tar.gz"
    fi
}

print_header()
{
    cat <<INFO
========================================
OpenResty build start
arch=${ARCH}
expected_arch=${EXPECTED_ARCH}
openresty=${OPENRESTY_VERSION}
openssl=${OPENSSL_VERSION}
openssl_patch=${OPENSSL_PATCH_VERSION}
pcre2=${PCRE2_VERSION}
substitutions_filter=${ENABLE_SUBSTITUTIONS_FILTER}
upstream_check=${ENABLE_UPSTREAM_CHECK}
upstream_check_ref=${UPSTREAM_CHECK_REF}
upstream_check_patch=${UPSTREAM_CHECK_PATCH}
builder=${BUILDER_IMAGE}
output=${OUTPUT_DIR}
docker_no_cache=${DOCKER_NO_CACHE}
========================================
INFO
}

format_duration()
{
    local total_seconds="$1"
    local hours
    local minutes
    local seconds

    hours=$(( total_seconds / 3600 ))
    minutes=$(( total_seconds % 3600 / 60 ))
    seconds=$(( total_seconds % 60 ))

    if [ "${hours}" -gt 0 ]; then
        printf '%02d:%02d:%02d' \
            "${hours}" \
            "${minutes}" \
            "${seconds}"
    else
        printf '%02d:%02d' \
            "${minutes}" \
            "${seconds}"
    fi
}

show_progress()
{
    local pid="$1"
    local name="$2"
    local start_time="$3"
    local elapsed

    if [ "${INTERACTIVE}" = "true" ]; then
        while kill -0 "${pid}" 2>/dev/null; do
            elapsed=$(( $(date +%s) - start_time ))

            printf '\r[INFO] %s running... elapsed=%s' \
                "${name}" \
                "$(format_duration "${elapsed}")"

            sleep 1
        done

        echo
    else
        echo "[INFO] ${name} running..."

        while kill -0 "${pid}" 2>/dev/null; do
            sleep 30

            if kill -0 "${pid}" 2>/dev/null; then
                elapsed=$(( $(date +%s) - start_time ))

                echo "[INFO] ${name} is still running... elapsed=$(format_duration "${elapsed}")"
            fi
        done
    fi
}

run_long_stage()
{
    local name="$1"
    local pid
    local start_time
    local elapsed
    local status

    shift

    start_time="$(date +%s)"

    "$@" &
    pid=$!

    show_progress \
        "${pid}" \
        "${name}" \
        "${start_time}"

    set +e
    wait "${pid}"
    status=$?
    set -e

    elapsed=$(( $(date +%s) - start_time ))

    if [ "${status}" -eq 0 ]; then
        echo "[OK] ${name} ($(format_duration "${elapsed}"))"
    else
        echo "[ERROR] ${name} ($(format_duration "${elapsed}"))" >&2

        if [ -f "${DOCKER_LOG}" ]; then
            echo "========== last Docker build log =========="
            tail -160 "${DOCKER_LOG}" || true
            echo "==========================================="
        fi

        if [ -f "${DOCKER_RUN_LOG}" ]; then
            echo "========== last Docker run log =========="
            tail -160 "${DOCKER_RUN_LOG}" || true
            echo "=========================================="
        fi

        exit "${status}"
    fi
}

docker_build()
{
    local args=(
        docker
        build
        --pull
        --platform
        "linux/${ARCH}"
        --build-arg
        "BUILDER_IMAGE=${BUILDER_IMAGE}"
        -t
        "${IMAGE_NAME}"
    )

    if [ "${DOCKER_NO_CACHE}" = "true" ]; then
        args+=(--no-cache)
    fi

    args+=(.)

    "${args[@]}" >"${DOCKER_LOG}" 2>&1
}

docker_check()
{
    local check_script

    check_script="$(cat <<'CHECK_EOF'
set -euo pipefail

ACTUAL_ARCH="$(uname -m)"

echo "expected_arch=${EXPECTED_ARCH}"
echo "actual_arch=${ACTUAL_ARCH}"

if [ "${ACTUAL_ARCH}" != "${EXPECTED_ARCH}" ]; then
    echo "[ERROR] architecture mismatch" >&2
    exit 1
fi

echo "========== versions =========="

ldd --version 2>&1 | sed -n '1p'
gcc --version 2>&1 | sed -n '1p'
g++ --version 2>&1 | sed -n '1p'
make --version 2>&1 | sed -n '1p'
perl -v 2>&1 | sed -n '1,2p'
autoconf --version 2>&1 | sed -n '1p'
automake --version 2>&1 | sed -n '1p'
libtool --version 2>&1 | sed -n '1p'
pkg-config --version

echo "========== required commands =========="

for command_name in \
    gcc \
    g++ \
    make \
    wget \
    curl \
    patch \
    diff \
    tar \
    gzip \
    bzip2 \
    xz \
    perl \
    file \
    git \
    unzip \
    which \
    find \
    sha256sum \
    autoconf \
    automake \
    autoreconf \
    libtool \
    pkg-config
do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "[ERROR] missing command: ${command_name}" >&2
        exit 1
    fi

    echo "[OK] ${command_name}"
done

echo "========== Perl modules =========="

perl -MIPC::Cmd \
    -e 'print "IPC::Cmd=$IPC::Cmd::VERSION\n"'

perl -MData::Dumper \
    -e 'print "Data::Dumper=$Data::Dumper::VERSION\n"'

perl -MExtUtils::MakeMaker \
    -e 'print "ExtUtils::MakeMaker=$ExtUtils::MakeMaker::VERSION\n"'

perl -MTime::Piece \
    -e 'print "Time::Piece=$Time::Piece::VERSION\n"'

perl -MDigest::SHA \
    -e 'print "Digest::SHA=$Digest::SHA::VERSION\n"'

echo "========== required RPM packages =========="

rpm -q \
    openssl-devel \
    zlib-devel \
    pcre-devel \
    perl-IPC-Cmd \
    perl-Data-Dumper \
    perl-ExtUtils-MakeMaker \
    perl-Time-Piece \
    perl-Digest-SHA \
    autoconf \
    automake \
    libtool \
    pkgconfig \
    readline-devel \
    ncurses-devel

echo "[OK] Builder verification passed"
CHECK_EOF
)"

    docker run \
        --rm \
        --platform "linux/${ARCH}" \
        --entrypoint /bin/bash \
        --user 0:0 \
        -e "EXPECTED_ARCH=${EXPECTED_ARCH}" \
        "${IMAGE_NAME}" \
        -c "${check_script}"
}

docker_run()
{
    rm -f \
        "${OUTPUT_DIR}"/openresty-"${OPENRESTY_VERSION}"-*-"${ARCH}".tar.gz \
        "${OUTPUT_DIR}"/openresty-"${OPENRESTY_VERSION}"-*-"${ARCH}".tar.gz.sha256

    docker run \
        --rm \
        --platform "linux/${ARCH}" \
        --user 0:0 \
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
        "${IMAGE_NAME}" \
        >"${DOCKER_RUN_LOG}" 2>&1
}

check_result()
{
    local package
    local sha_file

    package="$(
        find "${OUTPUT_DIR}" \
            -maxdepth 1 \
            -type f \
            -name "openresty-${OPENRESTY_VERSION}-*-${ARCH}.tar.gz" \
            -print \
            -quit
    )"

    if [ -z "${package}" ]; then
        echo "[ERROR] package not found" >&2
        ls -lh "${OUTPUT_DIR}" || true
        exit 1
    fi

    sha_file="${package}.sha256"

    if [ ! -s "${sha_file}" ]; then
        echo "[ERROR] SHA256 file not found: ${sha_file}" >&2
        exit 1
    fi

    (
        cd "${OUTPUT_DIR}"
        sha256sum -c "$(basename "${sha_file}")"
    )

    ls -lh "${OUTPUT_DIR}"

    echo "========================================"
    echo "BUILD SUCCESS"
    echo "package=${package}"
    echo "sha256=${sha_file}"
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
