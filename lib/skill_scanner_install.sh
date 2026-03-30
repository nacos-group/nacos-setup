#!/bin/bash

# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Optional Cisco skill-scanner (https://github.com/cisco-ai-defense/skill-scanner)
# PyPI: cisco-ai-skill-scanner — requires Python 3.10+ and uv.
# Interactive (Y/n): (1) skill-scanner stack, (2) uv bootstrap when missing, (3) uv python 3.10 when missing.
# stdin may be a pipe (curl | bash): prompt is read from /dev/tty when available; no usable TTY skips.
# After Y: missing uv is bootstrapped via install.sh (curl/wget/fetch, else Python urllib / ruby / node); missing Python 3.10+ uses `uv python install 3.10`.
# Simple UI (VERBOSE not true): installer uses UV_PRINT_QUIET; uv uses UV_NO_PROGRESS, -q/-qq, and stdout/stderr discarded where safe so progress spinners do not flood the console.

SKILL_SCANNER_PYPI_PACKAGE="cisco-ai-skill-scanner"
MIN_NACOS_VERSION_FOR_SKILL_SCANNER="3.2.0"
_SKILL_SCANNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SCANNER_VENV_PATH_RELATIVE="ai-infra/.venv"
SKILL_SCANNER_INSTALLED="false"

# Git Bash / MSYS / Cygwin: venv uses Scripts/*.exe, not bin/python.
_skill_scanner_is_windows_env() {
    case "${OSTYPE:-}" in
        cygwin | msys) return 0 ;;
    esac
    case "$(uname -s 2>/dev/null)" in
        CYGWIN* | MINGW* | MSYS*) return 0 ;;
        *) return 1 ;;
    esac
}

# Directory containing venv console_scripts / python (bin vs Scripts).
_skill_scanner_venv_scripts_dir() {
    local venv_dir="$1"
    if _skill_scanner_is_windows_env; then
        printf '%s\n' "${venv_dir}/Scripts"
    else
        printf '%s\n' "${venv_dir}/bin"
    fi
}

# Path to the venv Python interpreter for uv/pip --python.
_skill_scanner_venv_python_path() {
    local venv_dir="$1"
    if _skill_scanner_is_windows_env; then
        printf '%s\n' "${venv_dir}/Scripts/python.exe"
    else
        printf '%s\n' "${venv_dir}/bin/python"
    fi
}

# Path to skill-scanner CLI inside the venv (if installed).
_skill_scanner_venv_skill_scanner_path() {
    local venv_dir="$1"
    if _skill_scanner_is_windows_env; then
        printf '%s\n' "${venv_dir}/Scripts/skill-scanner.exe"
    else
        printf '%s\n' "${venv_dir}/bin/skill-scanner"
    fi
}

# True if venv python exists (executable or regular file on Windows .exe).
_skill_scanner_venv_python_exists() {
    local p="$1"
    [ -z "$p" ] && return 1
    [ -x "$p" ] && return 0
    _skill_scanner_is_windows_env && [ -f "$p" ] && return 0
    return 1
}

