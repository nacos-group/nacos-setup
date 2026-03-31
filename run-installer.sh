#!/usr/bin/env bash
# 在安装/使用 nacos-setup 前运行：优先使用仓库内的 nacos-installer.sh，否则从官网下载后执行。
# 用法: ./run-installer.sh [传递给 nacos-installer.sh 的参数]
# 示例: ./run-installer.sh
#       ./run-installer.sh --cli

set -euo pipefail

# Match nacos-installer.sh colored [INFO] lines
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

abort_run_installer_on_windows() {
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
        echo -e "${RED}[ERROR]${NC} run-installer.sh does not support Windows. Use PowerShell:" >&2
        echo "" >&2
        echo "  iwr -UseBasicParsing https://nacos.io/nacos-installer.ps1 | iex" >&2
        echo "" >&2
        exit 1
    fi
}
abort_run_installer_on_windows

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$ROOT/nacos-installer.sh"
INSTALLER_URL="https://nacos.io/nacos-installer.sh"

if [ -f "$INSTALLER" ]; then
    echo -e "${BLUE}[INFO]${NC} nacos-installer: using local: $INSTALLER"
    bash "$INSTALLER" "$@"
else
    echo -e "${BLUE}[INFO]${NC} nacos-installer: local nacos-installer.sh not found, fetching: $INSTALLER_URL"
    curl -fsSL "$INSTALLER_URL" | bash -s -- "$@"
fi
