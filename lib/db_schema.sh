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