# Nacos on Windows uses JVM + ProcessBuilder; prefer C:/... (cygpath -m) for properties and exec.
_skill_scanner_path_for_nacos_server() {
    local p="$1"
    local win_dir base w
    [ -z "$p" ] && return 0
    if ! _skill_scanner_is_windows_env; then
        printf '%s\n' "$p"
        return 0
    fi
    if command -v cygpath >/dev/null 2>&1; then
        w=$(cygpath -m "$p" 2>/dev/null) || w=""
        if [ -n "$w" ]; then
            printf '%s\n' "$w"
            return 0
        fi
        w=$(cygpath -aw "$p" 2>/dev/null) || w=""
        if [ -n "$w" ]; then
            printf '%s\n' "$w"
            return 0
        fi
    fi
    case "$p" in
        /*)
            base=$(basename "$p")
            win_dir=$(cd "$(dirname "$p")" 2>/dev/null && pwd -W 2>/dev/null) || win_dir=""
            if [ -n "$win_dir" ] && [ -n "$base" ]; then
                printf '%s\n' "${win_dir}/${base}"
                return 0
            fi
            ;;
    esac
    printf '%s\n' "$p"
    return 0
}

# After maybe_install: write plugin config if stack was installed OR a scanner binary is already discoverable.
_skill_scanner_should_write_plugin_config() {
    if [ "${NACOS_SETUP_SKIP_SKILL_SCANNER:-}" = "1" ] || [ "${NACOS_SETUP_SKIP_SKILL_SCANNER:-}" = "true" ]; then
        return 1
    fi
    if ! declare -F version_ge >/dev/null 2>&1; then
        return 1
    fi
    if ! version_ge "${VERSION:-0}" "$MIN_NACOS_VERSION_FOR_SKILL_SCANNER"; then
        return 1
    fi
    if [ "$SKILL_SCANNER_INSTALLED" = "true" ]; then
        return 0
    fi
    if [ -n "$(_get_skill_scanner_command_path 2>/dev/null || true)" ]; then
        return 0
    fi
    return 1
}

# Always write to stderr (no ANSI); survives logging pipelines.
_skill_scanner_trace() {
    if [ "${VERBOSE:-false}" = true ]; then
        printf '%s\n' "[nacos-setup/skill-scanner] $*" >&2
    fi
}

# Simple UI (step_simple_*): suppress uv/installer progress bars and package spinners.
_skill_scanner_uv_use_quiet_output() {
    [ "${VERBOSE:-false}" != true ]
}

# Add skill-scanner to PATH if installed via pip/uv but not in PATH
# This is idempotent - safe to call multiple times
_ensure_skill_scanner_in_path() {
    # If already in PATH, nothing to do
    if command -v skill-scanner >/dev/null 2>&1; then
        return 0
    fi
    
    # Check common Python bin directories for skill-scanner
    local py_dirs=""
    
    # Add pyenv Python directories if available
    local pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"
    if [ -d "$pyenv_root/versions" ]; then
        for ver_dir in "$pyenv_root/versions"/*/bin; do
            if [ -d "$ver_dir" ]; then
                py_dirs="$py_dirs $ver_dir"
            fi
        done
    fi
    
    # Add common Python installation paths
    py_dirs="$py_dirs /usr/local/bin /opt/homebrew/bin /usr/bin"
    
    # Check each potential bin directory
    for bin_dir in $py_dirs; do
        if [ -x "$bin_dir/skill-scanner" ]; then
            export PATH="$bin_dir:$PATH"
            _skill_scanner_trace "added $bin_dir to PATH for skill-scanner"
            return 0
        fi
    done
    
    # Also check user's local bin (pip --user install location)
    local user_bin="$HOME/.local/bin"
    if [ -x "$user_bin/skill-scanner" ]; then
        export PATH="$user_bin:$PATH"
        _skill_scanner_trace "added $user_bin to PATH for skill-scanner"
        return 0
    fi
    
    return 1
}

# Return the actual path to the skill-scanner executable.
# Prefers the venv bin path; falls back to command -v.
_get_skill_scanner_command_path() {
    local venv_dir scanner
    venv_dir=$(_skill_scanner_venv_dir_for_user 2>/dev/null || true)
    if [ -n "$venv_dir" ]; then
        scanner=$(_skill_scanner_venv_skill_scanner_path "$venv_dir")
        if [ -x "$scanner" ] || { _skill_scanner_is_windows_env && [ -f "$scanner" ]; }; then
            printf '%s\n' "$scanner"
            return 0
        fi
    fi
    command -v skill-scanner 2>/dev/null
}

# Configure skill-scanner plugin properties in application.properties
# Parameters: config_file
configure_skill_scanner_properties() {
    local config_file="$1"
    
    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        _skill_scanner_trace "skip: application.properties not found (config_file=${config_file:-unset})"
        return 1
    fi
    
    print_detail "Configuring skill-scanner plugin properties in ${config_file}"

    update_config_property "$config_file" "nacos.plugin.ai-pipeline.enabled" "true"
    update_config_property "$config_file" "nacos.plugin.ai-pipeline.type" "skill-scanner"
    update_config_property "$config_file" "nacos.plugin.ai-pipeline.skill-scanner.enabled" "true"

    local scanner_cmd
    scanner_cmd=$(_get_skill_scanner_command_path || true)
    if [ -n "$scanner_cmd" ]; then
        scanner_cmd=$(_skill_scanner_path_for_nacos_server "$scanner_cmd")
        update_config_property "$config_file" "nacos.plugin.ai-pipeline.skill-scanner.command" "$scanner_cmd"
    fi

    print_detail "skill-scanner plugin properties configured successfully"
}

