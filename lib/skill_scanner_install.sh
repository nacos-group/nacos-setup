#!/bin/bash

# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Optional Cisco skill-scanner (https://github.com/cisco-ai-defense/skill-scanner)
# PyPI: cisco-ai-skill-scanner — requires Python 3.10+ and uv.
# One interactive (Y/n) gate before any uv / Python / venv work; decline or non-TTY skips the whole stack and Nacos continues.

SKILL_SCANNER_PYPI_PACKAGE="cisco-ai-skill-scanner"
MIN_NACOS_VERSION_FOR_SKILL_SCANNER="3.2.0"
_SKILL_SCANNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SCANNER_VENV_PATH_RELATIVE="ai-infra/.venv"
SKILL_SCANNER_INSTALLED="false"

# Always write to stderr (no ANSI); survives logging pipelines.
_skill_scanner_trace() {
    if [ "${VERBOSE:-false}" = true ]; then
        printf '%s\n' "[nacos-setup/skill-scanner] $*" >&2
    fi
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
    local venv_dir
    venv_dir=$(_skill_scanner_venv_dir_for_user 2>/dev/null || true)
    if [ -n "$venv_dir" ] && [ -x "${venv_dir}/bin/skill-scanner" ]; then
        printf '%s\n' "${venv_dir}/bin/skill-scanner"
        return 0
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

    # Fallback: rely on uv-managed Python even if system Python is unavailable.
    if _skill_scanner_runas_target_user uv python install 3.10 >/dev/null 2>&1; then
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
    _skill_scanner_runas_target_user uv venv --python "$py_exe" "$venv_dir"
}

_install_skill_scanner_uv_in_venv() {
    local venv_python=$1
    _skill_scanner_runas_target_user uv pip install --python "$venv_python" "$SKILL_SCANNER_PYPI_PACKAGE"
}

_skill_scanner_ensure_venv_bin_in_path() {
    local venv_dir=$1
    local venv_bin="${venv_dir}/bin"
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
    _skill_scanner_runas_target_user "$venv_python" -m pip show "$SKILL_SCANNER_PYPI_PACKAGE" >/dev/null 2>&1
}

# Single gate before any uv / Python / venv / pip work. Returns 0 if user accepts, 1 if decline or non-interactive.
_confirm_skill_scanner_uv_stack() {
    if [ ! -t 0 ]; then
        print_info "Non-interactive shell: skipping optional Cisco skill-scanner setup (uv / Python 3.10+)."
        _skill_scanner_trace "skip stack: non-interactive stdin"
        return 1
    fi

    local confirm
    read -r -p "Install Cisco skill-scanner stack (requires uv + Python 3.10+ under ~/ai-infra/.venv)? (Y/n): " confirm
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

    local venv_dir
    venv_dir=$(_skill_scanner_venv_dir_for_user)
    local venv_python="${venv_dir}/bin/python"

    if [ -x "$venv_python" ] && _skill_scanner_installed_in_venv "$venv_python"; then
        SKILL_SCANNER_INSTALLED="true"
        print_detail "skill-scanner already installed in ${venv_dir} (skip)."
        return 0
    fi

    if command -v skill-scanner >/dev/null 2>&1; then
        _skill_scanner_trace "skill-scanner already on PATH; skip uv/venv install"
        return 0
    fi

    print_detail "Nacos ${nacos_version} >= ${MIN_NACOS_VERSION_FOR_SKILL_SCANNER}: optional Cisco skill-scanner (${SKILL_SCANNER_PYPI_PACKAGE})."

    if ! _confirm_skill_scanner_uv_stack; then
        print_info "Skipping skill-scanner / uv / Python setup. Continuing Nacos startup."
        return 0
    fi

    if ! _skill_scanner_runas_target_user bash -c 'command -v uv >/dev/null 2>&1'; then
        print_warn "No uv environment detected. Cannot install ${SKILL_SCANNER_PYPI_PACKAGE}."
        print_warn "Please install uv first: https://docs.astral.sh/uv/getting-started/installation/"
        return 0
    fi

    local py_exe
    py_exe=$(_ensure_python_310_plus_with_uv) || {
        print_warn "Could not prepare Python 3.10+ with uv. Please install Python 3.10+ and retry."
        print_warn "Reference: https://docs.astral.sh/uv/guides/install-python/"
        return 0
    }

    if [ ! -x "$venv_python" ]; then
        print_detail "Creating uv virtual environment in ${venv_dir}..."
        if ! _create_skill_scanner_venv_with_uv "$py_exe" "$venv_dir"; then
            print_warn "Could not create uv virtual environment at ${venv_dir}."
            print_warn "Docs: https://docs.astral.sh/uv/"
            return 0
        fi
    fi

    print_detail "Installing ${SKILL_SCANNER_PYPI_PACKAGE} into ${venv_dir} via uv..."
    if _install_skill_scanner_uv_in_venv "$venv_python"; then
        SKILL_SCANNER_INSTALLED="true"
        if _skill_scanner_ensure_venv_bin_in_path "$venv_dir"; then
            print_detail "Added ${venv_dir}/bin to PATH (current session and shell rc files)."
        else
            print_warn "Installed successfully, but failed to persist PATH update. Please add ${venv_dir}/bin to PATH manually."
        fi
        print_detail "Installed ${SKILL_SCANNER_PYPI_PACKAGE} in ${venv_dir}."
        print_detail "Run with: ${venv_dir}/bin/skill-scanner"
        return 0
    fi

    print_warn "Could not install ${SKILL_SCANNER_PYPI_PACKAGE} into ${venv_dir} via uv."
    print_warn "Docs: https://github.com/cisco-ai-defense/skill-scanner"
    return 0
}
