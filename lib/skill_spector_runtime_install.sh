#!/bin/bash

# Copyright 1999-2026 Alibaba Group Holding Ltd.
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

FALLBACK_SKILL_SPECTOR_RUNTIME_VERSION="${FALLBACK_SKILL_SPECTOR_RUNTIME_VERSION:-2.3.11}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://download.nacos.io}"
SKILL_SPECTOR_RUNTIME_DEFAULT_BASE_URL="${SKILL_SPECTOR_RUNTIME_DEFAULT_BASE_URL:-${DOWNLOAD_BASE_URL}/skill-spector}"
MIN_NACOS_VERSION_FOR_SKILL_SPECTOR="3.3.0"
SKILL_SPECTOR_RUNTIME_PATH_RELATIVE="ai-infra/ai-pipeline/skill-spector"
SKILL_SPECTOR_INSTALLED="false"

_skill_spector_source_versions() {
    if declare -F get_version >/dev/null 2>&1; then
        return 0
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${script_dir}/versions.sh" ]; then
        # shellcheck source=lib/versions.sh
        source "${script_dir}/versions.sh"
    fi
}

_skill_spector_default_runtime_version() {
    _skill_spector_source_versions
    if declare -F get_version >/dev/null 2>&1; then
        get_version skill-spector-runtime 1
        return
    fi
    printf '%s\n' "${FALLBACK_SKILL_SPECTOR_RUNTIME_VERSION}"
}

_skill_spector_default_runtime_dir() {
    local version="${1:-$(_skill_spector_default_runtime_version)}"
    env "PATH=$PATH" bash -c 'printf "%s/%s/%s\n" "$HOME" "$1" "$2"' \
        _ "$SKILL_SPECTOR_RUNTIME_PATH_RELATIVE" "$version"
}

_skill_spector_command_path_for_dir() {
    printf '%s/bin/skill-spector\n' "$1"
}

_get_skill_spector_command_path() {
    local version runtime_dir wrapper
    version="${SKILL_SPECTOR_RUNTIME_VERSION:-$(_skill_spector_default_runtime_version)}"
    runtime_dir="${SKILL_SPECTOR_RUNTIME_DIR:-$(_skill_spector_default_runtime_dir "$version")}"
    wrapper=$(_skill_spector_command_path_for_dir "$runtime_dir")
    if [ -x "$wrapper" ]; then
        printf '%s\n' "$wrapper"
        return 0
    fi
    command -v skill-spector 2>/dev/null
}

_skill_spector_ensure_version_ge() {
    if declare -F version_ge >/dev/null 2>&1; then
        return 0
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${script_dir}/common.sh" ]; then
        # shellcheck source=common.sh
        source "${script_dir}/common.sh"
    fi
    declare -F version_ge >/dev/null 2>&1
}

_skill_spector_should_write_plugin_config() {
    if [ "${NACOS_SETUP_SKIP_SKILL_SPECTOR:-}" = "1" ] || [ "${NACOS_SETUP_SKIP_SKILL_SPECTOR:-}" = "true" ]; then
        return 1
    fi
    if ! _skill_spector_ensure_version_ge; then
        return 1
    fi
    if ! version_ge "${VERSION:-0}" "$MIN_NACOS_VERSION_FOR_SKILL_SPECTOR"; then
        return 1
    fi
    if [ "$SKILL_SPECTOR_INSTALLED" = "true" ]; then
        return 0
    fi
    if [ -n "$(_get_skill_spector_command_path 2>/dev/null || true)" ]; then
        return 0
    fi
    return 1
}

configure_skill_spector_properties() {
    local config_file="$1"

    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        return 1
    fi

    print_detail "Configuring skill-spector plugin properties in ${config_file}"

    update_config_property "$config_file" "nacos.plugin.ai-pipeline.enabled" "true"
    append_config_csv_property_value "$config_file" "nacos.plugin.ai-pipeline.type" "skill-spector"

    local skill_spector_cmd
    skill_spector_cmd=$(_get_skill_spector_command_path || true)
    if [ -n "$skill_spector_cmd" ]; then
        update_config_property "$config_file" "nacos.plugin.ai-pipeline.skill-spector.command" "$skill_spector_cmd"
    fi

    print_detail "skill-spector plugin properties configured successfully"
}

