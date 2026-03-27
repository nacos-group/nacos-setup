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

# Java Environment Management Library
# Handles Java detection, version checking, and JAVA_HOME configuration

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ============================================================================
# Java Search and Detection
# ============================================================================

# Search for Java installation that meets requirement
# Parameters: required_version, advanced_mode
# Returns: path to java executable or empty on failure
search_java_installation() {
    local required_version=${1:-8}
    local advanced_mode=${2:-false}
    local os_type=$(detect_os_arch)
    
    print_info "Searching for Java installation (OS: $os_type, required: Java ${required_version}+)..." >&2
    
    # Get search paths into array
    local java_search_paths=()
    while IFS= read -r path; do
        java_search_paths+=("$path")
    done < <(get_java_search_paths "$os_type")
    
    local -a suitable_javas=()
    local -a suitable_versions=()
    
    # Search for Java executable in common directories
    for base_path in "${java_search_paths[@]}"; do
        if [ -d "$base_path" ]; then
            while IFS= read -r found_java; do
                if [ -n "$found_java" ] && [ -x "$found_java" ]; then
                    local java_ver=$(get_java_version "$found_java")
                    
                    # If meets requirement, add to list
                    if [ "$java_ver" -ge "$required_version" ]; then
                        suitable_javas+=("$found_java")
                        suitable_versions+=("$java_ver")
                    fi
                fi
            done < <(find "$base_path" -name java -type f 2>/dev/null | grep -E '(bin/java|Commands/java)' | grep -v 'jre/bin/java')
        fi
    done
    
    # If no suitable Java found
    if [ ${#suitable_javas[@]} -eq 0 ]; then
        return 1
    fi
    
    # If only one suitable Java found
    if [ ${#suitable_javas[@]} -eq 1 ]; then
        print_info "Found suitable Java: ${suitable_javas[0]} (version: ${suitable_versions[0]})" >&2
        echo "${suitable_javas[0]}"
        return 0
    fi
    
    # Multiple suitable Java versions found
    echo "" >&2
    print_info "Found multiple suitable Java installations:" >&2
    echo "" >&2
    
    for i in "${!suitable_javas[@]}"; do
        echo "  [$((i+1))] Java ${suitable_versions[$i]} - ${suitable_javas[$i]}" >&2
    done
    
    echo "" >&2
    
    # If not in advanced mode, auto-select the highest version
    if [ "$advanced_mode" = false ]; then
        local max_idx=0
        local max_ver=${suitable_versions[0]}
        for i in "${!suitable_versions[@]}"; do
            if [ "${suitable_versions[$i]}" -gt "$max_ver" ]; then
                max_ver=${suitable_versions[$i]}
                max_idx=$i
            fi
        done
        print_info "Auto-selecting highest version: Java $max_ver" >&2
        echo "${suitable_javas[$max_idx]}"
        return 0
    fi
    
    # Interactive selection
    while true; do
        read -p "Select Java version [1-${#suitable_javas[@]}] (or press Enter for highest version): " selection >&2
        
        # If empty, select highest version
        if [ -z "$selection" ]; then
            local max_idx=0
            local max_ver=${suitable_versions[0]}
            for i in "${!suitable_versions[@]}"; do
                if [ "${suitable_versions[$i]}" -gt "$max_ver" ]; then
                    max_ver=${suitable_versions[$i]}
                    max_idx=$i
                fi
            done
            print_info "Selected: Java $max_ver - ${suitable_javas[$max_idx]}" >&2
            echo "${suitable_javas[$max_idx]}"
            return 0
        fi
        
        # Validate input
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#suitable_javas[@]} ]; then
            local idx=$((selection-1))
            print_info "Selected: Java ${suitable_versions[$idx]} - ${suitable_javas[$idx]}" >&2
            echo "${suitable_javas[$idx]}"
            return 0
        else
            echo "Invalid selection. Please enter a number between 1 and ${#suitable_javas[@]}." >&2
        fi
    done
}

# ============================================================================
# Java Environment Setup
# ============================================================================

# Resolve JAVA_HOME from a java command path.
# Parameters: java_cmd
# Returns: resolved JAVA_HOME path or empty
resolve_java_home_from_cmd() {
    local java_cmd=$1
    local java_path=""

    if [ -z "$java_cmd" ]; then
        return 1
    fi

    if [[ "$java_cmd" = /* ]]; then
        java_path="$java_cmd"
    else
        java_path=$(command -v "$java_cmd" 2>/dev/null || true)
    fi

    if [ -z "$java_path" ]; then
        return 1
    fi

    # Check for macOS Java stub - it doesn't have a real JAVA_HOME
    if is_macos_java_stub "$java_path"; then
        return 1
    fi

    # Resolve symlink chain for a stable JAVA_HOME
    if command -v readlink >/dev/null 2>&1; then
        local resolved_f=""
        resolved_f=$(readlink -f "$java_path" 2>/dev/null || true)
        if [ -n "$resolved_f" ] && [ -x "$resolved_f" ]; then
            java_path="$resolved_f"
        else
            local link="$java_path"
            local i=0
            while [ $i -lt 10 ]; do
                local next
                next=$(readlink "$link" 2>/dev/null || true)
                [ -n "$next" ] || break
                if [[ "$next" = /* ]]; then
                    link="$next"
                else
                    link="$(cd "$(dirname "$link")" && cd "$(dirname "$next")" && pwd)/$(basename "$next")"
                fi
                i=$((i + 1))
            done
            if [ -x "$link" ]; then
                java_path="$link"
            fi
        fi
    fi

    local java_home
    java_home="$(dirname "$(dirname "$java_path")")"
    [ -d "$java_home" ] || return 1
    printf '%s\n' "$java_home"
}

# Check and setup Java environment
# Parameters: nacos_version, advanced_mode
# Returns: 0 on success, 1 on failure
# Sets: JAVA_HOME, JAVA_CMD, JAVA_VERSION
check_java_requirements() {
    local nacos_version=$1
    local advanced_mode=${2:-false}
    
    # Determine required Java version based on Nacos version
    local required_java_version=8
    if [ -n "$nacos_version" ]; then
        local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
        if [ "$nacos_major" -ge 3 ]; then
            required_java_version=17
            print_info "Nacos $nacos_version requires Java 17 or later"
        fi
    fi
    
    # Check Java
    JAVA_CMD=""
    JAVA_VERSION=0
    
    # Try JAVA_HOME first
    if [ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        JAVA_CMD="$JAVA_HOME/bin/java"
        JAVA_VERSION=$(get_java_version "$JAVA_CMD")
        print_info "Found Java from JAVA_HOME: $JAVA_HOME (version: $JAVA_VERSION)"
        
        if [ "$JAVA_VERSION" -lt "$required_java_version" ]; then
            print_warn "Java $JAVA_VERSION in JAVA_HOME is below required version $required_java_version"
            print_info "Searching for a suitable Java version..."
            JAVA_CMD=""
        fi
    # Try PATH
    elif command -v java &> /dev/null; then
        JAVA_CMD="java"
        JAVA_VERSION=$(get_java_version "$JAVA_CMD")
        print_info "Found Java in PATH (version: $JAVA_VERSION)"
        
        if [ "$JAVA_VERSION" -lt "$required_java_version" ]; then
            print_warn "Java $JAVA_VERSION in PATH is below required version $required_java_version"
            print_info "Searching for a suitable Java version..."
            JAVA_CMD=""
        fi
    fi

    # Ensure JAVA_HOME always matches selected JAVA_CMD (including PATH-discovered java).
    if [ -n "$JAVA_CMD" ]; then
        local resolved_java_home
        resolved_java_home=$(resolve_java_home_from_cmd "$JAVA_CMD" || true)
        if [ -n "$resolved_java_home" ] && [ -x "$resolved_java_home/bin/java" ]; then
            export JAVA_HOME="$resolved_java_home"
        fi
    fi
    
    # If no suitable Java found, search system
    if [ -z "$JAVA_CMD" ]; then
        print_warn "Java command not found or version too old"
        JAVA_CMD=$(search_java_installation "$required_java_version" "$advanced_mode")
        
        if [ -z "$JAVA_CMD" ]; then
            # Fallback: try to find any Java >= 8
            print_warn "No Java $required_java_version+ found, trying to find Java 8+..."
            JAVA_CMD=$(search_java_installation 8 "$advanced_mode")
            
            if [ -z "$JAVA_CMD" ]; then
                # No Java found at all
                print_error "Java not found. Please install Java $required_java_version or later"
                echo ""
                print_info "Install Java using:"
                print_info "  Ubuntu/Debian: sudo apt-get install openjdk-17-jdk"
                print_info "  CentOS/RHEL:   sudo yum install java-17-openjdk-devel"
                print_info "  macOS:         brew install openjdk@17"
                return 1
            else
                # Found Java 8+ but below required version
                JAVA_VERSION=$(get_java_version "$JAVA_CMD")
                export JAVA_HOME="$(dirname $(dirname $JAVA_CMD))"
                print_warn "Found Java $JAVA_VERSION, but Nacos $nacos_version may require Java $required_java_version+"
                print_warn "Installation will continue, but Nacos may fail to start"
            fi
        else
            # Found suitable Java
            JAVA_VERSION=$(get_java_version "$JAVA_CMD")
            export JAVA_HOME="$(dirname $(dirname $JAVA_CMD))"
            print_info "Found suitable Java: $JAVA_CMD (version: $JAVA_VERSION)"
            print_info "Set JAVA_HOME to: $JAVA_HOME"
        fi
    fi
    
    # Final version check
    if [ "$JAVA_VERSION" -lt 8 ]; then
        print_error "Java version must be 8 or later (found: $JAVA_VERSION)"
        return 1
    fi
    
    print_info "Java version: $JAVA_VERSION - OK"
    return 0
}

# ============================================================================
# Java Runtime Options
# ============================================================================

# Get JVM options for Nacos startup (JDK 9+ module access)
# Returns: JVM options string or empty
get_java_runtime_options() {
    local java_cmd="${JAVA_HOME:-/usr}/bin/java"
    
    if [ ! -x "$java_cmd" ]; then
        java_cmd=$(which java 2>/dev/null || echo "java")
    fi
    
    # Check for macOS Java stub
    if is_macos_java_stub "$java_cmd"; then
        echo ""
        return
    fi
    
    local java_version
    # Use timeout to prevent hanging
    if command -v timeout >/dev/null 2>&1; then
        java_version=$(timeout 5 "$java_cmd" -version 2>&1 | head -1)
    elif command -v gtimeout >/dev/null 2>&1; then
        java_version=$(gtimeout 5 "$java_cmd" -version 2>&1 | head -1)
    else
        java_version=$("$java_cmd" -version 2>&1 | head -1)
    fi
    
    local java_major_version=$(echo "$java_version" | sed -E -n 's/.* version "([0-9]+).*/\1/p')
    
    # For JDK 9+, add module access parameters
    if [ -n "$java_major_version" ] && [ "$java_major_version" -ge 9 ]; then
        echo "--add-opens java.base/java.io=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.util.concurrent=ALL-UNNAMED --add-opens java.base/sun.net.util=ALL-UNNAMED"
    else
        echo ""
    fi
}
