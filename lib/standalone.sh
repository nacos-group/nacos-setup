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
if [ -f "$SCRIPT_DIR/data_import.sh" ]; then
    # shellcheck source=data_import.sh
    source "$SCRIPT_DIR/data_import.sh"
fi
if [ -f "$SCRIPT_DIR/skill_scanner_install.sh" ]; then
    # shellcheck source=skill_scanner_install.sh
    source "$SCRIPT_DIR/skill_scanner_install.sh"
fi

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
    
    # Skip cleanup in daemon mode
    if [ "$DAEMON_MODE" = true ]; then
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
    local TOTAL_STEPS=7
    
    if [ "$VERBOSE" = true ]; then
        print_info "Nacos Standalone Installation"
        print_info "===================================="
        echo ""
    else
        echo ""
        echo "Nacos Standalone Setup (v${NACOS_SETUP_VERSION:-dev})"
        echo "======================================"
        echo ""
    fi
    
    # Set trap for cleanup
    trap cleanup_on_exit EXIT INT TERM
    
    # Set installation directory (append version if using default)
    if [ -z "$INSTALL_DIR" ] || [ "$INSTALL_DIR" = "$DEFAULT_INSTALL_DIR" ]; then
        INSTALL_DIR="$DEFAULT_INSTALL_DIR/standalone/nacos-$VERSION"
    fi
    
    print_detail "Target Nacos version: $VERSION"
    print_detail "Installation directory: $INSTALL_DIR"
    if [ "$VERBOSE" = true ]; then echo ""; fi
    
    # [1/7] Check Java requirements
    if ! check_java_requirements "$VERSION" "$ADVANCED_MODE"; then
        print_step_fail 1 $TOTAL_STEPS "Checking Java environment"
        exit 1
    fi
    print_step 1 $TOTAL_STEPS "Checking Java environment" "Java ${JAVA_VERSION}"
    
    # [2/7] Download Nacos
    local zip_file=$(download_nacos "$VERSION")
    if [ -z "$zip_file" ]; then
        print_step_fail 2 $TOTAL_STEPS "Downloading Nacos $VERSION"
        exit 1
    fi
    print_step 2 $TOTAL_STEPS "Downloading Nacos $VERSION"
    
    # [3/7] Extract and install
    local extracted_dir=$(extract_nacos_to_temp "$zip_file")
    if [ -z "$extracted_dir" ]; then
        print_step_fail 3 $TOTAL_STEPS "Installing"
        exit 1
    fi
    if ! install_nacos "$extracted_dir" "$INSTALL_DIR"; then
        print_step_fail 3 $TOTAL_STEPS "Installing"
        rm -rf "$(dirname "$extracted_dir")"
        exit 1
    fi
    cleanup_temp_dir "$(dirname "$extracted_dir")"
    print_step 3 $TOTAL_STEPS "Installing" "$INSTALL_DIR"
    
    # [4/7] Configure Nacos (ports + security + datasource)
    print_detail "Configuring Nacos..."
    local config_file="$INSTALL_DIR/conf/application.properties"
    
    local port_result=$(allocate_standalone_ports "$PORT" "$VERSION" "$ADVANCED_MODE" "$ALLOW_KILL")
    if [ -z "$port_result" ]; then
        print_step_fail 4 $TOTAL_STEPS "Configuring"
        exit 1
    fi
    read SERVER_PORT CONSOLE_PORT <<< "$port_result"
    
    update_port_config "$config_file" "$SERVER_PORT" "$CONSOLE_PORT" "$VERSION"
    print_detail "Ports configured: Server=$SERVER_PORT, Console=$CONSOLE_PORT"
    
    configure_standalone_security "$config_file" "$ADVANCED_MODE"
    
    if [ "${USE_EXTERNAL_DATASOURCE:-false}" = "true" ]; then
        local datasource_file=$(load_default_datasource_config)
        if [ -n "$datasource_file" ]; then
            print_detail "Applying external datasource configuration..."
            apply_datasource_config "$config_file" "$datasource_file"
            print_detail "External database configured"
        else
            print_step_fail 4 $TOTAL_STEPS "Configuring"
            print_error "External datasource specified but configuration not found at: $DEFAULT_DATASOURCE_CONFIG"
            print_info "To create the configuration, run:"
            print_info "  nacos-setup db-conf edit $DEFAULT_DATASOURCE_CONFIG"
            exit 1
        fi
    else
        print_detail "Using embedded Derby database"
    fi
    rm -f "$config_file.bak"
    print_step 4 $TOTAL_STEPS "Configuring" "port=${SERVER_PORT} console=${CONSOLE_PORT}"
    
    # [5/7] Import default data
    print_detail "Post-config: importing default agentspec / skill data into ${INSTALL_DIR}/data..."
    if declare -F run_post_nacos_config_data_import_hook >/dev/null 2>&1; then
        run_post_nacos_config_data_import_hook "$INSTALL_DIR"
    else
        print_detail "Default data import hook not available, skipping"
    fi
    print_step 5 $TOTAL_STEPS "Importing default data"
    
    # [6/7] Skill scanner
    print_detail "Post-config: optional Cisco skill-scanner step (Nacos ${VERSION})..."
    if declare -F run_post_nacos_config_skill_scanner_hook >/dev/null 2>&1; then
        run_post_nacos_config_skill_scanner_hook
        if [ "$SKILL_SCANNER_INSTALLED" = "true" ] && declare -F configure_skill_scanner_properties >/dev/null 2>&1; then
            configure_skill_scanner_properties "$config_file"
        fi
    fi
    print_step 6 $TOTAL_STEPS "Setting up skill-scanner"
    
    # [7/7] Start Nacos
    if [ "$AUTO_START" = true ]; then
        local start_time=$(date +%s)
        
        print_detail "Starting Nacos in standalone mode..."
        local pid=$(start_nacos_process "$INSTALL_DIR" "standalone" "false")
        if [ -z "$pid" ]; then
            print_warn "Could not determine Nacos PID"
        else
            STARTED_NACOS_PID=$pid
            print_detail "Nacos started with PID: $STARTED_NACOS_PID"
        fi
        
        if wait_for_nacos_ready "$SERVER_PORT" "$CONSOLE_PORT" "$VERSION"; then
            local end_time=$(date +%s)
            local elapsed=$((end_time - start_time))
            print_step 7 $TOTAL_STEPS "Starting Nacos" "ready in ${elapsed}s (PID: ${STARTED_NACOS_PID:-?})"
            
            if [ -n "$NACOS_PASSWORD" ] && [ "$NACOS_PASSWORD" != "nacos" ]; then
                if initialize_admin_password "$SERVER_PORT" "$CONSOLE_PORT" "$VERSION" "$NACOS_PASSWORD"; then
                    print_detail "Admin password initialized successfully"
                else
                    print_warn "Password initialization failed (may already be set previously)"
                    NACOS_PASSWORD=""
                fi
            fi
        else
            print_step 7 $TOTAL_STEPS "Starting Nacos" "may still be starting"
        fi
        
        # Print completion info
        local nacos_major=$(echo "$VERSION" | cut -d. -f1)
        local console_url
        if [ "$nacos_major" -ge 3 ]; then
            console_url="http://localhost:${CONSOLE_PORT}"
        else
            console_url="http://localhost:${SERVER_PORT}/nacos"
        fi
        
        print_completion_info "$INSTALL_DIR" "$console_url" "$SERVER_PORT" "$CONSOLE_PORT" "$VERSION" "nacos" "$NACOS_PASSWORD"
        
        # Handle daemon or monitoring mode
        if [ "$DAEMON_MODE" = true ]; then
            echo ""
            print_info "Daemon mode: Nacos running with PID: $STARTED_NACOS_PID"
            print_info "To stop: kill $STARTED_NACOS_PID"
            echo ""
            trap - EXIT INT TERM
            exit 0
        else
            echo ""
            print_info "Press Ctrl+C to stop Nacos (PID: $STARTED_NACOS_PID)"
            echo ""
            
            if [ -n "$STARTED_NACOS_PID" ]; then
                while ps -p $STARTED_NACOS_PID >/dev/null 2>&1; do
                    sleep 5
                done
                print_warn "Nacos process terminated unexpectedly"
                STARTED_NACOS_PID=""
            fi
        fi
    else
        print_step 7 $TOTAL_STEPS "Starting Nacos" "skipped (--no-start)"
        echo ""
        print_info "To start manually:"
        print_info "  cd $INSTALL_DIR && bash bin/startup.sh -m standalone"
        echo ""
    fi
}
