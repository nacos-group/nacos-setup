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
# Set NACOS_SETUP_SKIP_AUTO_INSTALL_UNZIP=1 to refuse auto-installing unzip (fail if missing).

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
    if command -v java >/dev/null 2>&1; then
        if _java_major_at_least_17 java; then
            return 0
        fi
    fi
    return 1
}

# Map detect_os_arch -> OSS path segment (darwin | linux)
_bundled_jdk_os_segment() {
    case "$(detect_os_arch)" in
        macos) echo darwin ;;
        linux) echo linux ;;
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
        print_error "Cannot detect OS/arch for bundled JDK (os=$os arch=$arch)." >&2
        return 1
    fi

    # Published matrix (see download.nacos.io/base)
    case "${os}-${arch}" in
        darwin-amd64 | darwin-arm64 | linux-amd64) ;;
        linux-arm64)
            print_error "No bundled JDK 17 package for linux-arm64. Install JDK 17 manually and retry." >&2
            return 1
            ;;
        *)
            print_error "No bundled JDK 17 package for ${os}-${arch}. Install JDK 17 manually and retry." >&2
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
            */bin/java | */Contents/Home/bin/java)
                if [ -x "$f" ]; then
                    printf '%s\n' "$f"
                    return 0
                fi
                ;;
        esac
    done < <(find "$root" -type f -name java 2>/dev/null)
    return 1
}

# OSS zip often wraps the real JDK as jdk17-*-*.tar.gz (not a flat bin/java tree).
_bundled_extract_inner_payload_if_needed() {
    local root="$1"
    local tg

    rm -rf "${root}/__MACOSX" 2>/dev/null || true

    if _bundled_find_java_binary "$root" >/dev/null 2>&1; then
        return 0
    fi

    tg=$(find "$root" -maxdepth 1 -type f \( -name 'jdk17-*.tar.gz' -o -name 'jdk-*.tar.gz' \) 2>/dev/null | head -1)
    if [ -z "$tg" ]; then
        tg=$(find "$root" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | head -1)
    fi
    if [ -z "$tg" ]; then
        return 0
    fi

    print_detail "Extracting inner JDK archive: $(basename "$tg")"
    if ! command -v tar >/dev/null 2>&1; then
        print_error "Command 'tar' is required to extract the JDK tarball." >&2
        return 1
    fi
    if ! tar -xzf "$tg" -C "$root"; then
        print_error "Failed to extract inner JDK tarball: $tg" >&2
        return 1
    fi
    return 0
}

_apply_bundled_java_home_from_root() {
    local root="$1"
    local java_bin
    java_bin=$(_bundled_find_java_binary "$root") || return 1
    if ! _java_major_at_least_17 "$java_bin"; then
        return 1
    fi
    # .../bin/java -> JDK/JRE root; .../Contents/Home/bin/java -> JAVA_HOME = .../Home
    JAVA_HOME="$(dirname "$(dirname "$java_bin")")"
    export JAVA_HOME
    export PATH="${JAVA_HOME}/bin:${PATH}"
    return 0
}

_bundled_jre_reuse_if_present() {
    if [ ! -d "$BUNDLED_JRE_ROOT" ]; then
        return 1
    fi
    if ! _bundled_extract_inner_payload_if_needed "$BUNDLED_JRE_ROOT"; then
        return 1
    fi
    if _apply_bundled_java_home_from_root "$BUNDLED_JRE_ROOT"; then
        print_detail "Using existing bundled JRE at JAVA_HOME=$JAVA_HOME"
        return 0
    fi
    return 1
}

