#!/bin/bash
#
# Security Features Tests - 安全功能测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Security Features ==="

# 测试 1: 检查 JWT Token 生成功能
if [ -f "$LIB_DIR/common.sh" ]; then
    if grep -q "generate_secret_key\|TOKEN_SECRET" "$LIB_DIR/common.sh"; then
        test_pass "JWT Token generation function exists"
    else
        test_fail "JWT Token generation not found"
    fi
else
    test_fail "common.sh not found"
fi

# 测试 2: 检查 Identity Key 生成
if [ -f "$LIB_DIR/config_manager.sh" ]; then
    if grep -q "IDENTITY_KEY" "$LIB_DIR/config_manager.sh"; then
        test_pass "Identity Key generation exists"
    else
        test_fail "Identity Key generation not found"
    fi
else
    test_fail "config_manager.sh not found"
fi

# 测试 3: 检查密码生成
if [ -f "$LIB_DIR/common.sh" ]; then
    if grep -q "NACOS_PASSWORD\|generate.*password" "$LIB_DIR/common.sh"; then
        test_pass "Password generation exists"
    else
        test_fail "Password generation not found"
    fi
else
    test_fail "common.sh not found"
fi

# 测试 4: 检查单机模式安全配置
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "TOKEN_SECRET\|IDENTITY_KEY\|NACOS_PASSWORD" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode configures security"
    else
        test_fail "Standalone mode should configure security"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 5: 检查集群模式安全配置
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "TOKEN_SECRET\|IDENTITY_KEY\|NACOS_PASSWORD" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode configures security"
    else
        test_fail "Cluster mode should configure security"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 6: 检查配置文件中安全相关设置
if [ -f "$LIB_DIR/config_manager.sh" ]; then
    if grep -q "nacos.core.auth\|secret.key" "$LIB_DIR/config_manager.sh"; then
        test_pass "Config manager handles security settings"
    else
        test_fail "Config manager should handle security settings"
    fi
else
    test_fail "config_manager.sh not found"
fi

echo ""
test_summary
