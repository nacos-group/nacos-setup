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

# Port Management Library
# Functions for port allocation, checking, and conflict resolution

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ============================================================================
# Port Availability Check
# ============================================================================

# Check if a port is available (not in use)
# Returns: 0 if available, 1 if in use
check_port_available() {
    local port=$1

    if command -v lsof &> /dev/null; then
        # Use lsof if available (most reliable)
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
            return 1  # Port is in use
        fi
    elif command -v netstat &> /dev/null; then
        # Fallback to netstat with word boundary
        if netstat -an | grep -E "[.:]${port}[[:space:]].*LISTEN" >/dev/null 2>&1; then
            return 1  # Port is in use
        fi
    elif command -v ss &> /dev/null; then
        # Use ss on modern Linux systems
        if ss -ltn | grep -E ":${port}[[:space:]]" >/dev/null 2>&1; then
            return 1  # Port is in use
        fi
    elif [ -f /proc/net/tcp ]; then
        # Linux: check /proc/net/tcp directly
        # Convert port to hex
        local port_hex=$(printf '%04X' $port)
        if grep -q "^[^:]*:[0-9A-Fa-f]*:${port_hex}" /proc/net/tcp 2>/dev/null; then
            return 1  # Port is in use
        fi
    elif command -v nc &> /dev/null; then
        # Use netcat to test port availability
        # Try to connect, if successful, port is in use
        if nc -z localhost $port 2>/dev/null; then
            return 1  # Port is in use
        fi
    elif command -v python3 &> /dev/null || command -v python &> /dev/null; then
        # Use Python socket to test port
        local python_cmd=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
        if $python_cmd -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', $port)); s.close()" 2>/dev/null; then
            :  # Port available
        else
            return 1  # Port is in use
        fi
    else
        # Try bash built-in /dev/tcp as last resort
        if (echo > /dev/tcp/localhost/$port) 2>/dev/null; then
            return 1  # Port is in use
        fi
    fi
    
    return 0  # Port is available
}

# ============================================================================
# Process Detection
# ============================================================================

