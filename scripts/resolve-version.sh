#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/openresty-version.conf"
REQUESTED_VERSION="${1:-}"
if [ -f "${CONFIG_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi
REQUESTED_VERSION="${REQUESTED_VERSION:-${OPENRESTY_VERSION:-latest}}"
FALLBACK_VERSION="${OPENRESTY_FALLBACK_VERSION:-1.31.1.1}"
ALLOW_FALLBACK="${ALLOW_LATEST_FALLBACK:-true}"
validate_version()
{
    printf '%s' "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}
resolve_latest()
{
    local page versions latest
    if page="$(curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 60 https://openresty.org/en/download.html)"; then
        versions="$(printf '%s\n' "${page}" \
            | grep -oE 'openresty-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
            | sed -E 's/^openresty-//;s/\.tar\.gz$//' \
            | sort -Vu || true)"
        latest="$(printf '%s\n' "${versions}" | tail -n 1)"
        if [ -n "${latest}" ] && validate_version "${latest}"; then
            printf '%s\n' "${latest}"
            return 0
        fi
    fi
    if [ "${ALLOW_FALLBACK}" = "true" ] && validate_version "${FALLBACK_VERSION}"; then
        echo "[WARN] 无法从 OpenResty 官网解析最新版本，使用回退版本 ${FALLBACK_VERSION}" >&2
        printf '%s\n' "${FALLBACK_VERSION}"
        return 0
    fi
    echo "[ERROR] 无法解析 OpenResty 最新版本" >&2
    return 1
}
case "${REQUESTED_VERSION}" in
    latest|LATEST|Latest)
        resolve_latest
        ;;
    *)
        if ! validate_version "${REQUESTED_VERSION}"; then
            echo "[ERROR] 非法 OpenResty 版本：${REQUESTED_VERSION}" >&2
            exit 1
        fi
        printf '%s\n' "${REQUESTED_VERSION}"
        ;;
esac
