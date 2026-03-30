#!/bin/bash

# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0

# Bundled JDK 17 for Nacos 3.x when no Java 17+ is on PATH / JAVA_HOME.
# Expects lib/common.sh to be sourced (print_*, get_java_version, detect_os_arch).
#
# Downloads from https://download.nacos.io/base/jdk17-<os>-<arch>.zip (cached under
# ~/.nacos/cache like nacos-server / nacos-setup packages). Override full URL with
# NACOS_SETUP_JRE17_DOWNLOAD_URL.
#
# Set NACOS_SETUP_SKIP_BUNDLED_JRE=1 to skip this step.

BUNDLED_JDK_CACHE_DIR="${NACOS_CACHE_DIR:-$HOME/.nacos/cache}"
JDK17_OSS_BASE="https://download.nacos.io/base"

# Install tree (same as nacos-setup DEFAULT_INSTALL_DIR / standalone parent)
BUNDLED_JRE_PARENT="${NACOS_SETUP_BUNDLED_JRE_PARENT:-$HOME/ai-infra/nacos}"
BUNDLED_JRE_ROOT="${NACOS_SETUP_BUNDLED_JRE_DIR:-$BUNDLED_JRE_PARENT/.bundled-jre-17}"

_nacos_major_version() {
    local v="$1"
    echo "${v}" | cut -d. -f1 | sed 's/[^0-9].*$//;s/^$/0/'
}

_nacos_requires_java17() {
    local nacos_version="$1"
    local major
    major=$(_nacos_major_version "$nacos_version")
    [ "${major:-0}" -ge 3 ]
}

_java_major_at_least_17() {
    local java_cmd="$1"
    local jv
    jv=$(get_java_version "$java_cmd" 2>/dev/null || echo "0")
    [ "${jv:-0}" -ge 17 ]
}

_java17_already_on_system() {
    if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
        if _java_major_at_least_17 "${JAVA_HOME}/bin/java"; then
            return 0
        fi
    fi
    # Windows Git Bash: java.exe under JAVA_HOME/bin
    if [ -n "${JAVA_HOME:-}" ] && [ -f "${JAVA_HOME}/bin/java.exe" ]; then
        if _java_major_at_least_17 "${JAVA_HOME}/bin/java.exe"; then
            return 0
        fi
    fi
    if command -v java >/dev/null 2>&1; then
        if _java_major_at_least_17 java; then
            return 0
        fi
    fi
    return 1
}

# Map detect_os_arch -> OSS path segment (darwin | linux | windows)
_bundled_jdk_os_segment() {
    case "$(detect_os_arch)" in
        macos) echo darwin ;;
        linux) echo linux ;;
        windows) echo windows ;;
        *) echo unknown ;;
    esac
}

_bundled_jdk_machine_arch() {
    case "$(uname -m 2>/dev/null)" in
        x86_64 | amd64) echo amd64 ;;
        arm64 | aarch64) echo arm64 ;;
        *) echo unknown ;;
    esac
}

# Echo download URL or return 1 if unsupported / unknown
_bundled_jdk_resolve_url() {
    if [ -n "${NACOS_SETUP_JRE17_DOWNLOAD_URL:-}" ]; then
        printf '%s\n' "$NACOS_SETUP_JRE17_DOWNLOAD_URL"
        return 0
    fi

    local os arch
    os=$(_bundled_jdk_os_segment)
    arch=$(_bundled_jdk_machine_arch)

    if [ "$os" = unknown ] || [ "$arch" = unknown ]; then
        print_error "Cannot detect OS/arch for bundled JDK (os=$os arch=$arch)."
        return 1
    fi

    # Published matrix (see download.nacos.io/base)
    case "${os}-${arch}" in
        darwin-amd64 | darwin-arm64 | linux-amd64 | windows-amd64) ;;
        linux-arm64)
            print_error "No bundled JDK 17 package for linux-arm64. Install JDK 17 manually and retry."
            return 1
            ;;
        windows-arm64)
            print_error "No bundled JDK 17 package for windows-arm64. Install JDK 17 manually and retry."
            return 1
            ;;
        *)
            print_error "No bundled JDK 17 package for ${os}-${arch}. Install JDK 17 manually and retry."
            return 1
            ;;
    esac

    printf '%s\n' "${JDK17_OSS_BASE}/jdk17-${os}-${arch}.zip"
}

_bundled_find_java_binary() {
    local root="$1"
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            */bin/java | */bin/java.exe | */Contents/Home/bin/java)
                if [ -x "$f" ]; then
                    printf '%s\n' "$f"
                    return 0
                fi
                if [[ "$f" == *.exe ]] && [ -f "$f" ]; then
                    printf '%s\n' "$f"
                    return 0
                fi
                ;;
        esac
    done < <(find "$root" -type f \( -name java -o -name java.exe \) 2>/dev/null)
    return 1
}

_apply_bundled_java_home_from_root() {
    local root="$1"
    local java_bin
    java_bin=$(_bundled_find_java_binary "$root") || return 1
    if ! _java_major_at_least_17 "$java_bin"; then
        return 1
    fi
    # .../bin/java or .../bin/java.exe -> JDK/JRE root; .../Contents/Home/bin/java -> JAVA_HOME = .../Home
    JAVA_HOME="$(dirname "$(dirname "$java_bin")")"
    export JAVA_HOME
    export PATH="${JAVA_HOME}/bin:${PATH}"
    return 0
}