print_skill_spector_install_usage() {
    local default_version
    default_version="${SKILL_SPECTOR_RUNTIME_VERSION:-$(_skill_spector_default_runtime_version)}"
    cat <<EOF
Usage:
  nacos-setup skill-spector install [options]
  bash lib/skill_spector_runtime_install.sh [options]

Install SkillSpector runtime for the Nacos skill-spector pipeline.

Options:
  --base-url URL       Override runtime artifact base URL.
                       Expected layout:
                       URL/skillspector-runtime-<version>-<platform>.tar.gz
                       Default: ${SKILL_SPECTOR_RUNTIME_DEFAULT_BASE_URL}
  --url URL            Runtime tar.gz URL.
  --file FILE          Local runtime tar.gz file for offline installation.
  --sha256-url URL     Runtime .sha256 URL. Defaults to <runtime-url>.sha256.
  --sha256-file FILE   Local .sha256 file.
  --version VERSION    SkillSpector runtime version. Default: ${default_version}
  --platform PLATFORM  Runtime platform. Default: auto-detect, such as linux-x86_64.
  --nacos-home DIR     Accepted for compatibility; not required for command-mode installation.
  --runtime-dir DIR    skill-spector runtime directory.
                       Default: ~/ai-infra/ai-pipeline/skill-spector/<version>
  -h, --help           Show this help.

Environment variables:
  SKILL_SPECTOR_RUNTIME_BASE_URL
  SKILL_SPECTOR_RUNTIME_DEFAULT_BASE_URL
  SKILL_SPECTOR_RUNTIME_VERSION
  SKILL_SPECTOR_RUNTIME_PLATFORM
  SKILL_SPECTOR_RUNTIME_DIR
  NACOS_HOME
EOF
}

_skill_spector_error() {
    if declare -F print_error >/dev/null 2>&1; then
        print_error "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
}

_skill_spector_info() {
    if declare -F print_info >/dev/null 2>&1; then
        print_info "$*"
    else
        printf '%s\n' "$*"
    fi
}

_skill_spector_die() {
    _skill_spector_error "$*"
    exit 1
}

_skill_spector_detect_platform() {
    local os_name arch_name os_key arch_key
    os_name=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch_name=$(uname -m | tr '[:upper:]' '[:lower:]')

    case "${os_name}" in
        linux*) os_key="linux" ;;
        darwin*) os_key="darwin" ;;
        msys*|mingw*|cygwin*) os_key="windows" ;;
        *) os_key="${os_name}" ;;
    esac

    case "${arch_name}" in
        amd64|x86_64) arch_key="x86_64" ;;
        arm64|aarch64) arch_key="aarch64" ;;
        *) arch_key="${arch_name}" ;;
    esac

    printf '%s-%s\n' "${os_key}" "${arch_key}"
}

_skill_spector_download_file() {
    local download_url="$1"
    local output_file="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL "${download_url}" -o "${output_file}"
        return
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -O "${output_file}" "${download_url}"
        return
    fi
    _skill_spector_die "curl or wget is required to download ${download_url}"
}

_skill_spector_sha256_of() {
    local target_file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${target_file}" | awk '{print $1}'
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${target_file}" | awk '{print $1}'
        return
    fi
    _skill_spector_die "sha256sum or shasum is required to verify ${target_file}"
}

_skill_spector_verify_sha256() {
    local target_file="$1"
    local checksum_file="$2"
    local expected_sha actual_sha
    [ -f "${checksum_file}" ] || _skill_spector_die "checksum file not found: ${checksum_file}"
    expected_sha=$(awk 'NF {print $1; exit}' "${checksum_file}")
    [ -n "${expected_sha}" ] || _skill_spector_die "checksum file is empty: ${checksum_file}"
    actual_sha=$(_skill_spector_sha256_of "${target_file}")
    [ "${expected_sha}" = "${actual_sha}" ] || _skill_spector_die "checksum mismatch for ${target_file}"
}

