#!/bin/bash

# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Import default agentspec / skill data into the Nacos data directory.
# Downloads the official archives once and copies the original zip files
# into each installed node's data folder.

DEFAULT_SKILLS_DATA_URL="${NACOS_SETUP_SKILLS_DATA_URL:-https://download.nacos.io/nacos-server-data/skills-data.zip}"
DEFAULT_AGENTSPEC_DATA_URL="${NACOS_SETUP_AGENTSPEC_DATA_URL:-https://download.nacos.io/nacos-server-data/agentspec-data.zip}"
NACOS_DATA_CACHE_DIR="${NACOS_DATA_CACHE_DIR:-${NACOS_CACHE_DIR:-$HOME/.nacos/cache}/data}"

_data_import_trace() {
    if [ "${VERBOSE:-false}" = true ]; then
        printf '%s\n' "[nacos-setup/data-import] $*" >&2
    fi
}

_data_import_skip_requested() {
    case "${NACOS_SETUP_SKIP_DEFAULT_DATA:-}" in
        1|true|TRUE|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_data_import_force_requested() {
    case "${NACOS_SETUP_FORCE_DEFAULT_DATA_IMPORT:-}" in
        1|true|TRUE|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_download_default_data_archive() {
    local archive_name=$1
    local archive_url=$2
    local cached_file="${NACOS_DATA_CACHE_DIR}/${archive_name}.zip"

    mkdir -p "$NACOS_DATA_CACHE_DIR" 2>/dev/null

    if [ -f "$cached_file" ] && [ -s "$cached_file" ]; then
        if unzip -t "$cached_file" >/dev/null 2>&1; then
            echo "$cached_file"
            return 0
        fi
        _data_import_trace "cached archive is invalid, re-downloading: $cached_file"
        rm -f "$cached_file"
    fi

    print_detail "Downloading ${archive_name} from ${archive_url}" >&2
    local curl_data_flag="-s"
    if [ "${VERBOSE:-false}" = true ]; then curl_data_flag="-#"; fi
    if curl -fL --retry 3 $curl_data_flag -o "$cached_file" "$archive_url" >&2; then
        if [ "${VERBOSE:-false}" = true ]; then echo "" >&2; fi
        if unzip -t "$cached_file" >/dev/null 2>&1; then
            echo "$cached_file"
            return 0
        fi
        print_warn "Downloaded ${archive_name} archive is invalid, skipping import"
        rm -f "$cached_file"
        return 1
    fi

    if [ "${VERBOSE:-false}" = true ]; then echo "" >&2; fi
    print_warn "Failed to download ${archive_name} from ${archive_url}"
    rm -f "$cached_file"
    return 1
}

_import_default_data_archive() {
    local install_dir=$1
    local archive_name=$2
    local archive_url=$3
    local data_dir="${install_dir}/data"
    local target_archive="${data_dir}/${archive_name}.zip"
    local marker_file="${data_dir}/.nacos-setup-${archive_name}.url"
    local archive_file=""

    mkdir -p "$data_dir" 2>/dev/null || {
        print_warn "Cannot create data directory: $data_dir"
        return 0
    }

    if ! _data_import_force_requested && [ -f "$marker_file" ] && grep -Fxq "$archive_url" "$marker_file" 2>/dev/null; then
        print_detail "${archive_name} already imported into ${data_dir}, skipping"
        return 0
    fi

    archive_file=$(_download_default_data_archive "$archive_name" "$archive_url") || return 0

    print_detail "Copying ${archive_name}.zip into ${data_dir}"
    if cp "$archive_file" "$target_archive" 2>/dev/null; then
        printf '%s\n' "$archive_url" > "$marker_file"
        return 0
    fi

    print_warn "Failed to copy ${archive_name}.zip into ${data_dir}"
    return 0
}

maybe_import_default_data_for_nacos() {
    local install_dir=$1

    if _data_import_skip_requested; then
        _data_import_trace "skip: NACOS_SETUP_SKIP_DEFAULT_DATA is set"
        return 0
    fi

    if [ -z "$install_dir" ] || [ ! -d "$install_dir" ]; then
        print_warn "Default data import skipped: install dir not found: ${install_dir:-<empty>}"
        return 0
    fi

    _import_default_data_archive "$install_dir" "skills-data" "$DEFAULT_SKILLS_DATA_URL"
    _import_default_data_archive "$install_dir" "agentspec-data" "$DEFAULT_AGENTSPEC_DATA_URL"
}

run_post_nacos_config_data_import_hook() {
    local install_dir=$1
    maybe_import_default_data_for_nacos "$install_dir"
}
