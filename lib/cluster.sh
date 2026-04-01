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

# Cluster Mode Implementation
# Main logic for Nacos cluster management

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
# Global Variables
# ============================================================================

declare -a STARTED_PIDS=()
CLEANUP_CLUSTER_DIR=""
CLEANUP_DONE=false

# Security configuration (shared across cluster)
TOKEN_SECRET=""
IDENTITY_KEY=""
IDENTITY_VALUE=""
NACOS_PASSWORD=""

# ============================================================================
# Cleanup Handler
# ============================================================================

cleanup_on_exit() {
    local exit_code=$?
    step_simple_clear 2>/dev/null || true

    if [ "$CLEANUP_DONE" = true ]; then
        return 0
    fi
    CLEANUP_DONE=true
    
    trap - EXIT INT TERM
    
    # Skip cleanup in daemon mode
    if [ "$DAEMON_MODE" = true ]; then
        exit $exit_code
    fi
    
    # Stop all started processes
    if [ ${#STARTED_PIDS[@]} -gt 0 ]; then
        echo ""
        print_info "Stopping cluster nodes..."
        
        local stopped_count=0
        local -a stopped_pids=()
        
        for pid in "${STARTED_PIDS[@]}"; do
            if is_process_running "$pid"; then
                stop_nacos_gracefully $pid
                stopped_pids+=("$pid")
                stopped_count=$((stopped_count + 1))
            fi
        done
        
        if [ $stopped_count -gt 0 ]; then
            print_info "Stopped $stopped_count node(s): ${stopped_pids[*]}"
        else
            print_info "No running nodes to stop"
        fi
    fi
    
    exit $exit_code
}

# ============================================================================
# Node Startup
# ============================================================================

start_cluster_node() {
    local node_dir=$1
    local node_name=$2
    local main_port=$3
    local console_port=$4
    local nacos_version=$5
    local use_derby=$6
    
    # Record start time
    local start_time=$(date +%s)
    
    # Check port availability
    if ! check_port_available $main_port; then
        print_error "Port $main_port is already in use" >&2
        return 1
    fi
    
    local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
    if [ "$nacos_major" -ge 3 ]; then
        if ! check_port_available $console_port; then
            print_error "Console port $console_port is already in use" >&2
            return 1
        fi
    fi
    
    # Start the node
    local pid=$(start_nacos_process "$node_dir" "cluster" "$use_derby" "$main_port")
    
    if [ -z "$pid" ]; then
        print_error "Failed to start node $node_name" >&2
        return 1
    fi
    
    # Wait for readiness
    if wait_for_nacos_ready "$main_port" "$console_port" "$nacos_version" 60; then
        # Fallback PID recovery if detection raced with process startup
        if [ -z "$pid" ]; then
            pid=$(detect_nacos_pid "$node_dir" "$main_port" || true)
        fi
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        print_detail "Node $node_name ready (PID: $pid, ${elapsed}s)" >&2
        echo "$pid"
        return 0
    else
        print_error "Node $node_name startup timeout" >&2
        if [ -n "$pid" ] && is_process_running "$pid"; then
            stop_nacos_gracefully "$pid" 2 >/dev/null 2>&1 || true
        fi
        return 1
    fi
}

# ============================================================================
# Cluster Creation
# ============================================================================

create_cluster() {
    local TOTAL_STEPS=7
    
    if [ "$VERBOSE" = true ]; then
        print_info "Nacos Cluster Installation"
        print_info "===================================="
        echo ""
    else
        echo ""
        echo "Nacos Cluster Setup (v${NACOS_SETUP_VERSION:-dev})"
        echo "======================================"
        echo ""
    fi
    
    trap cleanup_on_exit EXIT INT TERM
    
    local cluster_dir="$CLUSTER_BASE_DIR/$CLUSTER_ID"
    CLEANUP_CLUSTER_DIR="$cluster_dir"
    
    # Check if cluster exists
    if [ -d "$cluster_dir" ]; then
        local existing_nodes=($(ls -d "$cluster_dir/"[0-9]*"-v"* 2>/dev/null))
        if [ ${#existing_nodes[@]} -gt 0 ]; then
            if [ "$CLEAN_MODE" = true ]; then
                print_warn "Cleaning existing cluster..."
                clean_existing_cluster "$cluster_dir"
            else
                print_error "Cluster '$CLUSTER_ID' already exists"
                print_info "Use --clean flag to recreate"
                exit 1
            fi
        fi
    fi
    
    mkdir -p "$cluster_dir"
    
    print_detail "Cluster ID: $CLUSTER_ID"
    print_detail "Nacos version: $VERSION"
    print_detail "Replica count: $REPLICA_COUNT"
    print_detail "Cluster directory: $cluster_dir"
    if [ "$VERBOSE" = true ]; then echo ""; fi
    
    # [1/7] Check Java
    step_simple_begin 1 $TOTAL_STEPS "Checking Java environment"
    if ! check_java_requirements "$VERSION" "$ADVANCED_MODE"; then
        step_simple_clear
        print_step_fail 1 $TOTAL_STEPS "Checking Java environment"
        exit 1
    fi
    step_simple_clear
    print_step 1 $TOTAL_STEPS "Checking Java environment" "Java ${JAVA_VERSION}"
    
    # [2/7] Download Nacos
    step_simple_begin 2 $TOTAL_STEPS "Downloading Nacos $VERSION"
    local zip_file=$(download_nacos "$VERSION")
    if [ -z "$zip_file" ]; then
        step_simple_clear
        print_step_fail 2 $TOTAL_STEPS "Downloading Nacos $VERSION"
        exit 1
    fi
    step_simple_clear
    print_step 2 $TOTAL_STEPS "Downloading Nacos $VERSION"
    
    # [3/7] Configure security
    step_simple_begin 3 $TOTAL_STEPS "Configuring security & datasource"
    configure_cluster_security "$cluster_dir" "$ADVANCED_MODE"
    
    local use_derby=true
    local datasource_file=""
    if [ "${USE_EXTERNAL_DATASOURCE:-false}" = "true" ]; then
        datasource_file=$(load_default_datasource_config)
        if [ -n "$datasource_file" ]; then
            print_detail "Using external database"
            use_derby=false
        else
            step_simple_clear
            print_step_fail 3 $TOTAL_STEPS "Configuring security & datasource"
            print_error "External datasource config not found: $DEFAULT_DATASOURCE_CONFIG"
            exit 1
        fi
    else
        print_detail "Using embedded Derby database"
    fi
    step_simple_clear
    print_step 3 $TOTAL_STEPS "Configuring security & datasource"
    
    # [4/7] Allocate ports and setup nodes
    step_simple_begin 4 $TOTAL_STEPS "Setting up ${REPLICA_COUNT} nodes"
    print_detail "Allocating ports for $REPLICA_COUNT nodes..."
    local port_result=$(allocate_cluster_ports "$BASE_PORT" "$REPLICA_COUNT" "$VERSION")
    if [ -z "$port_result" ]; then
        step_simple_clear
        print_step_fail 4 $TOTAL_STEPS "Setting up ${REPLICA_COUNT} nodes"
        exit 1
    fi
    
    declare -a node_main_ports=()
    declare -a node_console_ports=()
    for port_pair in $port_result; do
        IFS=':' read -r main_port console_port <<< "$port_pair"
        node_main_ports+=("$main_port")
        node_console_ports+=("$console_port")
    done
    
    local cluster_conf="$cluster_dir/cluster.conf"
    local local_ip=$(get_local_ip)
    print_detail "Local IP: $local_ip"
    
    for ((i=0; i<REPLICA_COUNT; i++)); do
        local node_name="${i}-v${VERSION}"
        local node_dir="$cluster_dir/$node_name"
        
        print_detail "Configuring node $i..."
        
        if ! extract_nacos_to_target "$zip_file" "$cluster_dir" "$node_name"; then
            step_simple_clear
            print_step_fail 4 $TOTAL_STEPS "Setting up ${REPLICA_COUNT} nodes"
            exit 1
        fi
        
        local node_cluster_conf="$node_dir/conf/cluster.conf"
        > "$node_cluster_conf"
        for ((j=0; j<=i; j++)); do
            echo "${local_ip}:${node_main_ports[$j]}" >> "$node_cluster_conf"
        done
        
        local config_file="$node_dir/conf/application.properties"
        if [ ! -f "$config_file" ]; then
            print_error "Config file not found: $config_file"
            exit 1
        fi
        
        cp "$config_file" "$config_file.original"
        update_port_config "$config_file" "${node_main_ports[$i]}" "${node_console_ports[$i]}" "$VERSION"
        apply_security_config "$config_file" "$TOKEN_SECRET" "$IDENTITY_KEY" "$IDENTITY_VALUE"
        
        if [ "${USE_EXTERNAL_DATASOURCE:-false}" = "true" ]; then
            local datasource_file=$(load_default_datasource_config)
            if [ -n "$datasource_file" ]; then
                apply_datasource_config "$config_file" "$datasource_file"
            fi
        elif [ "$use_derby" = true ]; then
            configure_derby_for_cluster "$config_file"
        fi
        rm -f "$config_file.bak"

        print_detail "Importing default data into $node_dir/data..."
        if declare -F run_post_nacos_config_data_import_hook >/dev/null 2>&1; then
            run_post_nacos_config_data_import_hook "$node_dir"
        fi
        
        local main_port="${node_main_ports[$i]}"
        local console_port="${node_console_ports[$i]}"
        local nacos_major=$(echo "$VERSION" | cut -d. -f1)
        
        if [ "$VERBOSE" = true ]; then
            if [ "$nacos_major" -ge 3 ]; then
                print_info "  ✓ Server: $main_port | Console: $console_port | gRPC: $((main_port+1000)),$((main_port+1001)) | Raft: $((main_port-1000))"
            else
                print_info "  ✓ Server: $main_port | gRPC: $((main_port+1000)),$((main_port+1001)) | Raft: $((main_port-1000))"
            fi
        fi
    done
    
    # Create master cluster.conf
    > "$cluster_conf"
    for i in "${!node_main_ports[@]}"; do
        echo "${local_ip}:${node_main_ports[$i]}" >> "$cluster_conf"
    done
    
    if [ "$VERBOSE" = true ]; then
        echo ""
        print_info "Final cluster configuration:"
        cat "$cluster_conf" | while read line; do
            echo "  $line"
        done
        echo ""
    fi
    
    local ports_summary="${node_main_ports[0]}"
    if [ ${#node_main_ports[@]} -gt 1 ]; then
        ports_summary="${node_main_ports[0]}..${node_main_ports[$((${#node_main_ports[@]}-1))]}"
    fi
    step_simple_clear
    print_step 4 $TOTAL_STEPS "Setting up ${REPLICA_COUNT} nodes" "ports ${ports_summary}"
    
    # [5/7] Skill scanner — no spinner (interactive prompts must stay visible)
    step_simple_clear
    if [ "${VERBOSE:-false}" != true ]; then
        echo -e "${GREEN}[5/7]${NC} Setting up skill-scanner"
    fi
    print_detail "Post-config: optional Cisco skill-scanner step (Nacos ${VERSION})..."
    if declare -F run_post_nacos_config_skill_scanner_hook >/dev/null 2>&1; then
        run_post_nacos_config_skill_scanner_hook
        if declare -F configure_skill_scanner_properties >/dev/null 2>&1 && declare -F _skill_scanner_should_write_plugin_config >/dev/null 2>&1; then
            if _skill_scanner_should_write_plugin_config; then
                for ((i=0; i<REPLICA_COUNT; i++)); do
                    local node_name="${i}-v${VERSION}"
                    local node_config_file="$cluster_dir/$node_name/conf/application.properties"
                    if [ -f "$node_config_file" ]; then
                        configure_skill_scanner_properties "$node_config_file"
                    fi
                done
            fi
        fi
    fi
    step_simple_clear
    print_step 5 $TOTAL_STEPS "Setting up skill-scanner"

    # [6/7] Start all nodes
    if [ "$AUTO_START" = true ]; then
        step_simple_begin 6 $TOTAL_STEPS "Starting ${REPLICA_COUNT} cluster nodes"
        for ((i=0; i<REPLICA_COUNT; i++)); do
            local node_name="${i}-v${VERSION}"
            local node_dir="$cluster_dir/$node_name"
            
            local pid=$(start_cluster_node "$node_dir" "$node_name" "${node_main_ports[$i]}" "${node_console_ports[$i]}" "$VERSION" "$use_derby")
            
            if [ -n "$pid" ]; then
                STARTED_PIDS+=("$pid")
                if [ $i -gt 0 ]; then
                    print_detail "Updating cluster.conf in previous nodes to include node $i..."
                    for ((j=0; j<i; j++)); do
                        local prev_node_dir="$cluster_dir/${j}-v${VERSION}"
                        local prev_cluster_conf="$prev_node_dir/conf/cluster.conf"
                        echo "${local_ip}:${node_main_ports[$i]}" >> "$prev_cluster_conf"
                    done
                fi
            else
                step_simple_clear
                print_step_fail 6 $TOTAL_STEPS "Starting cluster nodes"
                exit 1
            fi
        done
        step_simple_clear
        print_step 6 $TOTAL_STEPS "Starting ${REPLICA_COUNT} cluster nodes" "${#STARTED_PIDS[@]} nodes up"
        
        # [7/7] Initialize password
        step_simple_begin 7 $TOTAL_STEPS "Initializing admin password"
        if [ -n "$NACOS_PASSWORD" ] && [ "$NACOS_PASSWORD" != "nacos" ]; then
            if initialize_admin_password "${node_main_ports[0]}" "${node_console_ports[0]}" "$VERSION" "$NACOS_PASSWORD"; then
                step_simple_clear
                print_step 7 $TOTAL_STEPS "Initializing admin password"
            else
                print_warn "Password initialization failed (may already be set previously)"
                NACOS_PASSWORD=""
                step_simple_clear
                print_step 7 $TOTAL_STEPS "Initializing admin password" "skipped"
            fi
        else
            step_simple_clear
            print_step 7 $TOTAL_STEPS "Initializing admin password" "default"
        fi
        
        # Print cluster info
        print_cluster_info "$cluster_dir" "$VERSION" "$REPLICA_COUNT" "${node_main_ports[@]}" "${node_console_ports[@]}"
        
        if [ "$DAEMON_MODE" = true ]; then
            print_info "Daemon mode: Script will exit"
            trap - EXIT INT TERM
            exit 0
        else
            print_info "Press Ctrl+C to stop cluster"
            echo ""
            
            print_detail "Verifying cluster nodes..."
            local -a verified_pids=()
            for idx in "${!STARTED_PIDS[@]}"; do
                local pid="${STARTED_PIDS[$idx]}"
                if is_process_running "$pid"; then
                    verified_pids+=($pid)
                else
                    print_warn "Node $idx (PID: $pid) is not running"
                fi
            done
            
            if [ ${#verified_pids[@]} -ne ${#STARTED_PIDS[@]} ]; then
                print_error "Some nodes failed verification, exiting..."
                exit 1
            fi
            
            print_detail "All ${#verified_pids[@]} nodes verified, monitoring..."
            
            while true; do
                sleep 5
                local stopped_nodes=()
                local running_count=0
                
                for idx in "${!STARTED_PIDS[@]}"; do
                    local pid="${STARTED_PIDS[$idx]}"
                    if is_process_running "$pid"; then
                        running_count=$((running_count + 1))
                    else
                        stopped_nodes+=("Node $idx (PID: $pid)")
                    fi
                done
                
                if [ ${#stopped_nodes[@]} -gt 0 ]; then
                    echo ""
                    print_warn "Detected stopped node(s):"
                    for node_info in "${stopped_nodes[@]}"; do
                        print_warn "  - $node_info"
                    done
                    print_info "Cluster status: $running_count/${#STARTED_PIDS[@]} nodes running"
                fi
                
                if [ $running_count -eq 0 ]; then
                    echo ""
                    print_error "All cluster nodes have stopped"
                    break
                fi
            done
        fi
    else
        print_step 6 $TOTAL_STEPS "Starting cluster nodes" "skipped (--no-start)"
        print_step 7 $TOTAL_STEPS "Initializing admin password" "skipped"
        echo ""
        print_info "Cluster created. To start nodes manually, run startup.sh in each node directory"
    fi
}

# ============================================================================
# Cluster Info Display
# ============================================================================

print_cluster_info() {
    local cluster_dir=$1
    local nacos_version=$2
    local node_count=$3
    shift 3
    
    # First half: main ports, second half: console ports
    local -a main_ports=()
    local -a console_ports=()
    
    local i
    for ((i=0; i<node_count; i++)); do
        main_ports+=($1)
        shift
    done
    
    for ((i=0; i<node_count; i++)); do
        console_ports+=($1)
        shift
    done
    
    local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
    local local_ip=$(get_local_ip)
    
    echo ""
    echo "========================================"
    print_info "Cluster Started Successfully!"
    echo "========================================"
    echo ""
    print_info "Cluster ID: $CLUSTER_ID"
    print_info "Nodes: ${#STARTED_PIDS[@]}"
    echo ""
    print_info "Node endpoints:"
    
    for i in "${!main_ports[@]}"; do
        if [ "$nacos_major" -ge 3 ]; then
            echo "  Node $i: http://${local_ip}:${console_ports[$i]}"
        else
            echo "  Node $i: http://${local_ip}:${main_ports[$i]}/nacos"
        fi
    done
    
    echo ""
    if [ -n "$NACOS_PASSWORD" ]; then
        echo "Login credentials:"
        echo "  Username: nacos"
        echo "  Password: $NACOS_PASSWORD"
    fi
    
    echo ""
    echo "========================================"
    echo "Perfect !"
    echo "========================================"
}

# ============================================================================
# Clean Existing Cluster
# ============================================================================

clean_existing_cluster() {
    local cluster_dir=$1
    
    print_detail "Cleaning existing cluster nodes..."
    
    local node_dirs=($(ls -d "$cluster_dir/"[0-9]*"-v"* 2>/dev/null))
    
    if [ ${#node_dirs[@]} -eq 0 ]; then
        return 0
    fi
    
    # Stop all running nodes
    for node_dir in "${node_dirs[@]}"; do
        local pid=""
        local node_config="$node_dir/conf/application.properties"
        local node_port=""
        if [ -f "$node_config" ]; then
            node_port=$(grep "^nacos.server.main.port=" "$node_config" 2>/dev/null | cut -d'=' -f2)
            [ -z "$node_port" ] && node_port=$(grep "^server.port=" "$node_config" 2>/dev/null | cut -d'=' -f2)
        fi

        pid=$(ps aux 2>/dev/null | grep "java" | grep "$node_dir" | grep -v grep | awk '{print $2}' | head -1)
        if [ -z "$pid" ] && [ -n "$node_port" ]; then
            pid=$(_pm_get_pid_by_listen_port "$node_port" || true)
        fi

        if [ -n "$pid" ] && is_process_running "$pid"; then
            print_detail "Stopping $(basename "$node_dir") (PID: $pid)"
            stop_nacos_gracefully "$pid" 2 >/dev/null 2>&1 || true
        fi
    done
    
    sleep 3
    
    # Force kill if still running
    for node_dir in "${node_dirs[@]}"; do
        local pid=""
        local node_config="$node_dir/conf/application.properties"
        local node_port=""
        if [ -f "$node_config" ]; then
            node_port=$(grep "^nacos.server.main.port=" "$node_config" 2>/dev/null | cut -d'=' -f2)
            [ -z "$node_port" ] && node_port=$(grep "^server.port=" "$node_config" 2>/dev/null | cut -d'=' -f2)
        fi

        pid=$(ps aux 2>/dev/null | grep "java" | grep "$node_dir" | grep -v grep | awk '{print $2}' | head -1)
        if [ -z "$pid" ] && [ -n "$node_port" ]; then
            pid=$(_pm_get_pid_by_listen_port "$node_port" || true)
        fi

        if [ -n "$pid" ] && is_process_running "$pid"; then
            stop_nacos_gracefully "$pid" 2 >/dev/null 2>&1 || true
        fi
    done
    
    # Remove directories
    for node_dir in "${node_dirs[@]}"; do
        rm -rf "$node_dir"
    done
    
    rm -f "$cluster_dir/cluster.conf"
    rm -f "$cluster_dir/share.properties"
    
    print_detail "Cleaned ${#node_dirs[@]} nodes"
    if [ "$VERBOSE" = true ]; then echo ""; fi
}

# ============================================================================
# Join Cluster
# ============================================================================

join_cluster() {
    local TOTAL_STEPS=5
    
    if [ "$VERBOSE" = true ]; then
        print_info "Join Cluster Mode"
        print_info "===================================="
        echo ""
    else
        echo ""
        echo "Nacos Cluster Join (v${NACOS_SETUP_VERSION:-dev})"
        echo "======================================"
        echo ""
    fi
    
    trap cleanup_on_exit EXIT INT TERM
    
    local cluster_dir="$CLUSTER_BASE_DIR/$CLUSTER_ID"
    
    if [ ! -d "$cluster_dir" ]; then
        print_error "Cluster not found: $CLUSTER_ID"
        exit 1
    fi
    
    local existing_nodes=($(ls -d "$cluster_dir/"[0-9]*"-v"* 2>/dev/null | xargs -n1 basename | sort -t'-' -k1,1n))
    if [ ${#existing_nodes[@]} -eq 0 ]; then
        print_error "No existing nodes found"
        exit 1
    fi
    
    print_detail "Existing nodes: ${#existing_nodes[@]}"
    
    local max_index=-1
    for node in "${existing_nodes[@]}"; do
        local idx=$(echo "$node" | sed -E "s/^([0-9]+)-v.*/\1/")
        if [ "$idx" -gt "$max_index" ]; then max_index=$idx; fi
    done
    
    local new_index=$((max_index + 1))
    local new_node_name="${new_index}-v${VERSION}"
    print_detail "New node: $new_node_name"
    
    # [1/5] Check Java
    step_simple_begin 1 $TOTAL_STEPS "Checking Java environment"
    if ! check_java_requirements "$VERSION" "$ADVANCED_MODE"; then
        step_simple_clear
        print_step_fail 1 $TOTAL_STEPS "Checking Java environment"
        exit 1
    fi
    step_simple_clear
    print_step 1 $TOTAL_STEPS "Checking Java environment" "Java ${JAVA_VERSION}"
    
    # [2/5] Download
    step_simple_begin 2 $TOTAL_STEPS "Downloading Nacos $VERSION"
    local zip_file=$(download_nacos "$VERSION")
    if [ -z "$zip_file" ]; then
        step_simple_clear
        print_step_fail 2 $TOTAL_STEPS "Downloading Nacos $VERSION"
        exit 1
    fi
    step_simple_clear
    print_step 2 $TOTAL_STEPS "Downloading Nacos $VERSION"
    
    # [3/5] Configure node
    local share_properties="$cluster_dir/share.properties"
    if [ ! -f "$share_properties" ]; then
        print_step_fail 3 $TOTAL_STEPS "Configuring node"
        print_error "Security configuration not found"
        exit 1
    fi
    
    step_simple_begin 3 $TOTAL_STEPS "Configuring node"
    
    TOKEN_SECRET=$(grep "^nacos.core.auth.plugin.nacos.token.secret.key=" "$share_properties" | cut -d'=' -f2-)
    IDENTITY_KEY=$(grep "^nacos.core.auth.server.identity.key=" "$share_properties" | cut -d'=' -f2-)
    IDENTITY_VALUE=$(grep "^nacos.core.auth.server.identity.value=" "$share_properties" | cut -d'=' -f2-)
    NACOS_PASSWORD=$(grep "^admin.password=" "$share_properties" | cut -d'=' -f2-)
    
    local new_node_dir="$cluster_dir/$new_node_name"
    if ! extract_nacos_to_target "$zip_file" "$cluster_dir" "$new_node_name"; then
        step_simple_clear
        print_step_fail 3 $TOTAL_STEPS "Configuring node"
        exit 1
    fi
    
    local existing_ports=($(grep -oE ":[0-9]+$" "$cluster_dir/cluster.conf" | cut -d':' -f2))
    local max_port=0
    for port in "${existing_ports[@]}"; do
        if [ "$port" -gt "$max_port" ]; then max_port=$port; fi
    done
    
    local new_main_port=$((max_port + 10))
    local new_console_port=$((8080 + new_index * 10))
    if ! check_port_available $new_main_port; then new_main_port=$(find_available_port $new_main_port); fi
    if ! check_port_available $new_console_port; then new_console_port=$(find_available_port $new_console_port); fi
    
    local local_ip=$(get_local_ip)
    echo "${local_ip}:${new_main_port}" >> "$cluster_dir/cluster.conf"
    
    local use_derby=true
    cp "$cluster_dir/cluster.conf" "$new_node_dir/conf/cluster.conf"
    
    local config_file="$new_node_dir/conf/application.properties"
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        exit 1
    fi
    
    cp "$config_file" "$config_file.original"
    update_port_config "$config_file" "$new_main_port" "$new_console_port" "$VERSION"
    apply_security_config "$config_file" "$TOKEN_SECRET" "$IDENTITY_KEY" "$IDENTITY_VALUE"
    
    if [ "${USE_EXTERNAL_DATASOURCE:-false}" = "true" ]; then
        local datasource_file=$(load_default_datasource_config)
        if [ -n "$datasource_file" ]; then
            apply_datasource_config "$config_file" "$datasource_file"
            use_derby=false
        fi
    fi
    if [ "$use_derby" = true ]; then configure_derby_for_cluster "$config_file"; fi
    rm -f "$config_file.bak"
    
    print_detail "Importing default data into ${new_node_dir}/data..."
    if declare -F run_post_nacos_config_data_import_hook >/dev/null 2>&1; then
        run_post_nacos_config_data_import_hook "$new_node_dir"
    fi
    
    step_simple_clear
    print_step 3 $TOTAL_STEPS "Configuring node" "port=${new_main_port} console=${new_console_port}"

    # [4/5] Skill scanner — no spinner (interactive prompts must stay visible)
    step_simple_clear
    if [ "${VERBOSE:-false}" != true ]; then
        echo -e "${GREEN}[4/5]${NC} Setting up skill-scanner"
    fi
    print_detail "Post-config: optional Cisco skill-scanner step..."
    if declare -F run_post_nacos_config_skill_scanner_hook >/dev/null 2>&1; then
        run_post_nacos_config_skill_scanner_hook
        if declare -F configure_skill_scanner_properties >/dev/null 2>&1 && declare -F _skill_scanner_should_write_plugin_config >/dev/null 2>&1; then
            if _skill_scanner_should_write_plugin_config; then
                configure_skill_scanner_properties "$config_file"
            fi
        fi
    fi
    step_simple_clear
    print_step 4 $TOTAL_STEPS "Setting up skill-scanner"

    # Update cluster.conf in existing nodes
    print_detail "Updating cluster.conf in existing nodes..."
    for existing_node in "${existing_nodes[@]}"; do
        cp "$cluster_dir/cluster.conf" "$cluster_dir/$existing_node/conf/cluster.conf"
    done
    
    # [5/5] Start new node
    if [ "$AUTO_START" = true ]; then
        step_simple_begin 5 $TOTAL_STEPS "Starting node"
        local pid=$(start_cluster_node "$new_node_dir" "$new_node_name" "$new_main_port" "$new_console_port" "$VERSION" "$use_derby")
        
        if [ -n "$pid" ]; then
            step_simple_clear
            print_step 5 $TOTAL_STEPS "Starting node" "joined (PID: $pid)"
            
            if [ "$DAEMON_MODE" = true ]; then
                print_info "Daemon mode: Script will exit"
                trap - EXIT INT TERM
                exit 0
            else
                print_info "Press Ctrl+C to stop node"
                while is_process_running "$pid"; do
                    sleep 5
                done
            fi
        else
            step_simple_clear
            print_step_fail 5 $TOTAL_STEPS "Starting node"
            exit 1
        fi
    else
        print_step 5 $TOTAL_STEPS "Starting node" "skipped (--no-start)"
    fi
}

# ============================================================================
# Leave Cluster
# ============================================================================

leave_cluster() {
    if [ "$VERBOSE" = true ]; then
        print_info "Leave Cluster Mode"
        print_info "===================================="
        echo ""
    fi
    
    local cluster_dir="$CLUSTER_BASE_DIR/$CLUSTER_ID"
    
    if [ ! -d "$cluster_dir" ]; then
        print_error "Cluster not found: $CLUSTER_ID"
        exit 1
    fi
    
    # Find target node - use version sort to handle numeric prefixes correctly
    local existing_nodes=($(ls -d "$cluster_dir/"[0-9]*"-v"* 2>/dev/null | xargs -n1 basename | sort -t'-' -k1,1n))
    local target_node=""
    
    for node in "${existing_nodes[@]}"; do
        local idx=$(echo "$node" | sed -E "s/^([0-9]+)-v.*/\1/")
        if [ "$idx" = "$NODE_INDEX" ]; then
            target_node="$node"
            break
        fi
    done
    
    if [ -z "$target_node" ]; then
        print_error "Node $NODE_INDEX not found"
        exit 1
    fi
    
    local target_node_dir="$cluster_dir/$target_node"
    
    print_info "Removing node: $target_node"
    
    # Get node port
    local node_config="$target_node_dir/conf/application.properties"
    local node_port=$(grep "^nacos.server.main.port=" "$node_config" | cut -d'=' -f2)
    if [ -z "$node_port" ]; then
        node_port=$(grep "^server.port=" "$node_config" | cut -d'=' -f2)
    fi
    
    # Update cluster.conf (remove this node)
    if [ -n "$node_port" ]; then
        grep -v ":${node_port}$" "$cluster_dir/cluster.conf" > "$cluster_dir/cluster.conf.tmp"
        mv "$cluster_dir/cluster.conf.tmp" "$cluster_dir/cluster.conf"
        
        # Update all remaining nodes
        for existing_node in "${existing_nodes[@]}"; do
            if [ "$existing_node" != "$target_node" ]; then
                cp "$cluster_dir/cluster.conf" "$cluster_dir/$existing_node/conf/cluster.conf"
            fi
        done
    fi
    
    # Stop node
    local pid=""
    pid=$(ps aux 2>/dev/null | grep "java" | grep "$target_node_dir" | grep -v grep | awk '{print $2}' | head -1)
    if [ -z "$pid" ] && [ -n "$node_port" ]; then
        pid=$(_pm_get_pid_by_listen_port "$node_port" || true)
    fi

    if [ -n "$pid" ] && is_process_running "$pid"; then
        print_info "Stopping node (PID: $pid)"
        stop_nacos_gracefully "$pid" 2 >/dev/null 2>&1 || true
        sleep 3
        
        if is_process_running "$pid"; then
            stop_nacos_gracefully "$pid" 2 >/dev/null 2>&1 || true
        fi
    fi
    
    # Remove directory
    rm -rf "$target_node_dir"
    
    print_info "Node removed successfully"
}

# ============================================================================
# Main Entry Point
# ============================================================================

run_cluster_mode() {
    # Route to appropriate cluster operation
    if [ "$JOIN_MODE" = true ]; then
        join_cluster
    elif [ "$LEAVE_MODE" = true ]; then
        leave_cluster
    else
        create_cluster
    fi
}
