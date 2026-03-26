#!/bin/bash

# Copyright 1999-2025 Alibaba Group Holding Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Optional Cisco skill-scanner (https://github.com/cisco-ai-defense/skill-scanner)
# PyPI: cisco-ai-skill-scanner — requires Python 3.10+ and uv (recommended) or pip.
# When invoked via "sudo nacos-setup", Python/uv/pip are resolved in SUDO_USER's
# environment (same as running without sudo), so Homebrew/user installs are visible.

SKILL_SCANNER_PYPI_PACKAGE="cisco-ai-skill-scanner"
MIN_NACOS_VERSION_FOR_SKILL_SCANNER="3.2.0"
_SKILL_SCANNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Always write to stderr (no ANSI); survives logging pipelines and makes sudo/root issues obvious.
_skill_scanner_trace() { printf '%s\n' "[nacos-setup/skill-scanner] $*" >&2; }

# Configure skill-scanner plugin properties in application.properties
# Parameters: config_file
configure_skill_scanner_properties() {
    local config_file="$1"
    
    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        _skill_scanner_trace "skip: application.properties not found (config_file=${config_file:-unset})"
        return 1
    fi
    
    _skill_scanner_trace "configuring skill-scanner plugin properties in ${config_file}"
    
    update_config_property "$config_file" "nacos.plugin.skill-scanner.enabled" "true"
    update_config_property "$config_file" "nacos.plugin.skill-scanner.type" "nacos"
    
    _skill_scanner_trace "skill-scanner plugin properties configured successfully"
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

# Run as the user who invoked sudo (so PATH/HOME match a normal login).
_skill_scanner_runas_target_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && command -v sudo >/dev/null 2>&1; then
        sudo -u "$SUDO_USER" -H "$@"
    else
        "$@"
    fi
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

_skill_scanner_already_installed() {
    local py_exe=$1
    if _skill_scanner_runas_target_user bash -c 'command -v skill-scanner >/dev/null 2>&1'; then
        return 0
    fi
    if _skill_scanner_runas_target_user "$py_exe" -m pip show "$SKILL_SCANNER_PYPI_PACKAGE" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

_install_skill_scanner_uv() {
    local py_exe=$1
    _skill_scanner_runas_target_user uv pip install --python "$py_exe" "$SKILL_SCANNER_PYPI_PACKAGE"
}

_install_skill_scanner_pip() {
    local py_exe=$1
    _skill_scanner_runas_target_user "$py_exe" -m pip install --user "$SKILL_SCANNER_PYPI_PACKAGE"
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

    print_info "Nacos ${nacos_version} >= ${MIN_NACOS_VERSION_FOR_SKILL_SCANNER}: checking Cisco skill-scanner (${SKILL_SCANNER_PYPI_PACKAGE})..."
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        print_info "sudo detected: using user ${SUDO_USER}'s environment for Python / pip / uv (root often lacks Homebrew Python)."
    fi

    local py_exe
    py_exe=$(_find_python_310_plus) || {
        print_warn "skill-scanner needs Python 3.10+ on PATH for your user. Install Python 3.10+ with pip or uv, then: pip install --user ${SKILL_SCANNER_PYPI_PACKAGE}"
        print_warn "Reference: https://github.com/cisco-ai-defense/skill-scanner"
        return 0
    }

    if _skill_scanner_already_installed "$py_exe"; then
        print_info "skill-scanner already installed (skip)."
        return 0
    fi

    if ! _skill_scanner_runas_target_user bash -c 'command -v uv >/dev/null 2>&1' \
        && ! _skill_scanner_runas_target_user "$py_exe" -m pip --version >/dev/null 2>&1; then
        print_warn "Neither uv nor pip is available for Python at ${py_exe}. Install uv or pip for Python 3.10+."
        return 0
    fi

    if _skill_scanner_runas_target_user bash -c 'command -v uv >/dev/null 2>&1'; then
        print_info "Installing ${SKILL_SCANNER_PYPI_PACKAGE} with uv..."
        if _install_skill_scanner_uv "$py_exe"; then
            print_info "Installed ${SKILL_SCANNER_PYPI_PACKAGE} via uv."
            return 0
        fi
        print_warn "uv install failed, trying pip..."
    fi

    print_info "Installing ${SKILL_SCANNER_PYPI_PACKAGE} with pip..."
    if _install_skill_scanner_pip "$py_exe"; then
        print_info "Installed ${SKILL_SCANNER_PYPI_PACKAGE} via pip."
        print_info "If skill-scanner is not in PATH, add ~/.local/bin or run: ${py_exe} -m skill_scanner"
        return 0
    fi

    print_warn "Could not install ${SKILL_SCANNER_PYPI_PACKAGE}. Install manually: pip install --user ${SKILL_SCANNER_PYPI_PACKAGE}"
    print_warn "Docs: https://github.com/cisco-ai-defense/skill-scanner"
    return 0
}