_confirm_bundled_jre_install() {
    local prompt="Java 17+ not found. Download JDK 17 from Nacos OSS into ${BUNDLED_JRE_ROOT} (cache: ${BUNDLED_JDK_CACHE_DIR})? (Y/n): "

    if declare -F nacos_setup_read_prompt >/dev/null 2>&1; then
        nacos_setup_read_prompt "$prompt"
        local pr=$?
        if [ "$pr" -eq 2 ]; then
            print_warn "Java 17+ is required for Nacos 3.x. Non-interactive shell: cannot prompt for bundled JDK download."
            print_warn "Install JDK 17+, set JAVA_HOME, or run nacos-setup in a terminal."
            return 1
        fi
        if [ "$pr" -ne 0 ]; then
            return 1
        fi
        if [[ "${REPLY:-}" =~ ^[Nn]$ ]]; then
            return 1
        fi
        return 0
    fi

    local confirm
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf '\n' >&2
        read -r -p "$prompt" confirm </dev/tty 2>/dev/tty
    elif [ -t 0 ]; then
        printf '\n' >&2
        read -r -p "$prompt" confirm
    else
        print_warn "Java 17+ is required for Nacos 3.x. Non-interactive shell: cannot prompt for bundled JDK download."
        print_warn "Install JDK 17+, set JAVA_HOME, or run nacos-setup in a terminal."
        return 1
    fi
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

# Package installs: noisy (dnf/yum/brew). Verbose -> show on stderr; simple UI -> discard.
_bundled_run_pkg_install() {
    if [ "${VERBOSE:-false}" = true ]; then
        "$@" 1>&2
    else
        "$@" >/dev/null 2>&1
    fi
}

# Run a command with root privileges when needed (package install).
_bundled_run_as_root() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        print_error "unzip is missing and you are not root; install unzip manually or re-run with sudo." >&2
        return 1
    fi
}

# Ensure unzip exists; try to install on common Linux/macOS when absent.
_bundled_ensure_unzip() {
    if command -v unzip >/dev/null 2>&1; then
        return 0
    fi

    if [ "${NACOS_SETUP_SKIP_AUTO_INSTALL_UNZIP:-}" = "1" ] || [ "${NACOS_SETUP_SKIP_AUTO_INSTALL_UNZIP:-}" = "true" ]; then
        print_error "unzip is not installed; auto-install disabled (NACOS_SETUP_SKIP_AUTO_INSTALL_UNZIP=1)." >&2
        print_info  "Install: yum install -y unzip   or   apt-get install -y unzip" >&2
        return 1
    fi

    print_detail "unzip not found; attempting to install..."

    local os
    os=$(detect_os_arch)

    case "$os" in
        linux)
            if command -v apt-get >/dev/null 2>&1; then
                if _bundled_run_pkg_install _bundled_run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip; then
                    command -v unzip >/dev/null 2>&1 && return 0
                fi
                if _bundled_run_pkg_install _bundled_run_as_root env DEBIAN_FRONTEND=noninteractive sh -c 'apt-get update -qq && apt-get install -y -qq unzip'; then
                    command -v unzip >/dev/null 2>&1 && return 0
                fi
            fi
            if command -v dnf >/dev/null 2>&1; then
                if _bundled_run_pkg_install _bundled_run_as_root dnf install -y unzip; then
                    command -v unzip >/dev/null 2>&1 && return 0
                fi
            fi
            if command -v yum >/dev/null 2>&1; then
                if _bundled_run_pkg_install _bundled_run_as_root yum install -y unzip; then
                    command -v unzip >/dev/null 2>&1 && return 0
                fi
            fi
            if command -v apk >/dev/null 2>&1; then
                if _bundled_run_pkg_install _bundled_run_as_root apk add --no-cache unzip; then
                    command -v unzip >/dev/null 2>&1 && return 0
                fi
            fi
            if command -v zypper >/dev/null 2>&1; then
                if _bundled_run_pkg_install _bundled_run_as_root zypper install -y unzip; then
                    command -v unzip >/dev/null 2>&1 && return 0
                fi
            fi
            ;;
        macos)
            if command -v brew >/dev/null 2>&1; then
                if _bundled_run_pkg_install brew install unzip; then
                    command -v unzip >/dev/null 2>&1 && return 0
                fi
            fi
            ;;
    esac

    if command -v unzip >/dev/null 2>&1; then
        return 0
    fi
    print_error "Could not install unzip automatically. Install manually (e.g. yum install -y unzip or apt-get install -y unzip)." >&2
    return 1
}

