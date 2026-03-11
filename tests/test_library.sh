#!/bin/bash
#
# Library Function Tests - 库函数测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Library Functions ==="

# Source common.sh
if [ -f "$LIB_DIR/common.sh" ]; then
    source "$LIB_DIR/common.sh" 2>/dev/null

    # 版本比较测试
    if version_ge "3.1.1" "2.4.0"; then
        test_pass "version_ge: 3.1.1 >= 2.4.0"
    else
        test_fail "version_ge: 3.1.1 >= 2.4.0"
    fi

    if ! version_ge "2.3.0" "2.4.0"; then
        test_pass "version_ge: 2.3.0 < 2.4.0"
    else
        test_fail "version_ge: 2.3.0 < 2.4.0"
    fi

    # OS 检测
    os=$(detect_os_arch)
    if [ -n "$os" ]; then
        test_pass "OS detection: $os"
    else
        test_fail "OS detection"
    fi

    # IP 获取
    ip=$(get_local_ip 2>/dev/null)
    if [ -n "$ip" ]; then
        test_pass "IP detection: $ip"
    else
        test_fail "IP detection"
    fi

    # 密钥生成
    key=$(generate_secret_key)
    if [ -n "$key" ] && [ ${#key} -ge 32 ]; then
        test_pass "Secret key generation (${#key} chars)"
    else
        test_fail "Secret key generation"
    fi
else
    test_fail "common.sh not found"
fi

echo ""

# 端口管理测试
echo "=== Test Group: Port Manager ==="

if [ -f "$LIB_DIR/port_manager.sh" ]; then
    source "$LIB_DIR/port_manager.sh" 2>/dev/null

    # 查找可用端口
    avail_port=$(find_available_port 45000 2>/dev/null)
    if [ -n "$avail_port" ]; then
        test_pass "Find available port: $avail_port"
    else
        test_fail "Find available port"
    fi
else
    test_fail "port_manager.sh not found"
fi

echo ""
test_summary