install_skill_spector_runtime() {
    local version="${SKILL_SPECTOR_RUNTIME_VERSION:-$(_skill_spector_default_runtime_version)}"
    local base_url="${SKILL_SPECTOR_RUNTIME_BASE_URL:-${SKILL_SPECTOR_RUNTIME_DEFAULT_BASE_URL}}"
    local nacos_home="${NACOS_HOME:-}"
    local runtime_dir="${SKILL_SPECTOR_RUNTIME_DIR:-}"
    local platform_key="${SKILL_SPECTOR_RUNTIME_PLATFORM:-}"
    local runtime_file=""
    local runtime_url=""
    local sha256_file=""
    local sha256_url=""
    local tmp_dir=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --base-url)
                [ "$#" -ge 2 ] || _skill_spector_die "--base-url requires a value"
                base_url="$2"
                shift 2
                ;;
            --url)
                [ "$#" -ge 2 ] || _skill_spector_die "--url requires a value"
                runtime_url="$2"
                shift 2
                ;;
            --file)
                [ "$#" -ge 2 ] || _skill_spector_die "--file requires a value"
                runtime_file="$2"
                shift 2
                ;;
            --sha256-url)
                [ "$#" -ge 2 ] || _skill_spector_die "--sha256-url requires a value"
                sha256_url="$2"
                shift 2
                ;;
            --sha256-file)
                [ "$#" -ge 2 ] || _skill_spector_die "--sha256-file requires a value"
                sha256_file="$2"
                shift 2
                ;;
            --version)
                [ "$#" -ge 2 ] || _skill_spector_die "--version requires a value"
                version="$2"
                shift 2
                ;;
            --platform)
                [ "$#" -ge 2 ] || _skill_spector_die "--platform requires a value"
                platform_key="$2"
                shift 2
                ;;
            --nacos-home)
                [ "$#" -ge 2 ] || _skill_spector_die "--nacos-home requires a value"
                nacos_home="$2"
                shift 2
                ;;
            --runtime-dir)
                [ "$#" -ge 2 ] || _skill_spector_die "--runtime-dir requires a value"
                runtime_dir="$2"
                shift 2
                ;;
            -h|--help)
                print_skill_spector_install_usage
                return 0
                ;;
            *)
                _skill_spector_die "unknown option: $1"
                ;;
        esac
    done

    local detected_platform
    detected_platform=$(_skill_spector_detect_platform)
    if [ -z "${platform_key}" ]; then
        platform_key="${detected_platform}"
    fi

    if [ -z "${runtime_dir}" ]; then
        runtime_dir=$(_skill_spector_default_runtime_dir "${version}")
    fi

    while [ "${base_url%/}" != "${base_url}" ]; do
        base_url="${base_url%/}"
    done

    local archive_name="skillspector-runtime-${version}-${platform_key}.tar.gz"
    if [ -z "${runtime_file}" ] && [ -z "${runtime_url}" ] && [ -n "${base_url}" ]; then
        runtime_url="${base_url}/${archive_name}"
    fi
    if [ -z "${runtime_file}" ] && [ -z "${runtime_url}" ]; then
        _skill_spector_die "runtime source is required. Set SKILL_SPECTOR_RUNTIME_DEFAULT_BASE_URL, or use --base-url, --url, or --file."
    fi

    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/nacos-skill-spector-install.XXXXXX")
    trap 'rm -rf "${tmp_dir}"' RETURN

    local archive_path
    if [ -n "${runtime_file}" ]; then
        [ -f "${runtime_file}" ] || _skill_spector_die "runtime file not found: ${runtime_file}"
        archive_path="${runtime_file}"
    else
        archive_path="${tmp_dir}/${archive_name}"
        _skill_spector_info "Downloading ${runtime_url}"
        _skill_spector_download_file "${runtime_url}" "${archive_path}"
        if [ -z "${sha256_url}" ]; then
            sha256_url="${runtime_url}.sha256"
        fi
    fi

    local checksum_path
    if [ -n "${sha256_file}" ]; then
        checksum_path="${sha256_file}"
    else
        [ -n "${sha256_url}" ] || _skill_spector_die "checksum source is required. Use --sha256-url or --sha256-file."
        checksum_path="${tmp_dir}/${archive_name}.sha256"
        _skill_spector_info "Downloading ${sha256_url}"
        _skill_spector_download_file "${sha256_url}" "${checksum_path}"
    fi

    _skill_spector_verify_sha256 "${archive_path}" "${checksum_path}"

    mkdir -p "${runtime_dir}"
    _skill_spector_info "Extracting ${archive_path} to ${runtime_dir}"
    tar -xzf "${archive_path}" -C "${runtime_dir}"

    local runtime_root="${runtime_dir}/runtime/${platform_key}"
    local runtime_python=""
    local candidate
    for candidate in \
        "${runtime_root}/python/bin/python3" \
        "${runtime_root}/python/bin/python" \
        "${runtime_root}/venv/bin/python3" \
        "${runtime_root}/bin/python3"
    do
        if [ -x "${candidate}" ]; then
            runtime_python="${candidate}"
            break
        fi
    done

    [ -n "${runtime_python}" ] || _skill_spector_die "runtime python not found under ${runtime_root}"

    local wrapper="${runtime_dir}/bin/skill-spector"
    if [ -f "${wrapper}" ] && [ ! -x "${wrapper}" ]; then
        chmod +x "${wrapper}"
    fi
    [ -x "${wrapper}" ] || _skill_spector_die "skill-spector wrapper not found or not executable: ${wrapper}"

    if [ "${platform_key}" = "${detected_platform}" ]; then
        SKILLSPECTOR_RUNTIME_PLATFORM="${platform_key}" "${wrapper}" --version >/dev/null
    fi

    _skill_spector_info "SkillSpector runtime installed:"
    _skill_spector_info "  version: ${version}"
    _skill_spector_info "  platform: ${platform_key}"
    _skill_spector_info "  runtime: ${runtime_root}"
    _skill_spector_info "  command: ${wrapper}"
}

