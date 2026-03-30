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
    if [ "${NACOS_SETUP_DEBUG:-}" = "true" ] || [ "${NACOS_SETUP_DEBUG:-}" = "1" ]; then
        echo "[DEBUG-PID] $*" >&2
    fi
}

_pm_is_windows_env() {
    case "${OSTYPE:-}" in
        cygwin|msys|win32) return 0 ;;
    esac
    case "$(uname -s 2>/dev/null)" in
        CYGWIN*|MINGW*|MSYS*|Windows_NT) return 0 ;;
        *) return 1 ;;
    esac
}

# Read PID from Nacos PID file or parse from startup log.
_pm_read_nacos_pid() {
    local install_dir=$1
    local startup_log=${2:-}
    local pid=""

    local pid_file
    for pid_file in \
        "$install_dir/logs/nacos_server.pid" \
        "$install_dir/logs/nacos-server.pid" \
        "$install_dir/data/nacos_server.pid"; do
        if [ -f "$pid_file" ]; then
            pid=$(tr -dc '0-9' < "$pid_file" 2>/dev/null)
            _pm_debug "pid_file=$pid_file exists, content='$pid'"
            if [ -n "$pid" ]; then
                printf '%s\n' "$pid"
                return 0
            fi
        fi
    done

    if [ -n "$startup_log" ] && [ -f "$startup_log" ]; then
        local matched_line
        matched_line=$(grep -oEi '(nacos is starting|pid)[[:space:]]*[:=,][[:space:]]*[0-9]+' "$startup_log" 2>/dev/null | tail -1)
        pid=$(echo "$matched_line" | grep -oE '[0-9]+' | tail -1)
        _pm_debug "startup_log=$startup_log matched='$matched_line' pid='$pid'"
        if [ -n "$pid" ]; then
            printf '%s\n' "$pid"
            return 0
        fi
    else
        _pm_debug "startup_log='$startup_log' not found or empty"
    fi

    return 1
}

