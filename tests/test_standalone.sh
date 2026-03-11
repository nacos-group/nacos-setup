#!/bin/bash
#
# Standalone Mode Tests - 单机模式测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Standalone Mode ==="

# 测试 1: 检查 run_standalone_mode 函数存在
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "^run_standalone_mode()" "$LIB_DIR/standalone.sh"; then
        test_pass "run_standalone_mode function exists"
    else
        test_fail "run_standalone_mode function not found"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 2: 检查单机模式必要的环境变量初始化
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "INSTALL_DIR=" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode initializes required variables"
    else
        test_fail "Standalone mode missing variable initialization"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 3: 检查单机模式端口处理
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "BASE_PORT\|SERVER_PORT" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode handles port configuration"
    else
        test_fail "Standalone mode should handle port configuration"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 4: 检查单机模式 Java 检测
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "check_java" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode checks Java environment"
    else
        test_fail "Standalone mode should check Java"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 5: 检查单机模式下载功能
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "download_nacos" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode downloads Nacos if needed"
    else
        test_fail "Standalone mode should handle download"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 6: 检查单机模式配置生成
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "application.properties" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode generates configuration"
    else
        test_fail "Standalone mode should generate config"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 7: 检查单机模式数据源配置
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "load_default_datasource_config\|apply_datasource_config" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode supports external datasource"
    else
        test_fail "Standalone mode should support external datasource"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 8: 检查单机模式 daemon 支持
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "DAEMON_MODE" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode supports daemon mode"
    else
        test_fail "Standalone mode should support daemon mode"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 9: 检查单机模式 cleanup 机制
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "cleanup_standalone\|trap.*EXIT" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode has cleanup mechanism"
    else
        test_fail "Standalone mode should have cleanup"
    fi
else
    test_fail "standalone.sh not found"
fi

echo ""
test_summary