# Entry from standalone.sh / cluster.sh after application.properties is written.
run_post_nacos_config_skill_scanner_hook() {
    _skill_scanner_trace "hook invoked (VERSION=${VERSION:-unset}, lib_dir=${_SKILL_SCANNER_LIB_DIR})"
    if declare -F post_nacos_config_hook >/dev/null 2>&1; then
        post_nacos_config_hook
        return $?
    fi
    if declare -F maybe_install_skill_scanner_for_nacos >/dev/null 2>&1; then
        maybe_install_skill_scanner_for_nacos "$VERSION"
        return $?
    fi
    _skill_scanner_trace "no post_nacos_config_hook and no maybe_install_skill_scanner_for_nacos (broken or partial install)"
    return 0
}

# Run the given command directly (no privilege changes).
_skill_scanner_runas_target_user() {
    "$@"
}

_skill_scanner_uv_on_path() {
    _skill_scanner_runas_target_user bash -c 'command -v uv >/dev/null 2>&1'
}

# True if we can download HTTPS to stdout (curl, wget, fetch, Python, ruby, or node).
_skill_scanner_have_url_fetch_tool() {
    command -v curl >/dev/null 2>&1 && return 0
    command -v wget >/dev/null 2>&1 && return 0
    command -v fetch >/dev/null 2>&1 && return 0
    local py
    for py in python3 python python2.7 python2; do
        command -v "$py" >/dev/null 2>&1 && return 0
    done
    command -v ruby >/dev/null 2>&1 && return 0
    command -v node >/dev/null 2>&1 && return 0
    return 1
}

# Run official uv install.sh in the target user environment (same shell as nacos-setup).
# Prefers curl → wget → fetch (BSD) → Python urllib → ruby open-uri → node https.
_skill_scanner_run_uv_install_sh() {
    local quiet_install="${1:-0}"
    _skill_scanner_runas_target_user bash -c "
        set -eo pipefail
        url=\"\$1\"
        quiet=\"\$2\"
        if [ \"\$quiet\" = 1 ]; then
            export UV_PRINT_QUIET=1
        fi
        if command -v curl >/dev/null 2>&1; then
            curl -LsSf \"\$url\" | sh
        elif command -v wget >/dev/null 2>&1; then
            wget -qO- \"\$url\" | sh
        elif command -v fetch >/dev/null 2>&1; then
            fetch -q -o - \"\$url\" | sh
        else
            pyexe=\"\"
            for py in python3 python python2.7 python2; do
                if command -v \"\$py\" >/dev/null 2>&1; then
                    pyexe=\"\$py\"
                    break
                fi
            done
            if [ -n \"\$pyexe\" ]; then
                \"\$pyexe\" -c \"
import sys
url = sys.argv[1]
try:
    from urllib.request import urlopen
except ImportError:
    from urllib2 import urlopen
data = urlopen(url).read()
if sys.version_info[0] >= 3:
    sys.stdout.buffer.write(data)
else:
    sys.stdout.write(data)
\" \"\$url\" | sh
            elif command -v ruby >/dev/null 2>&1; then
                export url
                ruby -e 'require \"open-uri\"; print URI.open(ENV[\"url\"]).read' | sh
            elif command -v node >/dev/null 2>&1; then
                node -e \"require('https').get(process.argv[1], function(r) { if (r.statusCode !== 200) process.exit(1); var d = []; r.on('data', function(c) { d.push(c); }); r.on('end', function() { process.stdout.write(Buffer.concat(d)); }); }).on('error', function() { process.exit(1); });\" \"\$url\" | sh
            else
                echo \"nacos-setup: need curl, wget, fetch, Python, ruby, or node to download uv installer\" >&2
                exit 1
            fi
        fi
    " _ "https://astral.sh/uv/install.sh" "$quiet_install"
}

# Prepend a directory to PATH in this shell if it exists and is not already present.
_skill_scanner_prepend_path_dir() {
    local d="$1"
    [ -n "$d" ] && [ -d "$d" ] || return 0
    case ":${PATH}:" in
        *":${d}:"*) ;;
        *) export PATH="${d}:${PATH}" ;;
    esac
}

# Ensure common install locations are visible after `uv/install.sh` (typically ~/.local/bin).
_skill_scanner_refresh_path_for_uv() {
    local home
    home=$(_skill_scanner_runas_target_user bash -c 'printf %s "$HOME"')
    _skill_scanner_prepend_path_dir "${home}/.local/bin"
    _skill_scanner_prepend_path_dir "${home}/.cargo/bin"
}

