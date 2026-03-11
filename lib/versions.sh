#!/bin/bash

# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ============================================================================
# Unified Version Management
# ============================================================================
#
# Usage: source lib/versions.sh
#        get_version <component> [timeout_seconds]
#
# Components: cli, setup, server
#
# Examples:
#   get_version cli          # Get nacos-cli version
#   get_version setup        # Get nacos-setup version
#   get_version server       # Get nacos-server version
#   get_version cli 2        # Get version with 2 second timeout
#
# Environment variables override remote versions:
#   NACOS_CLI_VERSION
#   NACOS_SETUP_VERSION
#   NACOS_SERVER_VERSION
#
# ============================================================================

# Base URL for downloads
DOWNLOAD_BASE_URL="https://download.nacos.io"
VERSIONS_URL="${DOWNLOAD_BASE_URL}/versions"

# ============================================================================
# Fallback Versions (used when versions file cannot be fetched)
# ============================================================================

FALLBACK_NACOS_CLI_VERSION="0.0.8"
FALLBACK_NACOS_SETUP_VERSION="0.0.2"
FALLBACK_NACOS_SERVER_VERSION="3.2.0-BETA"

# ============================================================================
# Cached versions (populated on first fetch)
# ============================================================================

_CACHED_CLI_VERSION=""
_CACHED_SETUP_VERSION=""
_CACHED_SERVER_VERSION=""
_VERSIONS_FETCHED=false

# ============================================================================
# Helper Functions
# ============================================================================

# Print info message (if common.sh is not loaded)
_versions_print_info() {
    if command -v print_info >/dev/null 2>&1; then
        print_info "$1" >&2
    else
        echo "[INFO] $1" >&2
    fi
}

# Print warn message (if common.sh is not loaded)
_versions_print_warn() {
    if command -v print_warn >/dev/null 2>&1; then
        print_warn "$1" >&2
    else
        echo "[WARN] $1" >&2
    fi
}

# Fetch versions from remote versions file
# Parameters: timeout_seconds (default: 1)
# Returns: 0 on success, 1 on failure
# Sets: _CACHED_*_VERSION variables
_fetch_versions() {
    local timeout=${1:-1}
    local temp_dir="/tmp/nacos-versions-$$"
    local versions_file="$temp_dir/versions"

    mkdir -p "$temp_dir" 2>/dev/null

    _versions_print_info "Fetching versions from $VERSIONS_URL..."

    # Try to download versions file with timeout
    local download_success=false
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --max-time "$timeout" "$VERSIONS_URL" -o "$versions_file" 2>/dev/null; then
            download_success=true
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --timeout="$timeout" "$VERSIONS_URL" -O "$versions_file" 2>/dev/null; then
            download_success=true
        fi
    fi

    if [[ "$download_success" != true ]] || [ ! -f "$versions_file" ] || [ ! -s "$versions_file" ]; then
        _versions_print_warn "Failed to fetch versions file (timeout or network error)"
        rm -rf "$temp_dir"
        return 1
    fi

    # Parse versions file
    local cli_ver=$(grep "^NACOS_CLI_VERSION=" "$versions_file" | cut -d'=' -f2 | tr -d '[:space:]')
    local setup_ver=$(grep "^NACOS_SETUP_VERSION=" "$versions_file" | cut -d'=' -f2 | tr -d '[:space:]')
    local server_ver=$(grep "^NACOS_SERVER_VERSION=" "$versions_file" | cut -d'=' -f2 | tr -d '[:space:]')

    rm -rf "$temp_dir"

    # Cache the fetched versions
    if [ -n "$cli_ver" ]; then
        _CACHED_CLI_VERSION="$cli_ver"
    fi
    if [ -n "$setup_ver" ]; then
        _CACHED_SETUP_VERSION="$setup_ver"
    fi
    if [ -n "$server_ver" ]; then
        _CACHED_SERVER_VERSION="$server_ver"
    fi

    _VERSIONS_FETCHED=true
    return 0
}

# ============================================================================
# Main Public Function
# ============================================================================

# Get version for specified component
# Parameters:
#   $1 - component name (cli, setup, server)
#   $2 - timeout in seconds (optional, default: 1)
# Returns: version string to stdout
get_version() {
    local component="$1"
    local timeout="${2:-1}"
    local env_var_name=""
    local fallback_version=""
    local cached_var=""

    # Validate component
    case "$component" in
        cli)
            env_var_name="NACOS_CLI_VERSION"
            fallback_version="$FALLBACK_NACOS_CLI_VERSION"
            cached_var="_CACHED_CLI_VERSION"
            ;;
        setup)
            env_var_name="NACOS_SETUP_VERSION"
            fallback_version="$FALLBACK_NACOS_SETUP_VERSION"
            cached_var="_CACHED_SETUP_VERSION"
            ;;
        server)
            env_var_name="NACOS_SERVER_VERSION"
            fallback_version="$FALLBACK_NACOS_SERVER_VERSION"
            cached_var="_CACHED_SERVER_VERSION"
            ;;
        *)
            echo "Error: Unknown component '$component'. Use: cli, setup, or server." >&2
            return 1
            ;;
    esac

    # Check environment variable first (highest priority)
    local env_value="${!env_var_name:-}"
    if [ -n "$env_value" ]; then
        echo "$env_value"
        return 0
    fi

    # Check if we have cached value
    local cached_value="${!cached_var:-}"
    if [ -n "$cached_value" ]; then
        echo "$cached_value"
        return 0
    fi

    # Try to fetch from remote (only once per script execution)
    if [ "$_VERSIONS_FETCHED" != true ]; then
        if _fetch_versions "$timeout"; then
            # Re-check cached value after fetch
            cached_value="${!cached_var:-}"
            if [ -n "$cached_value" ]; then
                echo "$cached_value"
                return 0
            fi
        fi
    fi

    # Return fallback version
    echo "$fallback_version"
    return 0
}

# Get all versions at once (useful for installer)
# Parameters: timeout_seconds (optional, default: 1)
# Sets global variables: NACOS_CLI_VERSION, NACOS_SETUP_VERSION, NACOS_SERVER_VERSION
get_all_versions() {
    local timeout="${1:-1}"

    # Fetch all versions (will use cache if already fetched)
    NACOS_CLI_VERSION=$(get_version cli "$timeout")
    NACOS_SETUP_VERSION=$(get_version setup "$timeout")
    NACOS_SERVER_VERSION=$(get_version server "$timeout")
}

# Print all versions (for debugging)
print_versions() {
    echo "Nacos Component Versions:"
    echo "  CLI:    $(get_version cli) (fallback: $FALLBACK_NACOS_CLI_VERSION)"
    echo "  Setup:  $(get_version setup) (fallback: $FALLBACK_NACOS_SETUP_VERSION)"
    echo "  Server: $(get_version server) (fallback: $FALLBACK_NACOS_SERVER_VERSION)"
}
