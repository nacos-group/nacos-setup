#!/usr/bin/env bash
# 在安装/使用 nacos-setup 前运行：优先使用仓库内的 nacos-installer.sh，否则从官网下载后执行。
# 用法: ./run-installer.sh [传递给 nacos-installer.sh 的参数]
# 示例: ./run-installer.sh
#       ./run-installer.sh --cli

set -euo pipefail

# Match nacos-installer.sh colored [INFO] lines
BLUE='\033[0;34m'
NC='\033[0m'

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
