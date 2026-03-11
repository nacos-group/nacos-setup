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

# Nacos Setup - Unified Installation Script
# Supports both standalone and cluster modes
# Version: 0.0.1

# ============================================================================
# Script Initialization
# ============================================================================

NACOS_SETUP_VERSION="0.0.1"

set -e  # Exit on error (will be disabled after initial checks)

# Get the real path of the script (resolve symlinks)
if [ -L "${BASH_SOURCE[0]}" ]; then
    # It's a symlink, resolve it
    REAL_SCRIPT=$(readlink "${BASH_SOURCE[0]}")
    if [[ "$REAL_SCRIPT" != /* ]]; then
        # Relative path, resolve it
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd "$(dirname "$REAL_SCRIPT")" && pwd)"
    else
        # Absolute path
        SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
    fi
else
    # Not a symlink
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Determine lib directory location
# When installed globally: /usr/local/nacos-setup/bin/nacos-setup
#   -> lib is at /usr/local/nacos-setup/lib
# When running from source: /path/to/nacos-setup/nacos-setup.sh
#   -> lib is at /path/to/nacos-setup/lib
if [ -d "$SCRIPT_DIR/lib" ]; then
    # Running from source directory
    LIB_DIR="$SCRIPT_DIR/lib"
elif [ -d "$SCRIPT_DIR/../lib" ]; then
    # Running from installed bin directory
    LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
else
    echo "ERROR: Cannot find lib directory"
    echo "Checked locations:"
    echo "  - $SCRIPT_DIR/lib"
    echo "  - $SCRIPT_DIR/../lib"
    exit 1
fi

# Load common library
if [ ! -f "$LIB_DIR/common.sh" ]; then
    echo "ERROR: Required library not found: $LIB_DIR/common.sh"
    exit 1
fi
source "$LIB_DIR/common.sh"

# ============================================================================
# Default Configuration
# ============================================================================

# Load version management library
if [ -f "$LIB_DIR/versions.sh" ]; then
    source "$LIB_DIR/versions.sh"
fi

# Flag to track if user specified version via -v
USER_SPECIFIED_VERSION=false

# Initialize version on startup (only if user didn't specify -v)
init_version() {
    # If user specified version via -v, skip fetching
    if [ "$USER_SPECIFIED_VERSION" = true ]; then
        return 0
    fi

    # Try to fetch latest version from remote
    local fetched_version=$(get_version server 1)
    if [ -n "$fetched_version" ]; then
        DEFAULT_VERSION="$fetched_version"
        VERSION="$fetched_version"
    fi
}

# ============================================================================
# Default Configuration
# ============================================================================

# Get fallback version from versions.sh if available, otherwise use hardcoded
if command -v get_version >/dev/null 2>&1; then
    DEFAULT_VERSION=$(get_version server 0)
else
    DEFAULT_VERSION="3.2.0-BETA"
fi
DEFAULT_INSTALL_DIR="$HOME/ai-infra/nacos"
DEFAULT_MODE="standalone"
DEFAULT_PORT="8848"
DEFAULT_REPLICA_COUNT=3
MINIMUM_NACOS_VERSION="2.4.0"

# ============================================================================
# Global Variables
# ============================================================================

# Operation mode
MODE="$DEFAULT_MODE"  # standalone or cluster

# Common parameters
VERSION="$DEFAULT_VERSION"
AUTO_START=true
ADVANCED_MODE=false
DETACH_MODE=false

# Standalone parameters
INSTALL_DIR=""
PORT="$DEFAULT_PORT"
ALLOW_KILL=false  # Allow killing existing processes (formerly -kill flag)

# Cluster parameters
CLUSTER_ID=""
REPLICA_COUNT="$DEFAULT_REPLICA_COUNT"
CLUSTER_BASE_DIR="$DEFAULT_INSTALL_DIR/cluster"
BASE_PORT="$DEFAULT_PORT"
CLEAN_MODE=false
JOIN_MODE=false
LEAVE_MODE=false
NODE_INDEX=""

# Datasource configuration mode
DATASOURCE_CONF_MODE=false

# ============================================================================
# Usage Information
# ============================================================================

print_usage() {
    cat << 'EOF'
Nacos Setup - Unified Installation Script

USAGE:
    bash nacos-setup.sh [OPTIONS]

MODES:
    Standalone Mode (default):
        Install and run a single Nacos instance
        
    Cluster Mode:
        Install and manage Nacos cluster with multiple nodes
        Triggered by: -c/--cluster option

COMMON OPTIONS:
    -v, --version VERSION          Nacos version (default: 3.1.1, min: 2.4.0)
    -p, --port PORT                Server port (default: 8848)
    --no-start                     Do not start after installation
    --adv                          Advanced mode (interactive prompts)
    --detach                       Detach mode (exit after start)
    --datasource-conf              Configure global datasource
    -h, --help                     Show this help message

STANDALONE MODE OPTIONS:
    -d, --dir DIRECTORY            Installation directory
                                   (default: ~/ai-infra/nacos/standalone/nacos-VERSION)
    --kill                         Allow stopping existing Nacos on port conflict

CLUSTER MODE OPTIONS:
    -c, --cluster CLUSTER_ID       Cluster identifier (enables cluster mode)
    -n, --nodes COUNT              Number of cluster nodes (default: 3)
    --clean                        Clean existing cluster before creation
    --join                         Add new node to existing cluster
    --leave INDEX                  Remove node at INDEX from cluster

EXAMPLES:

  Standalone Mode:
    # Install default version (3.1.1)
    bash nacos-setup.sh
    
    # Install specific version
    bash nacos-setup.sh -v 2.5.2
    
    # Custom port and directory
    bash nacos-setup.sh -p 18848 -d /opt/nacos
    
    # Kill existing Nacos on conflict
    bash nacos-setup.sh --kill

  Cluster Mode:
    # Create 3-node cluster named 'prod'
    bash nacos-setup.sh -c prod
    bash nacos-setup.sh --cluster prod -n 3
    
    # Create 5-node cluster with version 2.5.2
    bash nacos-setup.sh -c prod -n 5 -v 2.5.2
    
    # Add new node to existing cluster
    bash nacos-setup.sh -c prod --join
    
    # Remove node 2 from cluster
    bash nacos-setup.sh -c prod --leave 2
    
    # Clean and recreate cluster
    bash nacos-setup.sh -c prod -n 3 --clean

  Configuration:
    # Configure global database settings
    bash nacos-setup.sh --datasource-conf

VERSION REQUIREMENTS:
    - Minimum supported: Nacos 2.4.0
    - Nacos 3.x requires Java 17+
    - Nacos 2.4.x - 2.5.x requires Java 8+

For more details, visit: https://nacos.io
EOF
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_arguments() {
    # First pass: detect flags that don't take values
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --adv|--detach|--clean|--join|--no-start|--kill|--datasource-conf)
                case "$arg" in
                    --adv) ADVANCED_MODE=true ;;
                    --detach) DETACH_MODE=true ;;
                    --clean) CLEAN_MODE=true ;;
                    --join) JOIN_MODE=true ;;
                    --no-start) AUTO_START=false ;;
                    --kill) ALLOW_KILL=true ;;
                    --datasource-conf) DATASOURCE_CONF_MODE=true ;;
                esac
                ;;
            *)
                args+=("$arg")
                ;;
        esac
    done
    
    # Second pass: parse options with values
    set -- "${args[@]}"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    print_error "Option -v/--version requires a version number"
                    echo ""
                    print_info "Usage: bash nacos-setup.sh -v <version> [OPTIONS]"
                    exit 1
                fi
                VERSION="$2"
                USER_SPECIFIED_VERSION=true
                shift 2
                ;;
            -p|--port)
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    print_error "Option -p/--port requires a port number"
                    echo ""
                    print_info "Usage: bash nacos-setup.sh -p <port> [OPTIONS]"
                    exit 1
                fi
                PORT="$2"
                BASE_PORT="$2"  # For cluster mode
                shift 2
                ;;
            -d|--dir)
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    print_error "Option -d/--dir requires a directory path"
                    echo ""
                    print_info "Usage: bash nacos-setup.sh -d <directory> [OPTIONS]"
                    exit 1
                fi
                INSTALL_DIR="$2"
                shift 2
                ;;
            -c|--cluster)
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    print_error "Option -c/--cluster requires a cluster ID"
                    echo ""
                    print_info "Usage: bash nacos-setup.sh -c <cluster-id> [OPTIONS]"
                    exit 1
                fi
                MODE="cluster"
                CLUSTER_ID="$2"
                shift 2
                ;;
            -n|--nodes)
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    print_error "Option -n/--nodes requires a node count"
                    echo ""
                    print_info "Usage: bash nacos-setup.sh -n <count> [OPTIONS]"
                    exit 1
                fi
                REPLICA_COUNT="$2"
                shift 2
                ;;
            --leave)
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    print_error "Option --leave requires a node index"
                    echo ""
                    print_info "Usage: bash nacos-setup.sh --leave <index> [OPTIONS]"
                    exit 1
                fi
                LEAVE_MODE=true
                NODE_INDEX="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo ""
                print_usage
                exit 1
                ;;
        esac
    done
    
    # Auto-detect cluster mode if CLUSTER_ID is set
    if [ -n "$CLUSTER_ID" ]; then
        MODE="cluster"
    fi
}

# ============================================================================
# Validation
# ============================================================================

validate_arguments() {
    # Validate version
    if ! version_ge "$VERSION" "$MINIMUM_NACOS_VERSION"; then
        print_error "Nacos version $VERSION is not supported"
        print_warn "Minimum required version: $MINIMUM_NACOS_VERSION"
        echo ""
        print_info "Supported versions: 2.4.0+, 2.5.x, 3.x.x"
        exit 1
    fi
    
    # Cluster mode specific validation
    if [ "$MODE" = "cluster" ]; then
        if [ -z "$CLUSTER_ID" ] && [ "$LEAVE_MODE" = false ]; then
            print_error "Cluster ID is required for cluster mode"
            echo ""
            print_info "Usage: bash nacos-setup.sh -c <cluster-id> [OPTIONS]"
            exit 1
        fi
        
        if [ "$LEAVE_MODE" = true ] && [ -z "$NODE_INDEX" ]; then
            print_error "Node index is required for --leave operation"
            echo ""
            print_info "Usage: bash nacos-setup.sh -c <cluster-id> --leave <index>"
            exit 1
        fi
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    # Parse command line arguments first
    parse_arguments "$@"

    # Initialize version (fetch from remote only if user didn't specify -v)
    init_version
    echo ""

    # Handle datasource configuration mode (special mode)
    if [ "$DATASOURCE_CONF_MODE" = true ]; then
        # This will be implemented in a separate module
        print_info "Datasource configuration mode"
        print_warn "This feature will be available after full migration"
        print_info "For now, please use: bash install.sh --datasource-conf"
        exit 0
    fi

    # Validate arguments
    validate_arguments
    
    # Check system requirements
    if ! check_system_commands; then
        exit 1
    fi
    
    # Disable set -e for mode execution (they handle errors internally)
    set +e
    
    # Route to appropriate mode
    case "$MODE" in
        standalone)
            # Load standalone mode implementation
            if [ ! -f "$LIB_DIR/standalone.sh" ]; then
                print_error "Standalone mode implementation not found: $LIB_DIR/standalone.sh"
                exit 1
            fi
            
            source "$LIB_DIR/standalone.sh"
            run_standalone_mode
            ;;
            
        cluster)
            # Load cluster mode implementation
            if [ ! -f "$LIB_DIR/cluster.sh" ]; then
                print_error "Cluster mode implementation not found: $LIB_DIR/cluster.sh"
                exit 1
            fi
            
            source "$LIB_DIR/cluster.sh"
            run_cluster_mode
            ;;
            
        *)
            print_error "Unknown mode: $MODE"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
