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

# Common Utilities Library
# Shared functions used by both standalone and cluster modes

# ============================================================================
# Color Output
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Bash entrypoints (nacos-setup.sh, nacos-installer.sh) support Linux and macOS only.
# Windows: use windows/nacos-installer.ps1 and windows/nacos-setup.ps1.
nacos_setup_require_unix_os() {
    local win=0
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) win=1 ;;
    esac
    if [ "$win" -eq 0 ]; then
        case "$(uname -s 2>/dev/null)" in
            CYGWIN*|MINGW*|MSYS*|Windows_NT) win=1 ;;
        esac
    fi
    if [ "$win" -eq 1 ]; then
        print_error "This script does not support Windows. Use PowerShell instead:"
        echo ""
        echo "  iwr -UseBasicParsing https://nacos.io/nacos-installer.ps1 | iex"
        echo ""
        exit 1
    fi
}

# ============================================================================
# Verbose Output Control
# ============================================================================

VERBOSE="${VERBOSE:-false}"

print_detail() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}[INFO]${NC} $1"
    fi
}

print_step() {
    local current=$1 total=$2 desc=$3 result="${4:-}"
    if [ -n "$result" ]; then
        echo -e "${GREEN}[${current}/${total}]${NC} ${desc} ${GREEN}✓${NC} ${result}"
    else
        echo -e "${GREEN}[${current}/${total}]${NC} ${desc} ${GREEN}✓${NC}"
    fi
}

print_step_fail() {
    local current=$1 total=$2 desc=$3 result="${4:-failed}"
    echo -e "${RED}[${current}/${total}]${NC} ${desc} ${RED}✗${NC} ${result}"
}

# ============================================================================
# Simple UI: in-progress step line (non-verbose only)
# Shows [n/t] description with an indeterminate ASCII bar until step_simple_clear.
# With -x/--verbose, these are no-ops; use print_detail for diagnostics.
# ============================================================================

STEP_SIMPLE_SPINNER_PID=""

step_simple_clear() {
    if [ -n "${STEP_SIMPLE_SPINNER_PID:-}" ]; then
        kill "$STEP_SIMPLE_SPINNER_PID" 2>/dev/null || true
        wait "$STEP_SIMPLE_SPINNER_PID" 2>/dev/null || true
        STEP_SIMPLE_SPINNER_PID=""
        if [ "${VERBOSE:-false}" != true ]; then
            printf '\r\033[K'
        fi
    fi
}

# Start animated progress line on stdout (same stream as print_step; safe while
# command substitutions only capture a child process's stdout).
# Args: current total description
step_simple_begin() {
    local cur=$1
    local tot=$2
    local desc="$3"
    if [ "${VERBOSE:-false}" = true ]; then
        return 0
    fi
    step_simple_clear
    (
        # Detect fractional sleep support (busybox/Alpine may only accept integers).
        local sleep_interval=0.09
        if ! sleep 0.01 2>/dev/null; then
            sleep_interval=1
        fi
        local i=0
        local w=10
        while true; do
            local pos=$((i % (w + 1)))
            local bar=""
            local j
            for ((j = 0; j < w; j++)); do
                if [ "$j" -eq "$pos" ]; then
                    bar+="="
                else
                    bar+="-"
                fi
            done
            printf "\r\033[K${GREEN}[%s/%s]${NC} %s  [%s]" "$cur" "$tot" "$desc" "$bar"
            i=$((i + 1))
            sleep $sleep_interval
        done
    ) &
    STEP_SIMPLE_SPINNER_PID=$!
}

# Stop simple-mode spinner; optional newline so prompts are not drawn on the spinner line.
nacos_setup_pause_simple_ui() {
    if declare -F step_simple_clear >/dev/null 2>&1; then
        step_simple_clear 2>/dev/null || true
    fi
    if [ "${VERBOSE:-false}" != true ]; then
        printf '\n' 2>/dev/null || true
    fi
}

# Read one line for Y/n flows. Prefers /dev/tty for stdin and stderr so prompts stay visible
# when stdin is a pipe and are not hidden behind the simple-mode stdout spinner. Sets REPLY.
# Returns 0 on success, 2 if no interactive input is possible.
nacos_setup_read_prompt() {
    local prompt="$1"
    nacos_setup_pause_simple_ui
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf '\n' >/dev/tty 2>/dev/null || true
        IFS= read -r -p "$prompt" REPLY </dev/tty 2>/dev/tty || return 2
        return 0
    fi
    if [ -t 0 ]; then
        printf '\n' || true
        IFS= read -r -p "$prompt" REPLY || return 2
        return 0
    fi
    return 2
}

