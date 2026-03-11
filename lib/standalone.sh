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

# Standalone Mode Implementation
# Main logic for single Nacos instance installation

# Load dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/port_manager.sh"
source "$SCRIPT_DIR/download.sh"
source "$SCRIPT_DIR/config_manager.sh"
source "$SCRIPT_DIR/java_manager.sh"
source "$SCRIPT_DIR/process_manager.sh"

# ============================================================================
# Global Variables for Standalone Mode
# ============================================================================

STARTED_NACOS_PID=""
CLEANUP_DONE=false

# Security configuration (set by configure_standalone_security)
TOKEN_SECRET=""
IDENTITY_KEY=""
IDENTITY_VALUE=""
NACOS_PASSWORD=""

# ============================================================================
# Cleanup Handler
# ============================================================================

cleanup_on_exit() {
    local exit_code=$?
    
    # Prevent duplicate cleanup
    if [ "$CLEANUP_DONE" = true ]; then
        return 0
    fi
    CLEANUP_DONE=true
    
    # Skip cleanup in detach mode
    if [ "$DETACH_MODE" = true ]; then
        exit $exit_code
    fi
    
    # Stop Nacos if running
    if [ -n "$STARTED_NACOS_PID" ] && ps -p $STARTED_NACOS_PID >/dev/null 2>&1; then
        echo ""
        print_info "Cleaning up: Stopping Nacos (PID: $STARTED_NACOS_PID)..."
        
        if stop_nacos_gracefully $STARTED_NACOS_PID; then
            print_info "Nacos stopped successfully"
        else
            print_warn "Failed to stop Nacos gracefully"
        fi
        
        echo ""
        print_info "Tip: Use --daemon flag to run Nacos in background without auto-cleanup"
    fi
    
    exit $exit_code
}

# ============================================================================
# Main Standalone Installation
# ============================================================================

