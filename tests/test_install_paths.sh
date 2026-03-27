#!/bin/bash
#
# Install Path Constants Tests - 安装路径常量测试
# Validates: Requirements 1.1, 1.2

source "$(dirname "$0")/common.sh"

INSTALLER_SCRIPT="$TEST_DIR/nacos-installer.sh"

echo "=== Test Group: Install Path Constants ==="

# 测试 1: 验证 INSTALL_BASE_DIR 包含 $HOME/.nacos/nacos-setup
if [ -f "$INSTALLER_SCRIPT" ]; then
    if grep -q 'INSTALL_BASE_DIR="\$HOME/.nacos/nacos-setup"' "$INSTALLER_SCRIPT"; then
        test_pass "INSTALL_BASE_DIR is set to \$HOME/.nacos/nacos-setup"
    else
        test_fail "INSTALL_BASE_DIR should be \$HOME/.nacos/nacos-setup"
    fi
else
    test_fail "nacos-installer.sh not found"
fi

# 测试 2: 验证 BIN_DIR 包含 $HOME/.nacos/bin
if [ -f "$INSTALLER_SCRIPT" ]; then
    if grep -q 'BIN_DIR="\$HOME/.nacos/bin"' "$INSTALLER_SCRIPT"; then
        test_pass "BIN_DIR is set to \$HOME/.nacos/bin"
    else
        test_fail "BIN_DIR should be \$HOME/.nacos/bin"
    fi
else
    test_fail "nacos-installer.sh not found"
fi

# 测试 3: 验证 INSTALL_BASE_DIR 不包含 /usr/local
if [ -f "$INSTALLER_SCRIPT" ]; then
    if grep '^INSTALL_BASE_DIR=' "$INSTALLER_SCRIPT" | grep -q '/usr/local'; then
        test_fail "INSTALL_BASE_DIR should not contain /usr/local"
    else
        test_pass "INSTALL_BASE_DIR does not contain /usr/local"
    fi
else
    test_fail "nacos-installer.sh not found"
fi

# 测试 4: 验证 BIN_DIR 不包含 /usr/local/bin
if [ -f "$INSTALLER_SCRIPT" ]; then
    if grep '^BIN_DIR=' "$INSTALLER_SCRIPT" | grep -q '/usr/local/bin'; then
        test_fail "BIN_DIR should not contain /usr/local/bin"
    else
        test_pass "BIN_DIR does not contain /usr/local/bin"
    fi
else
    test_fail "nacos-installer.sh not found"
fi

echo ""
test_summary