# Install Astral uv via official installer when missing. Updates PATH in the current process on success.
_skill_scanner_bootstrap_uv() {
    if _skill_scanner_uv_on_path; then
        return 0
    fi
    if ! _skill_scanner_have_url_fetch_tool; then
        print_warn "Cannot auto-install uv: need curl, wget, fetch, Python, ruby, or node on PATH."
        return 1
    fi
    if ! _confirm_uv_bootstrap_interactive; then
        print_info "Skipping uv download/install."
        return 1
    fi
    print_info "Installing uv (https://astral.sh/uv/) via official install script..."
    # Non-interactive-friendly; installs to ~/.local/bin by default on Unix.
    local q=0
    _skill_scanner_uv_use_quiet_output && q=1
    if ! _skill_scanner_run_uv_install_sh "$q"; then
        print_warn "Automatic uv installation failed. Install manually: https://docs.astral.sh/uv/getting-started/installation/"
        return 1
    fi
    _skill_scanner_refresh_path_for_uv
    if ! _skill_scanner_uv_on_path; then
        print_warn "uv was installed but is not on PATH in this session. Open a new terminal or add ~/.local/bin to PATH."
        return 1
    fi
    print_info "uv is available: $(_skill_scanner_runas_target_user bash -c 'command -v uv')"
    return 0
}

_find_python_310_plus() {
    local out
    if ! out=$(_skill_scanner_runas_target_user bash -c '
        for c in python3.13 python3.12 python3.11 python3.10 python3; do
            if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then
                command -v "$c"
                exit 0
            fi
        done
        exit 1
    ' 2>/dev/null); then
        return 1
    fi
    echo "$out" | tail -n 1
}

_ensure_python_310_plus_with_uv() {
    local py_exe=$(_find_python_310_plus || true)
    if [ -n "$py_exe" ]; then
        printf '%s\n' "$py_exe"
        return 0
    fi

    # Fallback: uv-managed Python when system Python is missing or < 3.10.
    # Prompts / status on stderr only: caller uses py_exe=$(this_func) and stdout must be the interpreter path.
    print_info "No Python 3.10+ on PATH; uv can install Python 3.10." >&2
    if ! _confirm_uv_python310_interactive; then
        print_info "Skipping uv-managed Python 3.10." >&2
        return 1
    fi
    print_info "Installing Python 3.10 with uv..." >&2
    local py_install_ok=0
    if _skill_scanner_uv_use_quiet_output; then
        if _skill_scanner_runas_target_user env UV_NO_PROGRESS=1 uv -q python install 3.10 >/dev/null 2>&1; then
            py_install_ok=1
        fi
    else
        if _skill_scanner_runas_target_user uv python install 3.10 >&2; then
            py_install_ok=1
        fi
    fi
    py_exe=""
    if [ "$py_install_ok" -eq 1 ]; then
        py_exe=$(_skill_scanner_runas_target_user uv python find 3.10 2>/dev/null || true)
    fi

    if [ -n "$py_exe" ] && _skill_scanner_runas_target_user "$py_exe" -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then
        printf '%s\n' "$py_exe"
        return 0
    fi

    return 1
}

_skill_scanner_venv_dir_for_user() {
    _skill_scanner_runas_target_user bash -c 'printf "%s/%s\n" "$HOME" "'"$SKILL_SCANNER_VENV_PATH_RELATIVE"'"'
}

_create_skill_scanner_venv_with_uv() {
    local py_exe=$1
    local venv_dir=$2
    if _skill_scanner_uv_use_quiet_output; then
        _skill_scanner_runas_target_user env UV_NO_PROGRESS=1 uv -q venv --python "$py_exe" "$venv_dir" >/dev/null 2>&1
    else
        _skill_scanner_runas_target_user uv venv --python "$py_exe" "$venv_dir"
    fi
}

_install_skill_scanner_uv_in_venv() {
    local venv_python=$1
    if _skill_scanner_uv_use_quiet_output; then
        _skill_scanner_runas_target_user env UV_NO_PROGRESS=1 uv -qq pip install --python "$venv_python" "$SKILL_SCANNER_PYPI_PACKAGE" >/dev/null 2>&1
    else
        _skill_scanner_runas_target_user uv pip install --python "$venv_python" "$SKILL_SCANNER_PYPI_PACKAGE"
    fi
}

_skill_scanner_ensure_venv_bin_in_path() {
    local venv_dir=$1
    local venv_bin
    venv_bin=$(_skill_scanner_venv_scripts_dir "$venv_dir")
    local export_line="export PATH=\"${venv_bin}:\$PATH\""

    # Current process PATH (helps immediate invocation in this script run).
    case ":$PATH:" in
        *":${venv_bin}:"*) ;;
        *) export PATH="${venv_bin}:$PATH" ;;
    esac

    # Persist for common shells of target user (idempotent).
    _skill_scanner_runas_target_user bash -c '
        set -e
        line="$1"
        shift
        for rc in "$@"; do
            [ -f "$rc" ] || touch "$rc"
            grep -Fqx "$line" "$rc" || printf "\n%s\n" "$line" >> "$rc"
        done
    ' _ "$export_line" "$HOME/.zshrc" "$HOME/.bashrc" || return 1
}

