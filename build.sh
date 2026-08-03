#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${BASE_DIR}"
OPENRESTY_VERSION="${OPENRESTY_VERSION:?OPENRESTY_VERSION is required}"
OPENSSL_VERSION="${OPENSSL_VERSION:?OPENSSL_VERSION is required}"
OPENSSL_PATCH_VERSION="${OPENSSL_PATCH_VERSION:?OPENSSL_PATCH_VERSION is required}"
PCRE2_VERSION="${PCRE2_VERSION:?PCRE2_VERSION is required}"
PCRE2_SHA256="${PCRE2_SHA256:?PCRE2_SHA256 is required}"
ENABLE_SUBSTITUTIONS_FILTER="${ENABLE_SUBSTITUTIONS_FILTER:-true}"
SUB_FILTER_VERSION="${SUB_FILTER_VERSION:-0.6.4}"
ENABLE_UPSTREAM_CHECK="${ENABLE_UPSTREAM_CHECK:-true}"
UPSTREAM_CHECK_REF="${UPSTREAM_CHECK_REF:-87bfa66ddf16c17053ba7bbae72400c9939ecf6d}"
UPSTREAM_CHECK_PATCH="${UPSTREAM_CHECK_PATCH:-auto}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
WORK_DIR="${BASE_DIR}/work"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/openresty}"
OPENSSL_PREFIX="${INSTALL_PREFIX}/openssl3"
PCRE2_PREFIX="${INSTALL_PREFIX}/pcre2"
BUILD_LOG="${OUTPUT_DIR}/build.log"
STAGE_LOG="${OUTPUT_DIR}/stage-time.log"
BUILD_INFO="${OUTPUT_DIR}/build-info.txt"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
mkdir -p "${OUTPUT_DIR}"
: >"${BUILD_LOG}"
: >"${STAGE_LOG}"
case "$(uname -m)" in x86_64) BUILD_ARCH=amd64 ;; aarch64) BUILD_ARCH=arm64 ;; *) echo "unsupported architecture"; exit 1 ;; esac
stage_start_time=0
stage_start(){ stage_start_time="$(date +%s)"; }
stage_ok(){ local name="$1" cost=$(( $(date +%s)-stage_start_time )); echo "[OK] ${name} (${cost}s)"; echo "${name}=${cost}s" >>"${STAGE_LOG}"; }
stage_fail(){ echo "[ERROR] $1"; echo '========== last build log =========='; tail -160 "${BUILD_LOG}" || true; echo '===================================='; exit 1; }
run_stage(){ local name="$1"; shift; stage_start; "$@" >>"${BUILD_LOG}" 2>&1 || stage_fail "${name}"; stage_ok "${name}"; }
check_sources()
{
    local required=(
        "sources/openresty-${OPENRESTY_VERSION}.tar.gz"
        "sources/openssl-${OPENSSL_VERSION}.tar.gz"
        "sources/pcre2-${PCRE2_VERSION}.tar.gz"
        "sources/openssl-${OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch"
    )
    [ "${ENABLE_SUBSTITUTIONS_FILTER}" = "false" ] || required+=("sources/ngx_http_substitutions_filter_module-${SUB_FILTER_VERSION}.tar.gz")
    [ "${ENABLE_UPSTREAM_CHECK}" = "false" ] || required+=("sources/nginx_upstream_check_module-${UPSTREAM_CHECK_REF}.tar.gz")
    local file
    for file in "${required[@]}"; do [ -s "${file}" ] || { echo "missing source: ${file}"; return 1; }; done
    echo "${PCRE2_SHA256}  sources/pcre2-${PCRE2_VERSION}.tar.gz" | sha256sum -c -
}
extract_sources()
{
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}/deps"
    tar zxf "sources/openresty-${OPENRESTY_VERSION}.tar.gz" -C "${WORK_DIR}"
    tar zxf "sources/openssl-${OPENSSL_VERSION}.tar.gz" -C "${WORK_DIR}/deps"
    tar zxf "sources/pcre2-${PCRE2_VERSION}.tar.gz" -C "${WORK_DIR}/deps"
    if [ "${ENABLE_SUBSTITUTIONS_FILTER}" = "true" ]; then tar zxf "sources/ngx_http_substitutions_filter_module-${SUB_FILTER_VERSION}.tar.gz" -C "${WORK_DIR}/deps"; fi
    if [ "${ENABLE_UPSTREAM_CHECK}" = "true" ]; then tar zxf "sources/nginx_upstream_check_module-${UPSTREAM_CHECK_REF}.tar.gz" -C "${WORK_DIR}/deps"; fi
}
detect_paths()
{
    OPENRESTY_SRC="${WORK_DIR}/openresty-${OPENRESTY_VERSION}"
    OPENSSL_SRC="${WORK_DIR}/deps/openssl-${OPENSSL_VERSION}"
    PCRE2_SRC="${WORK_DIR}/deps/pcre2-${PCRE2_VERSION}"
    test -d "${OPENRESTY_SRC}"; test -d "${OPENSSL_SRC}"; test -d "${PCRE2_SRC}"
    if [ "${ENABLE_SUBSTITUTIONS_FILTER}" = "true" ]; then
        SUB_FILTER_SRC="$(find "${WORK_DIR}/deps" -maxdepth 1 -type d -name 'ngx_http_substitutions_filter_module-*' -print -quit)"
        test -d "${SUB_FILTER_SRC}"
    fi
    if [ "${ENABLE_UPSTREAM_CHECK}" = "true" ]; then
        UPSTREAM_CHECK_SRC="$(find "${WORK_DIR}/deps" -maxdepth 1 -type d -name 'nginx_upstream_check_module-*' -print -quit)"
        test -d "${UPSTREAM_CHECK_SRC}"
    fi
}
build_openssl()
{
    cd "${OPENSSL_SRC}"
    local patch_file="${BASE_DIR}/sources/openssl-${OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch"
    patch --dry-run --forward -p1 <"${patch_file}"
    patch --forward -p1 <"${patch_file}"
    ./config shared zlib -g \
        --prefix="${OPENSSL_PREFIX}" \
        --libdir=lib \
        -Wl,-rpath,"${OPENSSL_PREFIX}/lib" \
        enable-camellia enable-seed enable-rfc3779 enable-cms enable-weak-ssl-ciphers \
        enable-ssl3 enable-ssl3-method enable-ktls enable-fips
    make -j"${BUILD_JOBS}"
    make -j"${BUILD_JOBS}" install_sw
}
build_pcre2()
{
    cd "${PCRE2_SRC}"
    CFLAGS='-g -O3' ./configure \
        --prefix="${PCRE2_PREFIX}" \
        --libdir="${PCRE2_PREFIX}/lib" \
        --enable-jit \
        --enable-pcre2-8 \
        --enable-unicode \
        --enable-shared \
        --disable-static
    CFLAGS='-g -O3' make -j"${BUILD_JOBS}"
    CFLAGS='-g -O3' make -j"${BUILD_JOBS}" install
}
configure_openresty()
{
    cd "${OPENRESTY_SRC}"
    local args=(
        -j"${BUILD_JOBS}"
        --prefix="${INSTALL_PREFIX}"
        --with-compat
        --with-pcre
        --with-pcre-jit
        "--with-cc-opt=-O2 -DNGX_LUA_ABORT_AT_PANIC -I${PCRE2_PREFIX}/include -I${OPENSSL_PREFIX}/include"
        "--with-ld-opt=-L${PCRE2_PREFIX}/lib -L${OPENSSL_PREFIX}/lib -Wl,-rpath,${PCRE2_PREFIX}/lib:${OPENSSL_PREFIX}/lib"
        --with-http_sub_module
        --with-http_ssl_module
        --with-http_v2_module
        --with-http_realip_module
        --with-http_stub_status_module
        --with-http_gzip_static_module
        --with-http_slice_module
        --with-http_auth_request_module
        --with-http_secure_link_module
        --with-stream
        --with-stream_ssl_module
        --with-stream_ssl_preread_module
        --with-threads
    )
    [ "${ENABLE_SUBSTITUTIONS_FILTER}" = "false" ] || args+=("--add-module=${SUB_FILTER_SRC}")
    [ "${ENABLE_UPSTREAM_CHECK}" = "false" ] || args+=("--add-module=${UPSTREAM_CHECK_SRC}")
    ./configure "${args[@]}"
    NGINX_SRC="$(find "${OPENRESTY_SRC}/build" -maxdepth 1 -type d -name 'nginx-*' -print | sort -V | tail -n 1)"
    test -d "${NGINX_SRC}"
    NGINX_CORE_VERSION="$(basename "${NGINX_SRC}" | sed 's/^nginx-//')"
}
apply_upstream_check_patch()
{
    if [ "${ENABLE_UPSTREAM_CHECK}" != "true" ]; then
        SELECTED_UPSTREAM_PATCH=disabled
        return 0
    fi
    local candidates=() patch_file
    if [ "${UPSTREAM_CHECK_PATCH}" != "auto" ]; then
        candidates+=("${UPSTREAM_CHECK_SRC}/${UPSTREAM_CHECK_PATCH}")
    else
        while IFS= read -r patch_file; do candidates+=("${patch_file}"); done < <(
            find "${UPSTREAM_CHECK_SRC}" -maxdepth 1 -type f \( -name 'check_*.patch' -o -name 'check.patch' \) -print | sort -Vr
        )
    fi
    for patch_file in "${candidates[@]}"; do
        [ -f "${patch_file}" ] || continue
        echo "try patch: $(basename "${patch_file}")"
        if patch --dry-run --forward -d "${NGINX_SRC}" -p1 <"${patch_file}" >/dev/null 2>&1; then
            patch --forward -d "${NGINX_SRC}" -p1 <"${patch_file}"
            SELECTED_UPSTREAM_PATCH="$(basename "${patch_file}")"
            echo "selected patch: ${SELECTED_UPSTREAM_PATCH}"
            return 0
        fi
    done
    echo "No compatible nginx_upstream_check_module patch for nginx ${NGINX_CORE_VERSION}."
    echo "Set ENABLE_UPSTREAM_CHECK=false to build without this module, or provide a compatible patch."
    return 1
}
compile_openresty(){ cd "${OPENRESTY_SRC}"; make -j"${BUILD_JOBS}"; }
install_openresty(){ cd "${OPENRESTY_SRC}"; rm -rf "${INSTALL_PREFIX}"; make install; }
verify_binary()
{
    NGINX_BIN="${INSTALL_PREFIX}/nginx/sbin/nginx"
    test -x "${NGINX_BIN}"
    VERSION_INFO="$("${NGINX_BIN}" -V 2>&1)"
    printf '%s\n' "${VERSION_INFO}"
    grep -q -- '--with-http_stub_status_module' <<<"${VERSION_INFO}"
    [ "${ENABLE_UPSTREAM_CHECK}" = "false" ] || grep -q 'nginx_upstream_check_module' <<<"${VERSION_INFO}"
    if ldd "${NGINX_BIN}" | grep -q 'not found'; then ldd "${NGINX_BIN}"; return 1; fi
}
verify_directives()
{
    local test_root=/tmp/openresty-module-test
    rm -rf "${test_root}"; mkdir -p "${test_root}/logs"
    if [ "${ENABLE_UPSTREAM_CHECK}" = "true" ]; then
        cat >"${test_root}/nginx.conf" <<'CONF'
worker_processes 1;
error_log stderr notice;
pid /tmp/openresty-module-test/nginx.pid;
events { worker_connections 64; }
http {
    upstream test_backend {
        server 127.0.0.1:65535;
        check interval=3000 rise=1 fall=1 timeout=1000 type=tcp;
    }
    server {
        listen 127.0.0.1:18080;
        location = /nginx_status { stub_status; access_log off; }
        location = /upstream_status { check_status json; access_log off; }
    }
}
CONF
    else
        cat >"${test_root}/nginx.conf" <<'CONF'
worker_processes 1;
error_log stderr notice;
pid /tmp/openresty-module-test/nginx.pid;
events { worker_connections 64; }
http { server { listen 127.0.0.1:18080; location = /nginx_status { stub_status; access_log off; } } }
CONF
    fi
    "${INSTALL_PREFIX}/nginx/sbin/nginx" -t -p "${test_root}/" -c "${test_root}/nginx.conf"
}
package_openresty()
{
    local glibc package openssl_runtime
    glibc="$(ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    package="openresty-${OPENRESTY_VERSION}-glibc${glibc}-${BUILD_ARCH}.tar.gz"
    tar czf "${OUTPUT_DIR}/${package}" -C "$(dirname "${INSTALL_PREFIX}")" "$(basename "${INSTALL_PREFIX}")"
    (cd "${OUTPUT_DIR}" && sha256sum "${package}") >"${OUTPUT_DIR}/${package}.sha256"
    openssl_runtime="$("${INSTALL_PREFIX}/nginx/sbin/nginx" -V 2>&1 | sed -nE 's/^built with (OpenSSL[^ ]* [^ ]+.*)$/\1/p' | head -1)"
    cat >"${BUILD_INFO}" <<INFO
openresty_version=${OPENRESTY_VERSION}
nginx_core_version=${NGINX_CORE_VERSION}
openssl_version=${OPENSSL_VERSION}
openssl_runtime=${openssl_runtime}
openssl_patch_version=${OPENSSL_PATCH_VERSION}
pcre2_version=${PCRE2_VERSION}
substitutions_filter_enabled=${ENABLE_SUBSTITUTIONS_FILTER}
substitutions_filter_version=${SUB_FILTER_VERSION}
upstream_check_enabled=${ENABLE_UPSTREAM_CHECK}
upstream_check_ref=${UPSTREAM_CHECK_REF}
upstream_check_patch=${SELECTED_UPSTREAM_PATCH:-none}
http_stub_status_module=true
arch=${BUILD_ARCH}
glibc=${glibc}
build_jobs=${BUILD_JOBS}
install_prefix=${INSTALL_PREFIX}
INFO
    ls -lh "${OUTPUT_DIR}/${package}" "${OUTPUT_DIR}/${package}.sha256" "${BUILD_INFO}"
}
main()
{
    local start="$(date +%s)"
    run_stage 'check sources' check_sources
    run_stage 'extract sources' extract_sources
    run_stage 'detect paths' detect_paths
    run_stage 'build openssl' build_openssl
    run_stage 'build pcre2' build_pcre2
    run_stage 'configure openresty' configure_openresty
    run_stage 'apply upstream check patch' apply_upstream_check_patch
    run_stage 'compile openresty' compile_openresty
    run_stage 'install openresty' install_openresty
    run_stage 'verify binary' verify_binary
    run_stage 'verify directives' verify_directives
    run_stage 'package openresty' package_openresty
    echo "========================================"
    echo "BUILD SUCCESS"
    echo "openresty=${OPENRESTY_VERSION}"
    echo "nginx_core=${NGINX_CORE_VERSION}"
    echo "arch=${BUILD_ARCH}"
    echo "total=$(( $(date +%s)-start ))s"
    echo "========================================"
}
main "$@"
