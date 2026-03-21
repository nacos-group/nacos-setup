#!/bin/bash
#
# Argument Parsing Tests - 参数解析测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Argument Parsing ==="

if [ -f "$TEST_DIR/nacos-setup.sh" ]; then
    # 测试帮助信息
    if bash "$TEST_DIR/nacos-setup.sh" --help >/dev/null 2>&1; then
        test_pass "--help flag works"
    else
        test_fail "--help flag failed"
    fi

    # 测试无效版本
    output=$(bash "$TEST_DIR/nacos-setup.sh" -v 2.3.0 2>&1)
    if echo "$output" | grep -qi "not supported\|error"; then
        test_pass "Invalid version detection (2.3.0)"
    else
        test_fail "Invalid version detection"
    fi

    # 测试缺少 cluster ID
    output=$(bash "$TEST_DIR/nacos-setup.sh" -c 2>&1)
    if echo "$output" | grep -qi "requires\|error"; then
        test_pass "Missing cluster ID detection"
    else
        test_fail "Missing cluster ID detection"
    fi

    # 测试集群专用参数必须配合 -c 使用
    output=$(bash "$TEST_DIR/nacos-setup.sh" --leave 1 --no-start 2>&1)
    if echo "$output" | grep -qi "Cluster options.*require -c\|requires.*cluster"; then
        test_pass "Cluster-only flags require cluster ID"
    else
        test_fail "Cluster-only flags should require cluster ID"
    fi
else
    test_fail "nacos-setup.sh not found"
fi

echo ""
test_summary