_bundled_jre_reuse_if_present() {
    if [ ! -d "$BUNDLED_JRE_ROOT" ]; then
        return 1
    fi
    if _apply_bundled_java_home_from_root "$BUNDLED_JRE_ROOT"; then
        print_detail "Using existing bundled JRE at JAVA_HOME=$JAVA_HOME"
        return 0
    fi
    return 1
}

_confirm_bundled_jre_install() {
    if [ ! -t 0 ]; then
        print_warn "Java 17+ is required for Nacos 3.x. Non-interactive shell: cannot prompt for bundled JDK download."
        print_warn "Install JDK 17+, set JAVA_HOME, or run nacos-setup in a terminal."
        return 1
    fi
    local confirm
    read -r -p "Java 17+ not found. Download JDK 17 from Nacos OSS into ${BUNDLED_JRE_ROOT} (cache: ${BUNDLED_JDK_CACHE_DIR})? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

# Obtain path to jdk zip (from cache or download). Echoes path on success.
_bundled_jdk_acquire_zip() {
    local url="$1"
    local zip_name
    zip_name=$(basename "${url%%\?*}")
    [ -n "$zip_name" ] || zip_name="jdk17-custom.zip"
    local cached_file="${BUNDLED_JDK_CACHE_DIR}/${zip_name}"

    mkdir -p "$BUNDLED_JDK_CACHE_DIR" 2>/dev/null

    if [ -f "$cached_file" ] && [ -s "$cached_file" ]; then
        if unzip -t "$cached_file" >/dev/null 2>&1; then
            print_detail "Found cached JDK package: $cached_file"
            printf '%s\n' "$cached_file"
            return 0
        fi
        print_warn "Cached JDK archive is invalid, re-downloading..."
        rm -f "$cached_file"
    fi

    print_detail "Downloading JDK 17: $url"
    if [ "$VERBOSE" = true ]; then echo ""; fi

    local curl_jdk_flag="-s"
    if [ "$VERBOSE" = true ]; then curl_jdk_flag="-#"; fi
    if ! curl -fL $curl_jdk_flag -o "$cached_file" "$url"; then
        if [ "$VERBOSE" = true ]; then echo "" >&2; fi
        print_error "Failed to download JDK 17."
        rm -f "$cached_file" 2>/dev/null || true
        return 1
    fi
    if [ "$VERBOSE" = true ]; then echo ""; fi

    if ! unzip -t "$cached_file" >/dev/null 2>&1; then
        print_error "Downloaded file is not a valid zip."
        rm -f "$cached_file" 2>/dev/null || true
        return 1
    fi

    print_detail "Download completed: $zip_name"
    printf '%s\n' "$cached_file"
    return 0
}

_download_extract_bundled_jre() {
    local url
    url=$(_bundled_jdk_resolve_url) || return 1

    local zip_path
    zip_path=$(_bundled_jdk_acquire_zip "$url") || return 1

    if ! command -v unzip >/dev/null 2>&1; then
        print_error "Command 'unzip' is required to extract the JDK archive."
        return 1
    fi

    mkdir -p "$BUNDLED_JRE_ROOT"
    rm -rf "${BUNDLED_JRE_ROOT:?}/"*

    print_detail "Extracting JDK into ${BUNDLED_JRE_ROOT}..."
    if ! unzip -q "$zip_path" -d "$BUNDLED_JRE_ROOT"; then
        print_error "Failed to extract JDK archive."
        return 1
    fi

    if ! _apply_bundled_java_home_from_root "$BUNDLED_JRE_ROOT"; then
        print_error "Extracted archive did not contain a usable Java 17+ under $BUNDLED_JRE_ROOT"
        return 1
    fi

    print_detail "Bundled JDK ready: JAVA_HOME=$JAVA_HOME"
    return 0
}

# Returns:
#   0 — Java 17+ available; continue nacos-setup
#   2 — User declined or non-interactive without JRE; exit 0 from nacos-setup
#   1 — Error
ensure_bundled_java17_for_nacos_setup() {
    local nacos_version="${1:-}"

    if ! _nacos_requires_java17 "$nacos_version"; then
        return 0
    fi

    if [ "${NACOS_SETUP_SKIP_BUNDLED_JRE:-}" = "1" ] || [ "${NACOS_SETUP_SKIP_BUNDLED_JRE:-}" = "true" ]; then
        return 0
    fi

    if _java17_already_on_system; then
        print_detail "Java 17+ already available for Nacos ${nacos_version}."
        return 0
    fi

    if _bundled_jre_reuse_if_present; then
        return 0
    fi

    print_info "Nacos ${nacos_version} requires Java 17+. None found in JAVA_HOME or PATH."

    if ! _confirm_bundled_jre_install; then
        print_info "Skipping bundled JDK installation. Exiting without starting Nacos setup."
        return 2
    fi

    if ! _download_extract_bundled_jre; then
        return 1
    fi

    return 0
}