# ============================================================================
# Version Comparison
# ============================================================================

# Compare version numbers (returns 0 if v1 >= v2, 1 otherwise)
version_ge() {
    local v1=$1
    local v2=$2
    local clean_v1 clean_v2

    # Strip non-numeric suffixes like -BETA so prerelease versions remain comparable.
    clean_v1=$(echo "$v1" | sed 's/[^0-9.].*$//')
    clean_v2=$(echo "$v2" | sed 's/[^0-9.].*$//')
    
    # Split versions into arrays
    IFS='.' read -ra V1 <<< "${clean_v1:-0}"
    IFS='.' read -ra V2 <<< "${clean_v2:-0}"
    
    # Compare each component
    for i in 0 1 2; do
        local num1=${V1[$i]:-0}
        local num2=${V2[$i]:-0}
        
        if [ "$num1" -gt "$num2" ]; then
            return 0  # v1 > v2
        elif [ "$num1" -lt "$num2" ]; then
            return 1  # v1 < v2
        fi
        # If equal, continue to next component
    done
    
    return 0  # v1 == v2
}

# ============================================================================
# Security Key Generation
# ============================================================================

# Generate secret key (Base64 encoded random string)
generate_secret_key() {
    openssl rand -base64 32 2>/dev/null || echo "U2VjdXJlUmFuZG9tS2V5Rm9yTmFjb3NBdXRoVG9rZW4xMjM0NTY3ODkw"
}

# Generate password (alphanumeric, 12-16 characters)
generate_password() {
    local password=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 12)
    if [ -z "$password" ]; then
        password="Nacos$(date +%s | tail -c 6)"
    fi
    echo "$password"
}

# ============================================================================
# OS Detection
# ============================================================================

detect_os_arch() {
    local os_type="unknown"
    
    case "$(uname -s)" in
        Linux*)
            os_type="linux"
            ;;
        Darwin*)
            os_type="macos"
            ;;
    esac
    
    echo "$os_type"
}

# ============================================================================
# IP Address Detection
# ============================================================================

# Get first non-localhost IP address
get_local_ip() {
    local ip=""
    local os_type=$(detect_os_arch)
    
    case "$os_type" in
        macos)
            # Try ipconfig first (macOS native), then fallback to ifconfig
            ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ipconfig getifaddr en2 2>/dev/null)
            if [ -z "$ip" ] && command -v ifconfig &> /dev/null; then
                ip=$(ifconfig | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
            fi
            ;;
        linux)
            if command -v ip &> /dev/null; then
                ip=$(ip -4 addr show | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d'/' -f1 | head -1)
            elif command -v ifconfig &> /dev/null; then
                ip=$(ifconfig | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
            fi
            ;;
        *)
            if command -v ifconfig &> /dev/null; then
                ip=$(ifconfig | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
            fi
            ;;
    esac
    
    # Fallback to 127.0.0.1 if no IP found
    if [ -z "$ip" ]; then
        ip="127.0.0.1"
        print_warn "Could not detect non-localhost IP, using 127.0.0.1" >&2
    fi
    
    echo "$ip"
}

# ============================================================================
# Java Detection
# ============================================================================

# Check if the given path is macOS Java stub (not a real Java installation)
# macOS stub is small and located at /usr/bin/java
is_macos_java_stub() {
    local java_path=$1
    # Check if it's the macOS stub at /usr/bin/java
    if [ "$java_path" = "/usr/bin/java" ]; then
        # Check file size - macOS stub is typically < 100KB, real java is larger
        local file_size
        file_size=$(stat -f%z "$java_path" 2>/dev/null || stat -c%s "$java_path" 2>/dev/null || echo "0")
        if [ "$file_size" -lt 200000 ]; then
            return 0  # It's a stub
        fi
    fi
    return 1  # Not a stub
}