run_standalone_mode() {
    print_info "Nacos Standalone Installation"
    print_info "===================================="
    echo ""
    
    # Set trap for cleanup
    trap cleanup_on_exit EXIT INT TERM
    
    # Set installation directory (append version if using default)
    if [ -z "$INSTALL_DIR" ] || [ "$INSTALL_DIR" = "$DEFAULT_INSTALL_DIR" ]; then
        INSTALL_DIR="$DEFAULT_INSTALL_DIR/standalone/nacos-$VERSION"
    fi
    
    print_info "Target Nacos version: $VERSION"
    print_info "Installation directory: $INSTALL_DIR"
    echo ""
    
    # Check Java requirements
    if ! check_java_requirements "$VERSION" "$ADVANCED_MODE"; then
        exit 1
    fi
    echo ""
    
    # Download Nacos
    local zip_file=$(download_nacos "$VERSION")
    if [ -z "$zip_file" ]; then
        print_error "Failed to download Nacos"
        exit 1
    fi
    echo ""
    
    # Extract to temp directory
    local extracted_dir=$(extract_nacos_to_temp "$zip_file")
    if [ -z "$extracted_dir" ]; then
        print_error "Failed to extract Nacos"
        exit 1
    fi
    
    # Install to target directory
    if ! install_nacos "$extracted_dir" "$INSTALL_DIR"; then
        print_error "Failed to install Nacos"
        rm -rf "$(dirname "$extracted_dir")"
        exit 1
    fi
    
    # Cleanup temp directory
    cleanup_temp_dir "$(dirname "$extracted_dir")"
    echo ""
    
    # Configure Nacos
    print_info "Configuring Nacos..."
    local config_file="$INSTALL_DIR/conf/application.properties"
    
    # Allocate ports
    local port_result=$(allocate_standalone_ports "$PORT" "$VERSION" "$ADVANCED_MODE" "$ALLOW_KILL")
    if [ -z "$port_result" ]; then
        print_error "Failed to allocate ports"
        exit 1
    fi
    
    read SERVER_PORT CONSOLE_PORT <<< "$port_result"
    echo ""
    
    # Update port configuration
    update_port_config "$config_file" "$SERVER_PORT" "$CONSOLE_PORT" "$VERSION"
    print_info "Ports configured: Server=$SERVER_PORT, Console=$CONSOLE_PORT"
    
    # Configure security
    configure_standalone_security "$config_file" "$ADVANCED_MODE"
    
    # Load and apply datasource configuration only if explicitly specified via -db-conf
    if [ "${USE_EXTERNAL_DATASOURCE:-false}" = "true" ]; then
        local datasource_file=$(load_default_datasource_config)
        if [ -n "$datasource_file" ]; then
            print_info "Applying external datasource configuration..."
            apply_datasource_config "$config_file" "$datasource_file"
            print_info "External database configured"
        else
            print_error "External datasource specified but configuration not found at: $DEFAULT_DATASOURCE_CONFIG"
            echo ""
            print_info "To create the configuration, run:"
            print_info "  nacos-setup db-conf edit $DEFAULT_DATASOURCE_CONFIG"
            exit 1
        fi
    else
        print_info "Using embedded Derby database"
        print_info "Tip: Run 'nacos-setup -db-conf' to use external datasource"
    fi
    
    rm -f "$config_file.bak"
    print_info "Configuration completed"
    echo ""
    
    # Start Nacos if auto-start is enabled
    if [ "$AUTO_START" = true ]; then
        print_info "Starting Nacos in standalone mode..."
        echo ""
        
        # Record start time
        local start_time=$(date +%s)
        
        local pid=$(start_nacos_process "$INSTALL_DIR" "standalone" "false")
        if [ -z "$pid" ]; then
            print_warn "Could not determine Nacos PID"
        else
            STARTED_NACOS_PID=$pid
            print_info "Nacos started with PID: $STARTED_NACOS_PID"
        fi
        echo ""
        
        # Wait for readiness and initialize password
        if wait_for_nacos_ready "$SERVER_PORT" "$CONSOLE_PORT" "$VERSION"; then
            local end_time=$(date +%s)
            local elapsed=$((end_time - start_time))
            print_info "Nacos is ready in ${elapsed}s!"
            echo ""
            
            if [ -n "$NACOS_PASSWORD" ] && [ "$NACOS_PASSWORD" != "nacos" ]; then
                if ! initialize_admin_password "$SERVER_PORT" "$CONSOLE_PORT" "$VERSION" "$NACOS_PASSWORD"; then
                    print_warn "Password initialization failed, you can change it manually after login"
                fi
            fi
        else
            print_warn "Nacos may still be starting, please wait a moment"
        fi
        
        # Print completion info
        local nacos_major=$(echo "$VERSION" | cut -d. -f1)
        local console_url
        if [ "$nacos_major" -ge 3 ]; then
            console_url="http://localhost:${CONSOLE_PORT}/index.html"
        else
            console_url="http://localhost:${SERVER_PORT}/nacos/index.html"
        fi
        
        print_completion_info "$INSTALL_DIR" "$console_url" "$SERVER_PORT" "$CONSOLE_PORT" "$VERSION" "nacos" "$NACOS_PASSWORD"
        
        # Handle detach or monitoring mode
        if [ "$DETACH_MODE" = true ]; then
            echo ""
            print_info "Detach mode: Script will exit now"
            print_info "Nacos is running with PID: $STARTED_NACOS_PID"
            print_info "To stop Nacos, run: kill $STARTED_NACOS_PID"
            echo ""
            
            # Disable trap for detach mode
            trap - EXIT INT TERM
            exit 0
        else
            echo ""
            print_info "Script will keep running. Press Ctrl+C to stop and cleanup Nacos."
            print_info "Nacos is running with PID: $STARTED_NACOS_PID"
            echo ""
            
            # Monitor process
            if [ -n "$STARTED_NACOS_PID" ]; then
                while ps -p $STARTED_NACOS_PID >/dev/null 2>&1; do
                    sleep 5
                done
                
                print_warn "Nacos process terminated unexpectedly"
                STARTED_NACOS_PID=""
            fi
        fi
    else
        print_info "Installation completed (auto-start disabled)"
        print_info "To start manually, run:"
        print_info "  cd $INSTALL_DIR"
        print_info "  bash bin/startup.sh -m standalone"
        echo ""
    fi
}
