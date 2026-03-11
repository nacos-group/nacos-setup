#!/bin/bash
#
# Java Environment Tests - Java 环境测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Java Environment ==="

# 测试 1: 检查 Java 检测函数存在
if [ -f "$LIB_DIR/java_manager.sh" ]; then
    if grep -q "check_java\|detect_java" "$LIB_DIR/java_manager.sh"; then
        test_pass "Java check function exists"
    else
        test_fail "Java check function not found"
    fi
else
    test_fail "java_manager.sh not found"
fi

# 测试 2: 检查 Java 版本解析
if [ -f "$LIB_DIR/java_manager.sh" ]; then
    if grep -q "java.*version\|VERSION" "$LIB_DIR/java_manager.sh"; then
        test_pass "Java version parsing exists"
    else
        test_fail "Java version parsing not found"
    fi
else
    test_fail "java_manager.sh not found"
fi

# 测试 3: 检查 Java 版本要求
if [ -f "$LIB_DIR/java_manager.sh" ]; then
    if grep -q "17\|1.8\|8" "$LIB_DIR/java_manager.sh"; then
        test_pass "Java version requirements defined"
    else
        test_fail "Java version requirements not defined"
    fi
else
    test_fail "java_manager.sh not found"
fi

# 测试 4: 检查单机模式调用 Java 检测
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "check_java\|java_manager" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode checks Java"
    else
        test_fail "Standalone mode should check Java"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 5: 检查集群模式调用 Java 检测
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "check_java\|java_manager" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode checks Java"
    else
        test_fail "Cluster mode should check Java"
    fi
else
    test_fail "cluster.sh not found"
fi

echo ""
test_summary
