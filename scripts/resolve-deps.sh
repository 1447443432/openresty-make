#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/build.conf"
if [ -f "${CONFIG_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi
OPENRESTY_DOCKER_REF="${OPENRESTY_DOCKER_REF:-master}"
ALLOW_FALLBACK="${ALLOW_DEPENDENCY_FALLBACK:-true}"
OPENSSL_FALLBACK_VERSION="${OPENSSL_FALLBACK_VERSION:-3.5.7}"
OPENSSL_PATCH_FALLBACK_VERSION="${OPENSSL_PATCH_FALLBACK_VERSION:-3.5.5}"
PCRE2_FALLBACK_VERSION="${PCRE2_FALLBACK_VERSION:-10.47}"
PCRE2_FALLBACK_SHA256="${PCRE2_FALLBACK_SHA256:-c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16}"
DOCKERFILE_URL="https://raw.githubusercontent.com/openresty/docker-openresty/${OPENRESTY_DOCKER_REF}/noble/Dockerfile"
need_auto=false
for value in "${OPENSSL_VERSION:-auto}" "${OPENSSL_PATCH_VERSION:-auto}" "${PCRE2_VERSION:-auto}" "${PCRE2_SHA256:-auto}"; do
    if [ "${value}" = "auto" ]; then
        need_auto=true
    fi
done
extract_arg()
{
    local name="$1"
    local content="$2"
    printf '%s\n' "${content}" \
        | sed -nE "s/^ARG[[:space:]]+${name}=\"?([^\"[:space:]]+)\"?.*/\1/p" \
        | head -n 1
}
if [ "${need_auto}" = "true" ]; then
    official_dockerfile=""
    if ! official_dockerfile="$(curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 60 "${DOCKERFILE_URL}")"; then
        if [ "${ALLOW_FALLBACK}" != "true" ]; then
            echo "[ERROR] 无法读取 ${DOCKERFILE_URL}" >&2
            exit 1
        fi
        echo "[WARN] 无法读取官方 docker-openresty 配置，使用回退依赖版本" >&2
    fi
    if [ "${OPENSSL_VERSION:-auto}" = "auto" ]; then
        OPENSSL_VERSION="$(extract_arg RESTY_OPENSSL_VERSION "${official_dockerfile}")"
        OPENSSL_VERSION="${OPENSSL_VERSION:-${OPENSSL_FALLBACK_VERSION}}"
    fi
    if [ "${OPENSSL_PATCH_VERSION:-auto}" = "auto" ]; then
        OPENSSL_PATCH_VERSION="$(extract_arg RESTY_OPENSSL_PATCH_VERSION "${official_dockerfile}")"
        OPENSSL_PATCH_VERSION="${OPENSSL_PATCH_VERSION:-${OPENSSL_PATCH_FALLBACK_VERSION}}"
    fi
    if [ "${PCRE2_VERSION:-auto}" = "auto" ]; then
        PCRE2_VERSION="$(extract_arg RESTY_PCRE_VERSION "${official_dockerfile}")"
        PCRE2_VERSION="${PCRE2_VERSION:-${PCRE2_FALLBACK_VERSION}}"
    fi
    if [ "${PCRE2_SHA256:-auto}" = "auto" ]; then
        PCRE2_SHA256="$(extract_arg RESTY_PCRE_SHA256 "${official_dockerfile}")"
        PCRE2_SHA256="${PCRE2_SHA256:-${PCRE2_FALLBACK_SHA256}}"
    fi
fi
for name in OPENSSL_VERSION OPENSSL_PATCH_VERSION PCRE2_VERSION PCRE2_SHA256; do
    value="${!name:-}"
    if [ -z "${value}" ] || [ "${value}" = "auto" ]; then
        echo "[ERROR] ${name} 未解析成功" >&2
        exit 1
    fi
done
if ! printf '%s' "${PCRE2_SHA256}" | grep -qE '^[0-9a-fA-F]{64}$'; then
    echo "[ERROR] PCRE2_SHA256 格式错误：${PCRE2_SHA256}" >&2
    exit 1
fi
printf 'OPENSSL_VERSION=%s\n' "${OPENSSL_VERSION}"
printf 'OPENSSL_PATCH_VERSION=%s\n' "${OPENSSL_PATCH_VERSION}"
printf 'PCRE2_VERSION=%s\n' "${PCRE2_VERSION}"
printf 'PCRE2_SHA256=%s\n' "${PCRE2_SHA256}"
