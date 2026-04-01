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

# Database Schema Export Module
# Exports full schema SQL for a given Nacos version and database type

# Supported database types
DB_SCHEMA_SUPPORTED_TYPES=("mysql" "postgresql")

# Cache directory for downloaded schema files
DB_SCHEMA_CACHE_DIR="${NACOS_CACHE_DIR:-$HOME/.nacos/cache}"

# ============================================================================
# Validation
# ============================================================================

validate_db_type() {
    local db_type="$1"
    if [ -z "$db_type" ]; then
        print_error "Database type is required" >&2
        return 1
    fi
    for supported in "${DB_SCHEMA_SUPPORTED_TYPES[@]}"; do
        if [ "$db_type" = "$supported" ]; then
            return 0
        fi
    done
    print_error "Unsupported database type: $db_type" >&2
    print_info "Supported types: ${DB_SCHEMA_SUPPORTED_TYPES[*]}" >&2
    return 1
}

# ============================================================================
# Local Schema Lookup
# ============================================================================

# Find schema file from a local Nacos installation.
# Uses NACOS_INSTALL_BASE env var if set (for testing), otherwise $HOME/.nacos/nacos-server-$VERSION.
# Outputs the file path to stdout if found, empty otherwise.
find_local_schema() {
    local version="$1"
    local db_type="$2"
    local nacos_home="${NACOS_INSTALL_BASE:-$HOME/.nacos/nacos-server-$version}/nacos"

    # New-style: plugin-ext directory (Nacos >3.1.1)
    local new_path="$nacos_home/plugin-ext/nacos-datasource-plugin-${db_type}/${db_type}-schema.sql"
    if [ -f "$new_path" ]; then
        echo "$new_path"
        return 0
    fi

    # Old-style: conf directory (Nacos <=3.1.1)
    local old_path="$nacos_home/conf/${db_type}-schema.sql"
    if [ -f "$old_path" ]; then
        echo "$old_path"
        return 0
    fi

    return 1
}

# ============================================================================
# Remote Schema Download
# ============================================================================

# Returns the cache file path for a given version and type.
_schema_cache_path() {
    local version="$1"
    local db_type="$2"
    echo "${DB_SCHEMA_CACHE_DIR}/${version}-${db_type}-schema.sql"
}

# Build the GitHub raw URL for a schema file.
# Tries new plugin path first, falls back to old distribution/conf path.
_schema_github_urls() {
    local version="$1"
    local db_type="$2"
    # New path (Nacos >3.1.1, after plugin refactor)
    echo "https://raw.githubusercontent.com/alibaba/nacos/${version}/plugin-default-impl/nacos-default-datasource-plugin/nacos-datasource-plugin-${db_type}/src/main/resources/META-INF/${db_type}-schema.sql"
    # Old path (Nacos <=3.1.1)
    echo "https://raw.githubusercontent.com/alibaba/nacos/${version}/distribution/conf/${db_type}-schema.sql"
}

# Download schema from GitHub with new-path-first fallback.
# Caches the result. Outputs the local file path on success.
download_schema() {
    local version="$1"
    local db_type="$2"

    # Check cache first
    local cache_file
    cache_file=$(_schema_cache_path "$version" "$db_type")
    if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
        print_info "Using cached schema: $cache_file" >&2
        echo "$cache_file"
        return 0
    fi

    mkdir -p "$DB_SCHEMA_CACHE_DIR" 2>/dev/null

    # Try each URL in order
    local urls
    urls=$(_schema_github_urls "$version" "$db_type")
    while IFS= read -r url; do
        print_info "Downloading schema from: $url" >&2
        if curl -sSL --fail "$url" -o "$cache_file" 2>/dev/null; then
            if [ -s "$cache_file" ]; then
                print_info "Schema cached to: $cache_file" >&2
                echo "$cache_file"
                return 0
            fi
        fi
        rm -f "$cache_file"
    done <<< "$urls"

    print_error "Failed to download schema for Nacos $version ($db_type)" >&2
    print_info "Check that version tag '$version' exists at https://github.com/alibaba/nacos" >&2
    return 1
}
