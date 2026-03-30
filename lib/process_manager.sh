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

# Process Management Library
# Handles Nacos process lifecycle, health checks, and password initialization

# Load dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/java_manager.sh"

_pm_debug() {
    if [ "${VERBOSE:-false}" = true ]; then
        echo "[DEBUG] $*" >&2
    fi
}

# ============================================================================
# Health Check
# ============================================================================

# Wait for Nacos node to be ready
# Parameters: main_port, console_port, nacos_version, max_wait_seconds
# Returns: 0 on success, 1 on timeout
wait_for_nacos_ready() {
    local main_port=$1
    local console_port=$2
    local nacos_version=$3
    local max_wait=${4:-60}
    local wait_count=0
    local -a health_urls=()
    local -a fallback_urls=()
    
    # Determine health check URL(s) based on Nacos version
    local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
    if [ "$nacos_major" -ge 3 ]; then
        health_urls=(
            "http://127.0.0.1:${console_port}/v3/console/health/readiness"
            "http://localhost:${console_port}/v3/console/health/readiness"
            "http://127.0.0.1:${console_port}/nacos/v3/console/health/readiness"
            "http://localhost:${console_port}/nacos/v3/console/health/readiness"
        )
        # Some builds may expose only the root console endpoint at startup.
        fallback_urls=(
            "http://127.0.0.1:${console_port}/"
            "http://localhost:${console_port}/"
            "http://127.0.0.1:${main_port}/nacos/"
            "http://localhost:${main_port}/nacos/"
        )
    else
        health_urls=(
            "http://127.0.0.1:${main_port}/nacos/v2/console/health/readiness"
            "http://localhost:${main_port}/nacos/v2/console/health/readiness"
        )
        fallback_urls=(
            "http://127.0.0.1:${main_port}/nacos/"
            "http://localhost:${main_port}/nacos/"
        )
    fi
    
    _pm_debug "wait_for_nacos_ready max_wait=${max_wait}s"
    _pm_debug "health_urls=${health_urls[*]}"
    _pm_debug "fallback_urls=${fallback_urls[*]}"
    _pm_debug "HTTP_PROXY=${HTTP_PROXY:-<empty>} HTTPS_PROXY=${HTTPS_PROXY:-<empty>} NO_PROXY=${NO_PROXY:-<empty>}"

    while [ $wait_count -lt $max_wait ]; do
        local url

        # 1) strict readiness endpoint(s)
        for url in "${health_urls[@]}"; do
            if curl --noproxy "*" --connect-timeout 2 --max-time 3 -sf "$url" >/dev/null 2>&1; then
                _pm_debug "Readiness OK via ${url}"
                if [ "$VERBOSE" = true ]; then echo -ne "\r\033[K" >&2; fi
                return 0
            fi
        done

        # 2) fallback: service endpoint responds with any HTTP status (not 000)
        for url in "${fallback_urls[@]}"; do
            local code
            code=$(curl --noproxy "*" --connect-timeout 2 --max-time 3 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
            if [ "$code" != "000" ]; then
                _pm_debug "Fallback endpoint responded (${code}) via ${url}; treat as started"
                if [ "$VERBOSE" = true ]; then echo -ne "\r\033[K" >&2; fi
                return 0
            fi
        done
        
        # Update countdown display (verbose only to keep simple output clean)
        if [ "$VERBOSE" = true ]; then
            echo -ne "\r[INFO] Waiting for Nacos to be ready... ${wait_count}s" >&2
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    if [ "$VERBOSE" = true ]; then echo "" >&2; fi
    _pm_debug "Health check timed out. Collecting diagnostics..."
    if command -v netstat >/dev/null 2>&1; then
        _pm_debug "Listening ports snapshot (8848/8080/9848):"
        netstat -an 2>/dev/null | grep -E '[:.]8848[[:space:]]|[:.]8080[[:space:]]|[:.]9848[[:space:]]' >&2 || true
    fi
    if command -v ps >/dev/null 2>&1; then
        _pm_debug "Java process snapshot:"
        ps aux 2>/dev/null | grep -i java | grep -v grep >&2 || true
    fi
    print_warn "Nacos health check timeout after ${max_wait}s" >&2
    print_warn "If you use a proxy, set NO_PROXY=localhost,127.0.0.1 and retry." >&2
    return 1
}

# ============================================================================
# Password Management
# ============================================================================

# Initialize admin password via API
# Parameters: main_port, console_port, nacos_version, password
# Returns: 0 on success, 1 on failure
initialize_admin_password() {
    local main_port=$1
    local console_port=$2
    local nacos_version=$3
    local password=$4
    
    # Skip if password is empty or default
    if [ -z "$password" ] || [ "$password" = "nacos" ]; then
        return 0
    fi
    
    local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
    local api_url
    
    # Determine password change API based on Nacos version
    if [ "$nacos_major" -ge 3 ]; then
        api_url="http://localhost:${console_port}/v3/auth/user/admin"
    else
        api_url="http://localhost:${main_port}/nacos/v1/auth/users/admin"
    fi
    
    print_detail "Initializing admin password..."
    
    # Call the password change API
    local response
    response=$(curl -w "\nHTTP_CODE:%{http_code}" -s -X POST "$api_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "password=${password}" 2>&1)
    
    # Extract HTTP code and body
    local body=$(echo "$response" | sed '/HTTP_CODE:/d')
    
    # Check if response is successful
    if echo "$body" | grep -q '"username"'; then
        print_detail "Admin password initialized successfully"
        return 0
    else
        print_warn "Failed to initialize password automatically"
        return 1
    fi
}

# ============================================================================
# Process Startup
# ============================================================================

# Start Nacos process
# Parameters: install_dir, mode (standalone/cluster), use_derby (true/false)
# Returns: PID on success, empty on failure
start_nacos_process() {
    local install_dir=$1
    local mode=$2
    local use_derby=${3:-true}
    
    if [ ! -d "$install_dir" ]; then
        print_error "Installation directory not found: $install_dir"
        return 1
    fi
    
    cd "$install_dir"
    
    # Get Java runtime options for JDK 9+
    local java_opts=$(get_java_runtime_options)
    
    if [ -n "$java_opts" ]; then
        export JAVA_OPT="$java_opts"
    fi

    # Ensure startup uses the validated Java from check_java_requirements.
    if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
        export PATH="${JAVA_HOME}/bin:${PATH}"
    fi

    # Start Nacos
    local startup_log="$install_dir/logs/nacos-setup-startup.log"
    mkdir -p "$install_dir/logs" 2>/dev/null || true
    _pm_debug "Starting Nacos mode=${mode}, use_derby=${use_derby}, install_dir=${install_dir}"
    _pm_debug "Startup log: ${startup_log}"

    if [ "$use_derby" = true ] && [ "$mode" = "cluster" ]; then
        bash "$install_dir/bin/startup.sh" -m "$mode" -p embedded >"$startup_log" 2>&1
    else
        bash "$install_dir/bin/startup.sh" -m "$mode" >"$startup_log" 2>&1
    fi
    
    # Clear JAVA_OPT after starting
    unset JAVA_OPT
    
    # Try to find the PID (may take a moment for process to bind to port)
    local pid=""
    local retry_count=0
    local max_retries=10
    
    while [ $retry_count -lt $max_retries ]; do
        sleep 1
        pid=$(ps aux | grep "java" | grep "$install_dir" | grep -v grep | awk '{print $2}' | head -1)
        if [ -z "$pid" ]; then
            # Windows Git Bash often reports Windows path in java cmdline; fallback match by "nacos"
            pid=$(ps aux | grep -i "java" | grep -i "nacos" | grep -v grep | awk '{print $2}' | head -1)
        fi
        
        if [ -n "$pid" ] && ps -p $pid >/dev/null 2>&1; then
            _pm_debug "Detected Nacos PID: $pid"
            echo "$pid"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
    done
    
    # Could not determine PID
    _pm_debug "Could not determine PID after ${max_retries}s. Recent startup log:"
    if [ -f "$startup_log" ]; then
        tail -n 80 "$startup_log" >&2 || true
    fi
    echo ""
    return 1
}

# ============================================================================
# Process Cleanup
# ============================================================================

# Stop Nacos process (graceful then force)
# Parameters: pid, timeout_seconds
# Returns: 0 on success, 1 on failure
stop_nacos_gracefully() {
    local pid=$1
    local timeout=${2:-10}
    
    if [ -z "$pid" ] || ! ps -p $pid >/dev/null 2>&1; then
        return 0
    fi
    
    # Try graceful shutdown
    kill $pid 2>/dev/null
    
    # Wait for graceful shutdown
    local wait_count=0
    while [ $wait_count -lt $timeout ]; do
        if ! ps -p $pid >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    # Force kill if still running
    kill -9 $pid 2>/dev/null
    sleep 1
    
    ! ps -p $pid >/dev/null 2>&1
}

# ============================================================================
# Browser Integration
# ============================================================================

# Copy password to clipboard (cross-platform)
# Parameters: password
# Returns: 0 on success, 1 on failure
copy_password_to_clipboard() {
    local password=$1
    
    if command -v pbcopy &> /dev/null; then
        # macOS
        if echo -n "$password" | pbcopy 2>/dev/null; then
            return 0
        fi
    elif command -v xclip &> /dev/null; then
        # Linux with X11 (xclip)
        if echo -n "$password" | xclip -selection clipboard 2>/dev/null; then
            return 0
        fi
    elif command -v xsel &> /dev/null; then
        # Linux with X11 (xsel)
        if echo -n "$password" | xsel --clipboard --input 2>/dev/null; then
            return 0
        fi
    elif command -v clip.exe &> /dev/null; then
        # WSL (Windows Subsystem for Linux)
        if echo -n "$password" | clip.exe 2>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

# Open browser to Nacos console (cross-platform)
# Parameters: console_url
# Returns: 0 on success, 1 on failure
open_browser() {
    local console_url=$1
    
    if command -v open &> /dev/null; then
        # macOS
        if open "$console_url" 2>/dev/null; then
            return 0
        fi
    elif command -v xdg-open &> /dev/null; then
        # Linux with X11
        if xdg-open "$console_url" 2>/dev/null; then
            return 0
        fi
    elif command -v wslview &> /dev/null; then
        # WSL (Windows Subsystem for Linux)
        if wslview "$console_url" 2>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

# Print completion info with browser auto-open
# Parameters: install_dir, console_url, server_port, console_port, nacos_version, username, password
print_completion_info() {
    local install_dir=$1
    local console_url=$2
    local server_port=$3
    local console_port=$4
    local nacos_version=$5
    local username=$6
    local password=$7
    
    local nacos_major=$(echo "$nacos_version" | cut -d. -f1)
    
    echo ""
    echo "========================================"
    print_info "Nacos Started Successfully!"
    echo "========================================"
    echo ""
    echo "  Console URL: $console_url"
    echo ""
    if [ "$VERBOSE" = true ]; then
        echo "  Installation: $install_dir"
        echo ""
        print_info "Port allocation:"
        echo "  - Server Port: $server_port"
        echo "  - Client gRPC Port: $((server_port + 1000))"
        echo "  - Server gRPC Port: $((server_port + 1001))"
        echo "  - Raft Port: $((server_port - 1000))"
        if [ "$nacos_major" -ge 3 ]; then
            echo "  - Console Port: $console_port"
        fi
        echo ""
    fi
    
    local clipboard_success=false
    local browser_success=false
    
    # Display authentication info and copy password
    if [ -n "$password" ] && [ "$password" != "nacos" ]; then
        echo "Authentication is enabled. Please login with:"
        echo "  Username: $username"
        echo "  Password: $password"
        echo ""
        
        # Try to copy password to clipboard
        if copy_password_to_clipboard "$password"; then
            clipboard_success=true
            print_info "✓ Password copied to clipboard!"
        fi
    elif [ "$password" = "nacos" ]; then
        echo "Default login credentials:"
        echo "  Username: nacos"
        echo "  Password: nacos"
        echo ""
        print_warn "SECURITY WARNING: Using default password!"
        print_info "Please change the password after login for security"
        echo ""
    else
        # Password is empty - means initialization failed, password was set previously
        echo "Authentication is enabled."
        echo "Please login with your previously set credentials."
        echo ""
        print_info "If you forgot the password, please reset it manually"
        echo ""
    fi
    
    # Try to open browser (only if password copied or using default)
    local should_open_browser=false
    if [ "$password" = "nacos" ] || [ "$clipboard_success" = true ]; then
        should_open_browser=true
    fi
    
    if [ "$should_open_browser" = true ]; then
        # Show countdown before opening browser
        for i in 3 2 1; do
            echo -ne "\r[INFO] Opening console in browser in ${i}s..." >&2
            sleep 1
        done
        
        # Open the browser
        if open_browser "$console_url"; then
            browser_success=true
            echo -e "\r[INFO] Opening console in browser... Done!    " >&2
        else
            echo -e "\r[INFO] Opening console in browser... Failed!  " >&2
        fi
    fi
    
    if [ "$browser_success" = false ]; then
        print_info "Please manually open the console:"
        print_info "  $console_url"
    fi
    
    echo ""
    echo "========================================"
    echo "Perfect !"
    echo "========================================"
}
