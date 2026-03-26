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
            if ps -p $pid >/dev/null 2>&1; then
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
    local pid=$(start_nacos_process "$node_dir" "cluster" "$use_derby")
    
    if [ -z "$pid" ]; then
        print_error "Failed to start node $node_name" >&2
        return 1
    fi
    
    # Wait for readiness
    if wait_for_nacos_ready "$main_port" "$console_port" "$nacos_version" 60; then
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        print_info "Node $node_name ready (PID: $pid, ${elapsed}s)" >&2
        echo "$pid"
        return 0
    else
        print_error "Node $node_name startup timeout" >&2
        if [ -n "$pid" ] && ps -p $pid >/dev/null 2>&1; then
            kill -9 $pid 2>/dev/null || true
        fi
        return 1
    fi
}

# ============================================================================
# Cluster Creation
# ============================================================================

create_cluster() {
    print_info "Nacos Cluster Installation"
    print_info "===================================="
    echo ""
    
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
    
    print_info "Cluster ID: $CLUSTER_ID"
    print_info "Nacos version: $VERSION"
    print_info "Replica count: $REPLICA_COUNT"
    print_info "Cluster directory: $cluster_dir"
    echo ""
    
    # Check Java
    if ! check_java_requirements "$VERSION" "$ADVANCED_MODE"; then
        exit 1
    fi
    echo ""
    
    # Download Nacos
    local zip_file=$(download_nacos "$VERSION")
    if [ -z "$zip_file" ]; then
        exit 1
    fi
    echo ""
    
    # Configure cluster security
    configure_cluster_security "$cluster_dir" "$ADVANCED_MODE"
    
    # Check datasource (only if explicitly specified via -db-conf)
    local use_derby=true
    local datasource_file=""
    
    if [ "${USE_EXTERNAL_DATASOURCE:-false}" = "true" ]; then
        datasource_file=$(load_default_datasource_config)
        if [ -n "$datasource_file" ]; then
            print_info "Using external database"
            use_derby=false
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
    echo ""
    
    # Allocate ports for all nodes
    print_info "Allocating ports for $REPLICA_COUNT nodes..."
    local port_result=$(allocate_cluster_ports "$BASE_PORT" "$REPLICA_COUNT" "$VERSION")
    
    if [ -z "$port_result" ]; then
        print_error "Failed to allocate ports"
        exit 1
    fi
    
    # Parse port allocations
    declare -a node_main_ports=()
    declare -a node_console_ports=()
    
    for port_pair in $port_result; do
        IFS=':' read -r main_port console_port <<< "$port_pair"
        node_main_ports+=("$main_port")
        node_console_ports+=("$console_port")
    done
    echo ""
    
    # Prepare cluster metadata
    local cluster_conf="$cluster_dir/cluster.conf"
    local local_ip=$(get_local_ip)
    print_info "Local IP: $local_ip"
    echo ""
    
    # Extract and configure all nodes first
    print_info "Setting up cluster nodes..."
    echo ""
    
    for ((i=0; i<REPLICA_COUNT; i++)); do
        local node_name="${i}-v${VERSION}"
        local node_dir="$cluster_dir/$node_name"
        
        print_info "Configuring node $i..."
        
        if ! extract_nacos_to_target "$zip_file" "$cluster_dir" "$node_name"; then
            print_error "Failed to extract node $node_name"
            exit 1
        fi
        
        # Create incremental cluster.conf for each node
        # Only include nodes up to current index (works for both Derby and external DB)
        local node_cluster_conf="$node_dir/conf/cluster.conf"
        > "$node_cluster_conf"
        
        for ((j=0; j<=i; j++)); do
            echo "${local_ip}:${node_main_ports[$j]}" >> "$node_cluster_conf"
        done
        
        # Configure node (without copying cluster.conf, already created above)
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
        
        local main_port="${node_main_ports[$i]}"
        local console_port="${node_console_ports[$i]}"
        local nacos_major=$(echo "$VERSION" | cut -d. -f1)
        
        if [ "$nacos_major" -ge 3 ]; then
            # Nacos 3.x: 显示所有端口
            print_info "  ✓ Server: $main_port | Console: $console_port | gRPC: $((main_port+1000)),$((main_port+1001)) | Raft: $((main_port-1000))"
        else
            # Nacos 2.x: 显示所有端口
            print_info "  ✓ Server: $main_port | gRPC: $((main_port+1000)),$((main_port+1001)) | Raft: $((main_port-1000))"
        fi
    done
    echo ""
    
    # Create master cluster.conf for reference (contains all nodes)
    > "$cluster_conf"
    for i in "${!node_main_ports[@]}"; do
        echo "${local_ip}:${node_main_ports[$i]}" >> "$cluster_conf"
    done
    
    print_info "Final cluster configuration:"
    cat "$cluster_conf" | while read line; do
        echo "  $line"
    done
    echo ""

    print_info "Post-config: optional Cisco skill-scanner step (Nacos ${VERSION})..."
    echo "[nacos-setup/skill-scanner] cluster: post-config reached (VERSION=${VERSION})" >&2
    if declare -F run_post_nacos_config_skill_scanner_hook >/dev/null 2>&1; then
        run_post_nacos_config_skill_scanner_hook
        # Configure skill-scanner plugin properties for all cluster nodes
        if declare -F configure_skill_scanner_properties >/dev/null 2>&1; then
            for ((i=0; i<REPLICA_COUNT; i++)); do
                local node_name="${i}-v${VERSION}"
                local node_config_file="$cluster_dir/$node_name/conf/application.properties"
                if [ -f "$node_config_file" ]; then
                    configure_skill_scanner_properties "$node_config_file"
                fi
            done
        fi
    else
        echo "[nacos-setup/skill-scanner] ERROR: run_post_nacos_config_skill_scanner_hook missing; add lib/skill_scanner_install.sh to $SCRIPT_DIR" >&2
    fi
    echo ""

    # Start all nodes
    if [ "$AUTO_START" = true ]; then
        print_info "Starting cluster nodes (sequential start)..."
        echo ""
        
        for ((i=0; i<REPLICA_COUNT; i++)); do
            local node_name="${i}-v${VERSION}"
            local node_dir="$cluster_dir/$node_name"
            
            local pid=$(start_cluster_node "$node_dir" "$node_name" "${node_main_ports[$i]}" "${node_console_ports[$i]}" "$VERSION" "$use_derby")
            
            if [ -n "$pid" ]; then
                STARTED_PIDS+=("$pid")
                
                # Update previous nodes' cluster.conf to include new node
                if [ $i -gt 0 ]; then
                    print_info "Updating cluster.conf in previous nodes to include node $i..."
                    for ((j=0; j<i; j++)); do
                        local prev_node_dir="$cluster_dir/${j}-v${VERSION}"
                        local prev_cluster_conf="$prev_node_dir/conf/cluster.conf"
                        echo "${local_ip}:${node_main_ports[$i]}" >> "$prev_cluster_conf"
                    done
                fi
            else
                print_error "Failed to start node $node_name"
                exit 1
            fi
        done
        
        echo ""
        print_info "All nodes started successfully!"
        
        # Initialize password on first node
        if [ -n "$NACOS_PASSWORD" ] && [ "$NACOS_PASSWORD" != "nacos" ]; then
            print_info "Initializing admin password..."
            if initialize_admin_password "${node_main_ports[0]}" "${node_console_ports[0]}" "$VERSION" "$NACOS_PASSWORD"; then
                print_info "Admin password initialized successfully"
                echo ""
                print_info "Auto-Generated Admin Password:"
                echo "  $NACOS_PASSWORD"
                echo ""
            else
                print_warn "Password initialization failed (may already be set previously)"
                # Clear password so it won't be shown in completion info
                NACOS_PASSWORD=""
            fi
        fi
        
        # Print cluster info
        print_cluster_info "$cluster_dir" "$VERSION" "$REPLICA_COUNT" "${node_main_ports[@]}" "${node_console_ports[@]}"
        
        # Handle daemon or monitoring
        if [ "$DAEMON_MODE" = true ]; then
            print_info "Daemon mode: Script will exit"
            trap - EXIT INT TERM
            exit 0
        else
            print_info "Press Ctrl+C to stop cluster"
            echo ""
            
            # Verify all PIDs before monitoring
            print_info "Verifying cluster nodes..." >&2
            local -a verified_pids=()
            for idx in "${!STARTED_PIDS[@]}"; do
                local pid="${STARTED_PIDS[$idx]}"
                if ps -p $pid >/dev/null 2>&1; then
                    verified_pids+=($pid)
                else
                    print_warn "Node $idx (PID: $pid) is not running" >&2
                fi
            done
            
            if [ ${#verified_pids[@]} -ne ${#STARTED_PIDS[@]} ]; then
                print_error "Some nodes failed verification, exiting..." >&2
                exit 1
            fi
            
            print_info "All ${#verified_pids[@]} nodes verified, monitoring..." >&2
            
            # Monitor all nodes
            while true; do
                sleep 5
                local stopped_nodes=()
                local running_count=0
                
                for idx in "${!STARTED_PIDS[@]}"; do
                    local pid="${STARTED_PIDS[$idx]}"
                    if ps -p $pid >/dev/null 2>&1; then
                        running_count=$((running_count + 1))
                    else
                        stopped_nodes+=("Node $idx (PID: $pid)")
                    fi
                done
                
                # Report stopped nodes if any
                if [ ${#stopped_nodes[@]} -gt 0 ]; then
                    echo ""
                    print_warn "Detected stopped node(s):"
                    for node_info in "${stopped_nodes[@]}"; do
                        print_warn "  - $node_info"
                    done
                    print_info "Cluster status: $running_count/${#STARTED_PIDS[@]} nodes running"
                fi
                
                # Exit only if all nodes stopped
                if [ $running_count -eq 0 ]; then
                    echo ""
                    print_error "All cluster nodes have stopped"
                    break
                fi
            done
        fi
    else
        print_info "Cluster created (auto-start disabled)"
        print_info "To start nodes manually, run startup.sh in each node directory"
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
    
    print_info "Cleaning existing cluster nodes..."
    
    local node_dirs=($(ls -d "$cluster_dir/"[0-9]*"-v"* 2>/dev/null))
    
    if [ ${#node_dirs[@]} -eq 0 ]; then
        return 0
    fi
    
    # Stop all running nodes
    for node_dir in "${node_dirs[@]}"; do
        local pid=$(ps aux | grep "java" | grep "$node_dir" | grep -v grep | awk '{print $2}' | head -1)
        
        if [ -n "$pid" ] && ps -p $pid >/dev/null 2>&1; then
            print_info "Stopping $(basename "$node_dir") (PID: $pid)"
            kill $pid 2>/dev/null || true
        fi
    done
    
    sleep 3
    
    # Force kill if still running
    for node_dir in "${node_dirs[@]}"; do
        local pid=$(ps aux | grep "java" | grep "$node_dir" | grep -v grep | awk '{print $2}' | head -1)
        
        if [ -n "$pid" ] && ps -p $pid >/dev/null 2>&1; then
            kill -9 $pid 2>/dev/null || true
        fi
    done
    
    # Remove directories
    for node_dir in "${node_dirs[@]}"; do
        rm -rf "$node_dir"
    done
    
    rm -f "$cluster_dir/cluster.conf"
    rm -f "$cluster_dir/share.properties"
    
    print_info "Cleaned ${#node_dirs[@]} nodes"
    echo ""
}

# ============================================================================
# Join Cluster
# ============================================================================

join_cluster() {
    print_info "Join Cluster Mode"
    print_info "===================================="
    echo ""
    
    # Set up cleanup trap for join mode
    trap cleanup_on_exit EXIT INT TERM
    
    local cluster_dir="$CLUSTER_BASE_DIR/$CLUSTER_ID"
    
    if [ ! -d "$cluster_dir" ]; then
        print_error "Cluster not found: $CLUSTER_ID"
        exit 1
    fi
    
    # Find existing nodes - use version sort to handle numeric prefixes correctly
    local existing_nodes=($(ls -d "$cluster_dir/"[0-9]*"-v"* 2>/dev/null | xargs -n1 basename | sort -t'-' -k1,1n))
    
    if [ ${#existing_nodes[@]} -eq 0 ]; then
        print_error "No existing nodes found"
        exit 1
    fi
    
    print_info "Existing nodes: ${#existing_nodes[@]}"
    
    # Determine next node index
    local max_index=-1
    for node in "${existing_nodes[@]}"; do
        local idx=$(echo "$node" | sed -E "s/^([0-9]+)-v.*/\1/")
        if [ "$idx" -gt "$max_index" ]; then
            max_index=$idx
        fi
    done
    
    local new_index=$((max_index + 1))
    local new_node_name="${new_index}-v${VERSION}"
    
    print_info "New node: $new_node_name"
    echo ""
    
    # Check Java
    if ! check_java_requirements "$VERSION" "$ADVANCED_MODE"; then
        exit 1
    fi
    
    # Load security configuration
    local share_properties="$cluster_dir/share.properties"
    if [ ! -f "$share_properties" ]; then
        print_error "Security configuration not found"
        exit 1
    fi
    
    TOKEN_SECRET=$(grep "^nacos.core.auth.plugin.nacos.token.secret.key=" "$share_properties" | cut -d'=' -f2-)
    IDENTITY_KEY=$(grep "^nacos.core.auth.server.identity.key=" "$share_properties" | cut -d'=' -f2-)
    IDENTITY_VALUE=$(grep "^nacos.core.auth.server.identity.value=" "$share_properties" | cut -d'=' -f2-)
    NACOS_PASSWORD=$(grep "^admin.password=" "$share_properties" | cut -d'=' -f2-)
    
    # Download and extract
    local zip_file=$(download_nacos "$VERSION")
    if [ -z "$zip_file" ]; then
        exit 1
    fi
    
    local new_node_dir="$cluster_dir/$new_node_name"
    if ! extract_nacos_to_target "$zip_file" "$cluster_dir" "$new_node_name"; then
        exit 1
    fi
    
    # Allocate ports
    local existing_ports=($(grep -oE ":[0-9]+$" "$cluster_dir/cluster.conf" | cut -d':' -f2))
    local max_port=0
    for port in "${existing_ports[@]}"; do
        if [ "$port" -gt "$max_port" ]; then
            max_port=$port
        fi
    done
    
    local new_main_port=$((max_port + 10))
    local new_console_port=$((8080 + new_index * 10))
    
    if ! check_port_available $new_main_port; then
        new_main_port=$(find_available_port $new_main_port)
    fi
    
    if ! check_port_available $new_console_port; then
        new_console_port=$(find_available_port $new_console_port)
    fi
    
    print_info "Ports: main=$new_main_port, console=$new_console_port"
    echo ""
    
    # Update cluster.conf
    local local_ip=$(get_local_ip)
    echo "${local_ip}:${new_main_port}" >> "$cluster_dir/cluster.conf"
    
    # Configure node
    local use_derby=true
    
    # Copy cluster.conf
    cp "$cluster_dir/cluster.conf" "$new_node_dir/conf/cluster.conf"
    
    # Configure application.properties
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
    
    if [ "$use_derby" = true ]; then
        configure_derby_for_cluster "$config_file"
    fi
    
    rm -f "$config_file.bak"
    print_info "Node configured: main=$new_main_port, console=$new_console_port"
    echo ""

    print_info "Post-config: optional Cisco skill-scanner step (Nacos ${VERSION})..."
    echo "[nacos-setup/skill-scanner] cluster join: post-config reached (VERSION=${VERSION})" >&2
    if declare -F run_post_nacos_config_skill_scanner_hook >/dev/null 2>&1; then
        run_post_nacos_config_skill_scanner_hook
        # Configure skill-scanner plugin properties for the new node
        if declare -F configure_skill_scanner_properties >/dev/null 2>&1; then
            configure_skill_scanner_properties "$config_file"
        fi
    else
        echo "[nacos-setup/skill-scanner] ERROR: run_post_nacos_config_skill_scanner_hook missing; add lib/skill_scanner_install.sh to $SCRIPT_DIR" >&2
    fi
    echo ""

    # Update cluster.conf in existing nodes
    print_info "Updating cluster.conf in existing nodes..."
    for existing_node in "${existing_nodes[@]}"; do
        cp "$cluster_dir/cluster.conf" "$cluster_dir/$existing_node/conf/cluster.conf"
    done
    echo ""
    
    # Start new node
    if [ "$AUTO_START" = true ]; then
        local pid=$(start_cluster_node "$new_node_dir" "$new_node_name" "$new_main_port" "$new_console_port" "$VERSION" "$use_derby")
        
        if [ -n "$pid" ]; then
            print_info "Node joined successfully!"
            
            if [ "$DAEMON_MODE" = true ]; then
                print_info "Daemon mode: Script will exit"
                trap - EXIT INT TERM
                exit 0
            else
                print_info "Press Ctrl+C to stop node"
                while ps -p $pid >/dev/null 2>&1; do
                    sleep 5
                done
            fi
        else
            print_error "Failed to start new node"
            exit 1
        fi
    fi
}

# ============================================================================
# Leave Cluster
# ============================================================================

leave_cluster() {
    print_info "Leave Cluster Mode"
    print_info "===================================="
    echo ""
    
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
    local pid=$(ps aux | grep "java" | grep "$target_node_dir" | grep -v grep | awk '{print $2}' | head -1)
    
    if [ -n "$pid" ] && ps -p $pid >/dev/null 2>&1; then
        print_info "Stopping node (PID: $pid)"
        kill $pid 2>/dev/null
        sleep 3
        
        if ps -p $pid >/dev/null 2>&1; then
            kill -9 $pid 2>/dev/null
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