# Windows-only: find java.exe whose command line contains "nacos".
# Uses PowerShell CIM query or wmic as fallback.
_pm_find_nacos_pid_windows() {
    local install_dir=$1
    local pid=""
    local ps_cmd
    ps_cmd=$(_pm_powershell_cmd || true)
    _pm_debug "find_nacos_pid_windows: ps_cmd='$ps_cmd'"

    if [ -n "$ps_cmd" ]; then
        local win_dir
        win_dir=$(cd "$install_dir" 2>/dev/null && pwd -W 2>/dev/null) || win_dir=""
        local search_term="${win_dir:-nacos}"
        _pm_debug "find_nacos_pid_windows: win_dir='$win_dir' search_term='$search_term'"

        pid=$("$ps_cmd" -NoProfile -Command "
            \$p = Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" -ErrorAction SilentlyContinue |
                  Where-Object { \$_.CommandLine -and \$_.CommandLine -match [regex]::Escape('$search_term') } |
                  Select-Object -First 1 -ExpandProperty ProcessId
            if (\$p) { Write-Output \$p }
        " 2>/dev/null | tr -d '\r' | tail -n 1)
        _pm_debug "find_nacos_pid_windows: powershell_cim result='$pid'"
        if [ -n "$pid" ] && [[ "$pid" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$pid"
            return 0
        fi
    fi

    if command -v wmic >/dev/null 2>&1 || command -v wmic.exe >/dev/null 2>&1; then
        local wmic_cmd
        command -v wmic >/dev/null 2>&1 && wmic_cmd="wmic" || wmic_cmd="wmic.exe"
        _pm_debug "find_nacos_pid_windows: trying wmic_cmd='$wmic_cmd'"
        local wmic_raw
        wmic_raw=$($wmic_cmd process where "Name='java.exe'" get ProcessId,CommandLine 2>/dev/null | tr -d '\r' | grep -i "nacos" | head -3)
        _pm_debug "find_nacos_pid_windows: wmic nacos lines='$(echo "$wmic_raw" | head -2)'"
        pid=$(echo "$wmic_raw" | awk '{print $NF}' | grep -E '^[0-9]+$' | head -1)
        if [ -n "$pid" ] && [[ "$pid" =~ ^[0-9]+$ ]]; then
            _pm_debug "find_nacos_pid_windows: wmic found pid='$pid'"
            printf '%s\n' "$pid"
            return 0
        fi
    else
        _pm_debug "find_nacos_pid_windows: wmic not available"
    fi

    _pm_debug "find_nacos_pid_windows: no pid found"
    return 1
}

# Return first available PowerShell executable name.
_pm_powershell_cmd() {
    local c
    for c in powershell powershell.exe pwsh pwsh.exe; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# Resolve PID by listening TCP port.
# Echo PID on success; return 0 when found.
_pm_get_pid_by_listen_port() {
    local port=$1
    local pid=""

    # Unix-like first
    if command -v lsof >/dev/null 2>&1; then
        pid=$(lsof -Pi :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            _pm_debug "get_pid_by_port($port): lsof found pid='$pid'"
            printf '%s\n' "$pid"
            return 0
        fi
    fi

    # Windows PowerShell (Git Bash / MSYS / Cygwin)
    if _pm_is_windows_env; then
        local ps_cmd
        ps_cmd=$(_pm_powershell_cmd || true)
        if [ -n "$ps_cmd" ]; then
            pid=$("$ps_cmd" -Command "\$c=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty OwningProcess; if (\$c) { Write-Output \$c }" 2>/dev/null | tr -d '\r' | tail -n 1)
            _pm_debug "get_pid_by_port($port): powershell Get-NetTCPConnection result='$pid'"
            if [ -n "$pid" ]; then
                printf '%s\n' "$pid"
                return 0
            fi
        else
            _pm_debug "get_pid_by_port($port): powershell not available"
        fi

        # netstat fallback
        if command -v netstat >/dev/null 2>&1; then
            local netstat_lines
            netstat_lines=$(netstat -ano 2>/dev/null | tr -d '\r' | grep -E "[:.]${port}[[:space:]]" | grep -Ei "LISTEN|LISTENING" | head -3)
            _pm_debug "get_pid_by_port($port): netstat matches='$(echo "$netstat_lines" | head -2)'"
            pid=$(echo "$netstat_lines" | awk '{print $NF}' | grep -E '^[0-9]+$' | head -1)
            _pm_debug "get_pid_by_port($port): netstat parsed pid='$pid'"
            if [ -n "$pid" ]; then
                printf '%s\n' "$pid"
                return 0
            fi
        else
            _pm_debug "get_pid_by_port($port): netstat not available"
        fi
    fi

    return 1
}

# Cross-platform process existence check.
# Returns: 0 running, 1 not running
is_process_running() {
    local pid=$1
    if [ -z "$pid" ]; then
        return 1
    fi
    if ps -p "$pid" >/dev/null 2>&1; then
        _pm_debug "is_running($pid): ps -p OK"
        return 0
    fi
    if _pm_is_windows_env; then
        # tasklist is much faster than PowerShell (~50ms vs ~3s)
        if command -v tasklist >/dev/null 2>&1; then
            local tl_out
            tl_out=$(tasklist //FI "PID eq $pid" //NH 2>/dev/null | tr -d '\r')
            _pm_debug "is_running($pid): tasklist output='$(echo "$tl_out" | head -1)'"
            if [ -n "$tl_out" ] && ! echo "$tl_out" | grep -qi "INFO:"; then
                return 0
            fi
            return 1
        fi
        local ps_cmd
        ps_cmd=$(_pm_powershell_cmd || true)
        if [ -n "$ps_cmd" ]; then
            "$ps_cmd" -NoProfile -Command "if (Get-Process -Id $pid -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >/dev/null 2>&1
            local rc=$?
            _pm_debug "is_running($pid): powershell Get-Process rc=$rc"
            return $rc
        fi
        _pm_debug "is_running($pid): no checker available"
    fi
    return 1
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
    
    while [ $wait_count -lt $max_wait ]; do
        local url

        # 1) strict readiness endpoint(s)
        for url in "${health_urls[@]}"; do
            if curl --noproxy "*" --connect-timeout 2 --max-time 3 -sf "$url" >/dev/null 2>&1; then
                if [ "$VERBOSE" = true ]; then echo -ne "\r\033[K" >&2; fi
                return 0
            fi
        done

        # 2) fallback: service endpoint responds with any HTTP status (not 000)
        for url in "${fallback_urls[@]}"; do
            local code
            code=$(curl --noproxy "*" --connect-timeout 2 --max-time 3 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
            if [ "$code" != "000" ]; then
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
    local -a api_urls=()
    local -a methods=()
    local retries=10
    local i

    if [ "$nacos_major" -ge 3 ]; then
        api_urls=(
            "http://127.0.0.1:${console_port}/v3/auth/user/admin"
            "http://localhost:${console_port}/v3/auth/user/admin"
            "http://127.0.0.1:${console_port}/v3/auth/users/admin"
            "http://localhost:${console_port}/v3/auth/users/admin"
            "http://127.0.0.1:${console_port}/nacos/v3/auth/user/admin"
            "http://localhost:${console_port}/nacos/v3/auth/user/admin"
            "http://127.0.0.1:${console_port}/nacos/v3/auth/users/admin"
            "http://localhost:${console_port}/nacos/v3/auth/users/admin"
        )
        methods=(POST PUT)
    else
        api_urls=(
            "http://127.0.0.1:${main_port}/nacos/v1/auth/users/admin"
            "http://localhost:${main_port}/nacos/v1/auth/users/admin"
        )
        methods=(POST PUT)
    fi

    print_detail "Initializing admin password..."

    for ((i=0; i<retries; i++)); do
        local method url response body http_code
        for method in "${methods[@]}"; do
            for url in "${api_urls[@]}"; do
                response=$(curl --noproxy "*" --connect-timeout 2 --max-time 5 -w "\nHTTP_CODE:%{http_code}" -s -X "$method" "$url" \
                    -H "Content-Type: application/x-www-form-urlencoded" \
                    -d "password=${password}" 2>&1 || true)

                body=$(echo "$response" | sed '/HTTP_CODE:/d')
                http_code=$(echo "$response" | sed -n 's/^HTTP_CODE://p' | tail -n1)

                # Consider success on known successful payloads or generic 2xx.
                if echo "$body" | grep -Eq '"username"|success|\"code\"[[:space:]]*:[[:space:]]*0'; then
                    print_detail "Admin password initialized successfully"
                    return 0
                fi
                if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
                    print_detail "Admin password initialized successfully"
                    return 0
                fi
            done
        done
        sleep 2
    done

    print_warn "Failed to initialize password automatically"
    return 1
}

# ============================================================================
# Process Startup
# ============================================================================

# Start Nacos process
# Parameters: install_dir, mode (standalone/cluster), use_derby (true/false), main_port(optional)
# Returns: PID on success, empty on failure
start_nacos_process() {
    local install_dir=$1
    local mode=$2
    local use_derby=${3:-true}
    local main_port=${4:-}
    
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

    if [ "$use_derby" = true ] && [ "$mode" = "cluster" ]; then
        if _pm_is_windows_env; then
            # Git Bash may block when startup.sh keeps foreground attached.
            ( bash "$install_dir/bin/startup.sh" -m "$mode" -p embedded >"$startup_log" 2>&1 ) &
        else
            bash "$install_dir/bin/startup.sh" -m "$mode" -p embedded >"$startup_log" 2>&1
        fi
    else
        if _pm_is_windows_env; then
            ( bash "$install_dir/bin/startup.sh" -m "$mode" >"$startup_log" 2>&1 ) &
        else
            bash "$install_dir/bin/startup.sh" -m "$mode" >"$startup_log" 2>&1
        fi
    fi
    
    # Clear JAVA_OPT after starting
    unset JAVA_OPT
    
    # Try to find the PID (may take a moment for process to bind to port)
    local pid=""
    local retry_count=0
    local max_retries=40

    _pm_debug "=== start_nacos_process: is_windows=$(_pm_is_windows_env && echo true || echo false) install_dir='$install_dir' main_port='$main_port'"
    _pm_debug "=== OSTYPE='${OSTYPE:-}' uname='$(uname -s 2>/dev/null)'"
    _pm_debug "=== startup_log='$startup_log'"

    while [ $retry_count -lt $max_retries ]; do
        sleep 1
        pid=""

        # Method 1: Nacos PID file or startup log (fast, cross-platform)
        pid=$(_pm_read_nacos_pid "$install_dir" "$startup_log" || true)

        if _pm_is_windows_env; then
            # Method 2 (Windows): PowerShell/wmic process query (throttled to every 5s)
            if [ -z "$pid" ] && [ $((retry_count % 5)) -eq 3 ]; then
                _pm_debug "[${retry_count}s] trying _pm_find_nacos_pid_windows..."
                pid=$(_pm_find_nacos_pid_windows "$install_dir" || true)
            fi
            # Method 3 (Windows): Port-based detection via netstat/PowerShell
            if [ -z "$pid" ] && [ -n "$main_port" ]; then
                pid=$(_pm_get_pid_by_listen_port "$main_port" || true)
            fi
        else
            # Method 2 (Unix): ps-based detection
            if [ -z "$pid" ]; then
                pid=$(ps aux 2>/dev/null | grep "java" | grep "$install_dir" | grep -v grep | awk '{print $2}' | head -1)
            fi
            if [ -z "$pid" ]; then
                pid=$(ps aux 2>/dev/null | grep -i "java" | grep -i "nacos" | grep -v grep | awk '{print $2}' | head -1)
            fi
            # Method 3 (Unix): Port-based detection
            if [ -z "$pid" ] && [ -n "$main_port" ]; then
                pid=$(_pm_get_pid_by_listen_port "$main_port" || true)
            fi
        fi

        if [ -n "$pid" ]; then
            _pm_debug "[${retry_count}s] candidate pid='$pid', checking is_process_running..."
            if is_process_running "$pid"; then
                _pm_debug "[${retry_count}s] SUCCESS pid='$pid' is running"
                echo "$pid"
                return 0
            else
                _pm_debug "[${retry_count}s] pid='$pid' is NOT running, will retry"
            fi
        fi

        retry_count=$((retry_count + 1))
    done

    # Could not determine PID
    if [ "$VERBOSE" = true ] && [ -f "$startup_log" ]; then
        print_warn "Could not determine Nacos PID after ${max_retries}s. Startup log: $startup_log" >&2
    fi
    echo ""
    return 1
}

# Detect Nacos PID after the service is confirmed reachable.
# Useful as a fallback when start_nacos_process couldn't resolve the PID
# within its retry window but the health check later succeeded.
# Parameters: install_dir, main_port, startup_log (optional)
detect_nacos_pid() {
    local install_dir=$1
    local main_port=${2:-}
    local startup_log=${3:-$install_dir/logs/nacos-setup-startup.log}
    local pid=""

    _pm_debug "=== detect_nacos_pid (post-ready fallback): port='$main_port'"

    pid=$(_pm_read_nacos_pid "$install_dir" "$startup_log" || true)

    if [ -z "$pid" ] && [ -n "$main_port" ]; then
        _pm_debug "detect_nacos_pid: trying port-based detection..."
        pid=$(_pm_get_pid_by_listen_port "$main_port" || true)
    fi

    if [ -z "$pid" ] && _pm_is_windows_env; then
        _pm_debug "detect_nacos_pid: trying windows process search..."
        pid=$(_pm_find_nacos_pid_windows "$install_dir" || true)
    fi

    _pm_debug "detect_nacos_pid: final pid='$pid'"
    if [ -n "$pid" ] && is_process_running "$pid"; then
        printf '%s\n' "$pid"
        return 0
    fi
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
    
    if [ -z "$pid" ] || ! is_process_running "$pid"; then
        return 0
    fi
    
    # Try graceful shutdown
    if _pm_is_windows_env && command -v taskkill >/dev/null 2>&1; then
        taskkill //PID "$pid" >/dev/null 2>&1 || true
    else
        kill "$pid" 2>/dev/null || true
    fi
    
    # Wait for graceful shutdown
    local wait_count=0
    while [ $wait_count -lt $timeout ]; do
        if ! is_process_running "$pid"; then
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    # Force kill if still running
    if _pm_is_windows_env && command -v taskkill >/dev/null 2>&1; then
        taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true
    else
        kill -9 "$pid" 2>/dev/null || true
    fi
    sleep 1
    
    ! is_process_running "$pid"
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