_skill_scanner_installed_in_venv() {
    local venv_python=$1
    local venv_dir scanner
    venv_dir=$(dirname "$(dirname "$venv_python")")
    scanner=$(_skill_scanner_venv_skill_scanner_path "$venv_dir")
    # uv-managed venvs often have no pip module; the CLI is the reliable signal.
    if [ -x "$scanner" ] || { _skill_scanner_is_windows_env && [ -f "$scanner" ]; }; then
        return 0
    fi
    _skill_scanner_runas_target_user "$venv_python" -m pip show "$SKILL_SCANNER_PYPI_PACKAGE" >/dev/null 2>&1
}

# Confirm downloading and running Astral uv install.sh. Returns 0 if user accepts, 1 if decline or no TTY.
_confirm_uv_bootstrap_interactive() {
    local confirm
    local prompt="uv is not on PATH. Download and install uv from Astral (https://astral.sh/uv/)? (Y/n): "

    if [ -t 0 ]; then
        printf '\n' >&2
        read -r -p "$prompt" confirm
    elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf '\n' >&2
        read -r -p "$prompt" confirm </dev/tty
    else
        print_info "No interactive terminal: cannot prompt for uv installation."
        return 1
    fi
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

# Confirm installing Python 3.10 via uv when none on PATH (stdout must stay clean for py_exe capture).
_confirm_uv_python310_interactive() {
    local confirm
    local prompt="No Python 3.10+ on PATH. Install Python 3.10 with uv now? (Y/n): "

    if [ -t 0 ]; then
        printf '\n' >&2
        read -r -p "$prompt" confirm
    elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf '\n' >&2
        read -r -p "$prompt" confirm </dev/tty
    else
        print_info "No interactive terminal: cannot prompt for uv-managed Python." >&2
        return 1
    fi
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

# Single gate before any uv / Python / venv / pip work. Returns 0 if user accepts, 1 if decline or no TTY.
# Optional arg: current Nacos server version (for messaging only).
_confirm_skill_scanner_uv_stack() {
    local nacos_version="${1:-${VERSION:-}}"
    local confirm
    local prompt="Install Cisco skill-scanner stack (uv + Python 3.10+ under ~/ai-infra/.venv; missing tools will be installed)? (Y/n): "

    print_info "Optional Cisco skill-scanner for Nacos ${nacos_version}: proceeding may install uv, Python 3.10+, and ${SKILL_SCANNER_PYPI_PACKAGE} under ~/ai-infra/.venv."

    if [ -t 0 ]; then
        printf '\n' >&2
        read -r -p "$prompt" confirm
    elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
        # Piped installs (e.g. curl | bash): stdin is the script; ask on the controlling terminal.
        printf '\n' >&2
        read -r -p "$prompt" confirm </dev/tty
    else
        print_info "No interactive terminal: skipping optional Cisco skill-scanner setup (uv / Python 3.10+)."
        _skill_scanner_trace "skip stack: no tty (stdin not a tty and /dev/tty unavailable)"
        return 1
    fi
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

_skill_scanner_ensure_version_ge() {
    if declare -F version_ge >/dev/null 2>&1; then
        return 0
    fi
    if [ -f "$_SKILL_SCANNER_LIB_DIR/common.sh" ]; then
        # shellcheck source=common.sh
        source "$_SKILL_SCANNER_LIB_DIR/common.sh"
    fi
    declare -F version_ge >/dev/null 2>&1
}

# When Nacos Server version >= 3.2.0, ensure skill-scanner is available (best-effort).
# Set NACOS_SETUP_SKIP_SKILL_SCANNER=1 to disable.
maybe_install_skill_scanner_for_nacos() {
    local nacos_version="${1:-}"
    _skill_scanner_trace "maybe_install_skill_scanner_for_nacos nacos_version='${nacos_version}'"

    if [ "${NACOS_SETUP_SKIP_SKILL_SCANNER:-}" = "1" ] || [ "${NACOS_SETUP_SKIP_SKILL_SCANNER:-}" = "true" ]; then
        _skill_scanner_trace "skip: NACOS_SETUP_SKIP_SKILL_SCANNER is set"
        return 0
    fi

    if [ -z "$nacos_version" ]; then
        _skill_scanner_trace "skip: empty nacos_version"
        return 0
    fi

    if ! _skill_scanner_ensure_version_ge; then
        _skill_scanner_trace "skip: version_ge unavailable (missing lib/common.sh?)"
        print_warn "skill-scanner step skipped: version_ge unavailable (reinstall nacos-setup from a build that includes lib/common.sh)"
        return 0
    fi

    if ! version_ge "$nacos_version" "$MIN_NACOS_VERSION_FOR_SKILL_SCANNER"; then
        _skill_scanner_trace "skip: nacos ${nacos_version} < ${MIN_NACOS_VERSION_FOR_SKILL_SCANNER} (no skill-scanner step)"
        return 0
    fi

    # Try to add skill-scanner to PATH if not already there
    _ensure_skill_scanner_in_path

    local venv_dir venv_python venv_scripts
    venv_dir=$(_skill_scanner_venv_dir_for_user)
    venv_python=$(_skill_scanner_venv_python_path "$venv_dir")
    venv_scripts=$(_skill_scanner_venv_scripts_dir "$venv_dir")

    if _skill_scanner_venv_python_exists "$venv_python" && _skill_scanner_installed_in_venv "$venv_python"; then
        SKILL_SCANNER_INSTALLED="true"
        print_info "skill-scanner already installed in ${venv_dir} (skip)."
        return 0
    fi

    if command -v skill-scanner >/dev/null 2>&1; then
        _skill_scanner_trace "skill-scanner already on PATH; skip uv/venv install"
        SKILL_SCANNER_INSTALLED="true"
        return 0
    fi

    if ! _confirm_skill_scanner_uv_stack "$nacos_version"; then
        print_info "Skipping skill-scanner / uv / Python setup. Continuing Nacos startup."
        return 0
    fi

    if ! _skill_scanner_bootstrap_uv; then
        print_warn "Cannot install ${SKILL_SCANNER_PYPI_PACKAGE} without uv."
        return 0
    fi

    local py_exe
    py_exe=$(_ensure_python_310_plus_with_uv) || {
        print_warn "Could not prepare Python 3.10+ with uv. Please install Python 3.10+ and retry."
        print_warn "Reference: https://docs.astral.sh/uv/guides/install-python/"
        return 0
    }

    if ! _skill_scanner_venv_python_exists "$venv_python"; then
        print_info "Creating uv virtual environment in ${venv_dir}..."
        if ! _create_skill_scanner_venv_with_uv "$py_exe" "$venv_dir"; then
            print_warn "Could not create uv virtual environment at ${venv_dir}."
            print_warn "Docs: https://docs.astral.sh/uv/"
            return 0
        fi
        venv_python=$(_skill_scanner_venv_python_path "$venv_dir")
    fi

    print_info "Installing ${SKILL_SCANNER_PYPI_PACKAGE} into ${venv_dir} via uv..."
    if _install_skill_scanner_uv_in_venv "$venv_python"; then
        SKILL_SCANNER_INSTALLED="true"
        if _skill_scanner_ensure_venv_bin_in_path "$venv_dir"; then
            print_info "Added ${venv_scripts} to PATH (current session and shell rc files)."
        else
            print_warn "Installed successfully, but failed to persist PATH update. Please add ${venv_scripts} to PATH manually."
        fi
        print_info "Installed ${SKILL_SCANNER_PYPI_PACKAGE} in ${venv_dir}."
        print_info "Run with: $(_skill_scanner_venv_skill_scanner_path "$venv_dir")"
        return 0
    fi

    print_warn "Could not install ${SKILL_SCANNER_PYPI_PACKAGE} into ${venv_dir} via uv."
    print_warn "Docs: https://github.com/cisco-ai-defense/skill-scanner"
    return 0
}