# Get Java version from java command
get_java_version() {
    local java_cmd=$1
    
    # Check if it's macOS stub first
    local java_path
    if [[ "$java_cmd" = /* ]]; then
        java_path="$java_cmd"
    else
        java_path=$(command -v "$java_cmd" 2>/dev/null || echo "")
    fi
    
    if [ -n "$java_path" ] && is_macos_java_stub "$java_path"; then
        echo "0"
        return
    fi
    
    # Use timeout to prevent hanging on macOS stub (5 seconds should be enough)
    local version
    if command -v timeout >/dev/null 2>&1; then
        version=$(timeout 5 $java_cmd -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')
    elif command -v gtimeout >/dev/null 2>&1; then
        version=$(gtimeout 5 $java_cmd -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')
    else
        version=$($java_cmd -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')
    fi
    
    # Handle Java version format like "1.8.0" -> extract "8"
    if [ -z "$version" ]; then
        if command -v timeout >/dev/null 2>&1; then
            version=$(timeout 5 $java_cmd -version 2>&1 | head -1 | sed -n 's/.*version "1\.\([0-9]*\).*/\1/p')
        elif command -v gtimeout >/dev/null 2>&1; then
            version=$(gtimeout 5 $java_cmd -version 2>&1 | head -1 | sed -n 's/.*version "1\.\([0-9]*\).*/\1/p')
        else
            version=$($java_cmd -version 2>&1 | head -1 | sed -n 's/.*version "1\.\([0-9]*\).*/\1/p')
        fi
    fi
    
    echo "${version:-0}"
}

# Get Java search paths based on OS
get_java_search_paths() {
    local os_type=$1
    local paths=()
    
    case "$os_type" in
        linux)
            paths=(
                "/usr/lib/jvm"
                "/usr/java"
                "/opt/java"
                "/opt/jdk"
                "$HOME/.sdkman/candidates/java"
                "$HOME/.jenv/versions"
            )
            ;;
        macos)
            paths=(
                "/Library/Java/JavaVirtualMachines"
                "/System/Library/Frameworks/JavaVM.framework"
                "$HOME/.sdkman/candidates/java"
                "$HOME/.jenv/versions"
            )
            ;;
        *)
            paths=(
                "/usr/lib/jvm"
                "/usr/java"
                "/opt/java"
                "/Library/Java/JavaVirtualMachines"
            )
            ;;
    esac
    
    printf '%s\n' "${paths[@]}"
}

# ============================================================================
# Configuration Management
# ============================================================================

# Backup a configuration file before modification
# Parameters: config_file
# Returns: 0 on success, 1 on failure
backup_config_file() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        return 0  # Nothing to backup
    fi
    
    local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    if cp "$config_file" "$backup_file" 2>/dev/null; then
        print_detail "Config backed up to: $backup_file" >&2
        return 0
    else
        print_warn "Failed to create backup of: $config_file" >&2
        return 1
    fi
}

# Update or add a property in configuration file
update_config_property() {
    local config_file=$1
    local property_key=$2
    local property_value=$3
    
    if [ ! -f "$config_file" ]; then
        echo "[ERROR] Config file does not exist: $config_file" >&2
        return 1
    fi
    
    if grep -q "^${property_key}=" "$config_file" 2>/dev/null; then
        sed -i.bak "s|^${property_key}=.*|${property_key}=${property_value}|" "$config_file"
    elif grep -q "^#${property_key}=" "$config_file" 2>/dev/null; then
        sed -i.bak "s|^#${property_key}=.*|${property_key}=${property_value}|" "$config_file"
    else
        # Ensure file ends with newline before appending
        if [ -s "$config_file" ] && [ "$(tail -c 1 "$config_file" | wc -l)" -eq 0 ]; then
            echo "" >> "$config_file"
        fi
        echo "${property_key}=${property_value}" >> "$config_file"
    fi
}

# ============================================================================
# System Commands Check
# ============================================================================

check_system_commands() {
    print_detail "Checking required system commands..."
    
    local missing_commands=()
    local optional_missing=()
    
    # Essential commands
    local required_commands=("curl" "unzip" "grep" "sed")
    
    # Optional commands
    local optional_commands=("lsof" "ps" "kill")
    
    # Check required commands
    for cmd in "${required_commands[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    # Check optional commands
    for cmd in "${optional_commands[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            optional_missing+=("$cmd")
        fi
    done
    
    # Report missing required commands
    if [ ${#missing_commands[@]} -gt 0 ]; then
        print_error "Missing required commands: ${missing_commands[*]}"
        echo ""
        print_info "Please install them first"
        
        local os_type=$(detect_os_arch)
        case "$os_type" in
            linux)
                print_info "Ubuntu/Debian: sudo apt-get install -y ${missing_commands[*]}"
                print_info "CentOS/RHEL: sudo yum install -y ${missing_commands[*]}"
                ;;
            macos)
                print_info "macOS: brew install ${missing_commands[*]}"
                ;;
        esac
        
        echo ""
        return 1
    fi
    
    # Optional tools (lsof, etc.): only mention in verbose / advanced UX to keep simple install quiet.
    if [ ${#optional_missing[@]} -gt 0 ] && [ "${VERBOSE:-false}" = true ]; then
        print_warn "Optional commands not found: ${optional_missing[*]}"
        print_info "Some features may be limited (port detection, process management)"
        echo ""
    fi
    
    print_detail "All required commands are available"
    return 0
}