_confirm_skill_spector_runtime_install() {
    local runtime_version="$1"
    local runtime_dir="$2"
    local prompt="Install SkillSpector runtime ${runtime_version} to ${runtime_dir}? (Y/n): "

    if declare -F nacos_setup_read_prompt >/dev/null 2>&1; then
        if ! nacos_setup_read_prompt "$prompt"; then
            return 1
        fi
    elif [ -t 0 ]; then
        IFS= read -r -p "$prompt" REPLY || return 1
    else
        return 1
    fi

    case "${REPLY:-Y}" in
        [Yy]|[Yy][Ee][Ss]|"") return 0 ;;
        *) return 1 ;;
    esac
}

maybe_install_skill_spector_for_nacos() {
    local nacos_version="${1:-}"

    if [ "${NACOS_SETUP_SKIP_SKILL_SPECTOR:-}" = "1" ] || [ "${NACOS_SETUP_SKIP_SKILL_SPECTOR:-}" = "true" ]; then
        return 0
    fi

    if [ -z "$nacos_version" ]; then
        return 0
    fi

    if ! _skill_spector_ensure_version_ge; then
        print_warn "skill-spector step skipped: version_ge unavailable (reinstall nacos-setup from a build that includes lib/common.sh)"
        return 0
    fi

    if ! version_ge "$nacos_version" "$MIN_NACOS_VERSION_FOR_SKILL_SPECTOR"; then
        return 0
    fi

    local runtime_version runtime_dir command_path
    runtime_version="${SKILL_SPECTOR_RUNTIME_VERSION:-$(_skill_spector_default_runtime_version)}"
    runtime_dir="${SKILL_SPECTOR_RUNTIME_DIR:-$(_skill_spector_default_runtime_dir "$runtime_version")}"

    command_path=$(_get_skill_spector_command_path || true)
    if [ -n "$command_path" ]; then
        SKILL_SPECTOR_INSTALLED="true"
        print_info "skill-spector already installed at ${command_path} (skip)."
        return 0
    fi

    if ! _confirm_skill_spector_runtime_install "$runtime_version" "$runtime_dir"; then
        print_info "Skipping skill-spector runtime setup. Continuing Nacos startup."
        return 0
    fi

    if install_skill_spector_runtime --version "$runtime_version" --runtime-dir "$runtime_dir"; then
        SKILL_SPECTOR_INSTALLED="true"
    fi
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    install_skill_spector_runtime "$@"
fi