# Obtain path to jdk zip (from cache or download). Echoes path on success.
_bundled_jdk_acquire_zip() {
    local url="$1"
    local zip_name
    zip_name=$(basename "${url%%\?*}")
    [ -n "$zip_name" ] || zip_name="jdk17-custom.zip"
    local cached_file="${BUNDLED_JDK_CACHE_DIR}/${zip_name}"

    mkdir -p "$BUNDLED_JDK_CACHE_DIR" 2>/dev/null

    if ! _bundled_ensure_unzip; then
        return 1
    fi

    if [ -f "$cached_file" ] && [ -s "$cached_file" ]; then
        if unzip -t "$cached_file" >/dev/null 2>&1; then
            print_detail "Found cached JDK package: $cached_file"
            printf '%s\n' "$cached_file"
            return 0
        fi
        print_warn "Cached JDK archive is invalid, re-downloading..." >&2
        rm -f "$cached_file"
    fi

    print_detail "Downloading JDK 17: $url"
    # Do not use curl -s nor redirect curl stderr to /dev/null: some environments fail immediately
    # while -x works. zip_path=$(...) only captures stdout; curl progress/errors use stderr.
    if [ "${VERBOSE:-false}" = true ]; then
        echo ""
        if ! curl -fL -# -o "$cached_file" "$url" </dev/null; then
            echo ""
            print_error "Failed to download JDK 17." >&2
            rm -f "$cached_file" 2>/dev/null || true
            return 1
        fi
        echo ""
    else
        # Prefer --no-progress-meter (quiet, stderr still open) when available; else same as -x (-#).
        if curl --help 2>&1 | grep -q -- '--no-progress-meter'; then
            if ! curl -fL --no-progress-meter -o "$cached_file" "$url" </dev/null; then
                print_error "Failed to download JDK 17." >&2
                rm -f "$cached_file" 2>/dev/null || true
                return 1
            fi
        else
            if ! curl -fL -# -o "$cached_file" "$url" </dev/null; then
                print_error "Failed to download JDK 17." >&2
                rm -f "$cached_file" 2>/dev/null || true
                return 1
            fi
        fi
    fi

    if ! unzip -t "$cached_file" >/dev/null 2>&1; then
        print_error "Downloaded file is not a valid zip: $cached_file" >&2
        print_error "The file may be corrupted or the download URL may be invalid." >&2
        print_info  "URL: $url" >&2
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
    # $(...) must yield only the zip path; if anything wrote to stdout, keep the last non-empty line.
    zip_path="${zip_path//$'\r'/}"
    zip_path="$(printf '%s\n' "$zip_path" | sed '/^$/d' | tail -n1)"
    if [ ! -f "$zip_path" ]; then
        print_error "JDK zip path is not a readable file: ${zip_path:-<empty>}" >&2
        return 1
    fi

    mkdir -p "$BUNDLED_JRE_ROOT"
    rm -rf "${BUNDLED_JRE_ROOT:?}/"*

    print_detail "Extracting JDK into ${BUNDLED_JRE_ROOT}..."
    if ! unzip -q "$zip_path" -d "$BUNDLED_JRE_ROOT"; then
        print_error "Failed to extract JDK archive: $zip_path" >&2
        return 1
    fi

    if ! _bundled_extract_inner_payload_if_needed "$BUNDLED_JRE_ROOT"; then
        return 1
    fi

    if ! _apply_bundled_java_home_from_root "$BUNDLED_JRE_ROOT"; then
        print_error "Extracted archive did not contain a usable Java 17+ under $BUNDLED_JRE_ROOT" >&2
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