# Get PID of process using the port
# Returns: PID or empty string
get_port_pid() {
    local port=$1
    local pid=""
    
    if command -v lsof &> /dev/null; then
        # Use lsof with exact port matching
        local all_pids=$(lsof -ti :$port 2>/dev/null)
        
        if [ -n "$all_pids" ]; then
            # Verify each PID actually uses this exact port
            for p in $all_pids; do
                if lsof -Pi :$port -sTCP:LISTEN -a -p $p >/dev/null 2>&1; then
                    pid="$p"
                    break
                fi
            done
        fi
    elif command -v fuser &> /dev/null; then
        # Use fuser to find PID (Linux)
        pid=$(fuser $port/tcp 2>/dev/null | tr -d ' ')
    elif command -v netstat &> /dev/null; then
        # Try to extract PID from netstat
        local netstat_line=$(netstat -tulpn 2>/dev/null | grep -E ":${port}[[:space:]]" | head -1)
        if [ -n "$netstat_line" ]; then
            local col7=$(echo "$netstat_line" | awk '{print $7}')
            pid="${col7%%/*}"
        fi
    elif [ -f /proc/net/tcp ] && [ -d /proc ]; then
        # Linux: parse /proc/net/tcp to find inode, then find PID
        local port_hex=$(printf '%04X' $port)
        local inode=$(grep "^[^:]*:[0-9A-Fa-f]*:${port_hex}" /proc/net/tcp 2>/dev/null | awk '{print $10}')
        if [ -n "$inode" ] && [ "$inode" != "0" ]; then
            # Search for this inode in process file descriptors
            for fd in /proc/[0-9]*/fd/*; do
                if [ -L "$fd" ]; then
                    local link=$(readlink "$fd" 2>/dev/null)
                    if [ "$link" = "socket:[$inode]" ]; then
                        pid=$(echo "$fd" | cut -d'/' -f3)
                        break
                    fi
                fi
            done
        fi
    fi
    
    echo "$pid"
}

# Check if PID is a Nacos process
# Returns: 0 if Nacos process, 1 otherwise
is_nacos_process() {
    local pid=$1
    
    if [ -z "$pid" ]; then
        return 1
    fi
    
    # Check if process exists
    if ! ps -p $pid >/dev/null 2>&1; then
        return 1
    fi
    
    # Get the full command line of the process
    local cmd=$(ps -p $pid -o command= 2>/dev/null)
    
    if [ -z "$cmd" ]; then
        return 1
    fi
    
    # Check if command line contains 'nacos'
    if echo "$cmd" | grep -qi "nacos"; then
        return 0  # Is Nacos process
    else
        return 1  # Not Nacos process
    fi
}

# ============================================================================
# Port Allocation
# ============================================================================

# Find next available port starting from given port
# Returns: available port number or empty on failure
find_available_port() {
    local start_port=$1
    local port=$start_port
    
    while [ $port -lt 65535 ]; do
        if check_port_available $port; then
            echo $port
            return 0
        fi
        port=$((port + 1))
    done
    
    return 1
}

# Find an available port ensuring all Nacos-related ports are free
# Parameters: start_port
# Returns: server port or empty on failure
find_available_nacos_port() {
    local start_port=$1
    local port=$start_port
    
    while [ $port -lt 64535 ]; do
        local grpc_client=$((port + 1000))
        local grpc_server=$((port + 1001))
        local raft_port=$((port - 1000))
        
        # Check all required ports
        if [ $raft_port -gt 0 ] && \
           check_port_available $port && \
           check_port_available $grpc_client && \
           check_port_available $grpc_server && \
           check_port_available $raft_port; then
            echo $port
            return 0
        fi
        port=$((port + 1))
    done
    
    return 1
}

# ============================================================================
# Process Management
# ============================================================================

# Stop Nacos process (graceful then force)
# Returns: 0 on success, 1 on failure
stop_nacos_process() {
    local pid=$1
    local timeout=${2:-10}
    
    if [ -z "$pid" ] || ! ps -p $pid >/dev/null 2>&1; then
        return 0
    fi
    
    # Try graceful shutdown first
    kill $pid 2>/dev/null
    
    # Wait for graceful shutdown
    local wait_count=0
    while [ $wait_count -lt $timeout ]; do
        if ! ps -p $pid >/dev/null 2>&1; then
            print_info "Process stopped gracefully (PID: $pid)"
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    # Force kill if still running
    print_warn "Graceful shutdown timed out, force killing PID: $pid"
    kill -9 $pid 2>/dev/null
    sleep 1
    
    if ! ps -p $pid >/dev/null 2>&1; then
        print_info "Process force stopped (PID: $pid)"
        return 0
    else
        print_error "Failed to stop process (PID: $pid)"
        return 1
    fi
}

# ============================================================================
# Port Conflict Resolution
# ============================================================================

# Handle port conflict: check if Nacos process, decide action
# Returns: 0 if port freed, 1 if need to switch port
handle_port_conflict() {
    local port=$1
    local port_name=$2  # e.g., "Server Port", "Console Port"
    local allow_kill=${3:-false}  # Whether to kill existing Nacos
    
    print_warn "Port $port ($port_name) is already in use" >&2
    
    # Get PID and check if it's Nacos
    local pid=$(get_port_pid $port)
    
    if [ -n "$pid" ] && is_nacos_process $pid; then
        if [ "$allow_kill" = true ]; then
            # Kill mode: stop existing Nacos
            print_warn "Stopping existing Nacos process (PID: $pid)..." >&2
            if stop_nacos_process $pid; then
                sleep 2  # Wait for port to be fully released
                print_info "Port $port is now available" >&2
                return 0  # Port freed successfully
            else
                print_error "Failed to stop process" >&2
                return 1
            fi
        else
            # Safe mode: keep existing Nacos, switch port
            print_warn "Multi-instance mode: will use different port" >&2
            return 1  # Need to switch port
        fi
    else
        # Not a Nacos process - need to use a different port
        if [ -n "$pid" ]; then
            print_warn "Port occupied by non-Nacos process (PID: $pid)" >&2
        else
            print_warn "Port is in use" >&2
        fi
        return 1  # Need to switch port
    fi
}

# ============================================================================
# Standalone Port Allocation
# ============================================================================

# Allocate ports for standalone mode (with conflict resolution)
# Parameters: base_port, nacos_version, advanced_mode, allow_kill
# Returns: "server_port console_port" or empty on error
allocate_standalone_ports() {
    local base_port=$1
    local nacos_version=$2
    local advanced_mode=${3:-false}
    local allow_kill=${4:-false}
    
    local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
    local need_console_port=false
    
    if [ "$nacos_major" -ge 3 ]; then
        need_console_port=true
    fi
    
    local server_port=$base_port
    local grpc_port=$((base_port + 1000))
    local console_port=8080
    
    # Check and allocate server port
    if ! check_port_available $server_port; then
        if handle_port_conflict $server_port "Server Port" "$allow_kill"; then
            # Port freed, continue with original
            :
        else
            # Need new port
            if [ "$advanced_mode" = false ]; then
                server_port=$(find_available_nacos_port 18848)
                if [ -z "$server_port" ]; then
                    print_error "No available port pair found" >&2
                    return 1
                fi
                print_detail "Auto-selected port: $server_port" >&2
            else
                print_error "Port $server_port unavailable. Use -p to specify different port" >&2
                return 1
            fi
        fi
    fi
    
    # Check gRPC port
    grpc_port=$((server_port + 1000))
    if ! check_port_available $grpc_port; then
        print_warn "gRPC port $grpc_port is in use" >&2
        server_port=$(find_available_nacos_port $((server_port + 1)))
        if [ -z "$server_port" ]; then
            print_error "No available port pair found" >&2
            return 1
        fi
        print_detail "Reallocated to port pair: $server_port (gRPC: $((server_port + 1000)))" >&2
    fi
    
    # Allocate console port if needed
    if [ "$need_console_port" = true ]; then
        console_port=$((8080 + (server_port - 8848) / 10))
        if ! check_port_available $console_port; then
            console_port=$(find_available_port $console_port)
            if [ -z "$console_port" ]; then
                # Fallback: search from 18080
                console_port=$(find_available_port 18080)
                if [ -z "$console_port" ]; then
                    print_error "No available console port found" >&2
                    return 1
                fi
            fi
            print_detail "Console port: $console_port" >&2
        fi
    fi
    
    echo "$server_port $console_port"
    return 0
}

# ============================================================================
# Cluster Port Allocation
# ============================================================================

# Allocate ports for cluster nodes (with conflict resolution)
# Parameters: base_port, node_count, nacos_version
# Returns: array format "main:console main:console ..." or empty on error
allocate_cluster_ports() {
    local base_port=$1
    local node_count=$2
    local nacos_version=$3
    
    local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
    local result=""
    
    for ((i=0; i<node_count; i++)); do
        local target_main_port=$((base_port + i * 10))
        local main_port=$target_main_port
        
        # Check main port and all related ports availability
        local grpc_client=$((target_main_port + 1000))
        local grpc_server=$((target_main_port + 1001))
        local raft_port=$((target_main_port - 1000))
        
        local port_conflict=false
        if ! check_port_available $target_main_port; then
            port_conflict=true
        elif ! check_port_available $grpc_client; then
            port_conflict=true
        elif ! check_port_available $grpc_server; then
            port_conflict=true
        elif [ $raft_port -gt 0 ] && ! check_port_available $raft_port; then
            port_conflict=true
        fi
        
        if [ "$port_conflict" = true ]; then
            print_warn "Port $target_main_port or related ports are in use for node $i" >&2
            main_port=$(find_available_nacos_port $((target_main_port + 1)))
            if [ -z "$main_port" ]; then
                print_error "Could not find available port set for node $i" >&2
                return 1
            fi
            print_detail "Node $i using alternative port: $main_port (gRPC: $((main_port+1000)),$((main_port+1001)), Raft: $((main_port-1000)))" >&2
        fi
        
        # Allocate console port (only for Nacos 3.x)
        local console_port=0
        if [ "$nacos_major" -ge 3 ]; then
            console_port=$((8080 + i * 10))
            local console_attempts=0
            local max_attempts=10
            
            while [ $console_attempts -lt $max_attempts ]; do
                if check_port_available $console_port; then
                    break  # Port is available
                fi
                # Port is occupied, try next one
                console_port=$((console_port + 1))
                console_attempts=$((console_attempts + 1))
            done
            
            if [ $console_attempts -ge $max_attempts ]; then
                # All nearby ports occupied, search from alternative range
                console_port=$(find_available_port $((18080 + i * 10)))
                if [ -z "$console_port" ]; then
                    print_error "No available console port found for node $i" >&2
                    return 1
                fi
            fi
        fi
        
        # Append to result
        if [ -z "$result" ]; then
            result="${main_port}:${console_port}"
        else
            result="${result} ${main_port}:${console_port}"
        fi
    done
    
    echo "$result"
    return 0
}
