#!/bin/bash
#
# --db-conf Feature Tests - 数据源配置功能测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: --db-conf Feature ==="

if [ -f "$LIB_DIR/config_manager.sh" ]; then
    source "$LIB_DIR/config_manager.sh" 2>/dev/null

    # 测试 _resolve_config_path 函数
    test_info "Testing _resolve_config_path function"

    # 测试配置名解析
    resolved=$(_resolve_config_path "prod")
    expected="$HOME/ai-infra/nacos/prod.properties"
    if [ "$resolved" = "$expected" ]; then
        test_pass "Config name 'prod' resolves to correct path"
    else
        test_fail "Config name resolution: expected $expected, got $resolved"
    fi

    # 测试 "default" 关键字
    resolved=$(_resolve_config_path "default")
    expected="$DEFAULT_DATASOURCE_CONFIG"
    if [ "$resolved" = "$expected" ]; then
        test_pass "Config name 'default' resolves to default path"
    else
        test_fail "Config name 'default' resolution: expected $expected, got $resolved"
    fi
else
    test_fail "config_manager.sh not found"
fi

echo ""

# 测试 db-conf show/edit 命令（不访问网络）
test_info "Testing db-conf commands (local mode)"

if [ -f "$TEST_DIR/nacos-setup.sh" ]; then
    # 测试 db-conf show 不应获取版本（本地模式）
    output=$(bash "$TEST_DIR/nacos-setup.sh" db-conf show 2>&1)
    if echo "$output" | grep -q "Fetching versions"; then
        test_fail "db-conf show should not fetch versions"
    else
        test_pass "db-conf show does not fetch versions (local mode)"
    fi

    # 测试 db-conf edit 不应获取版本（本地模式）
    output=$(echo -e "1\nlocalhost\n3306\nnacos\nroot\npassword" | bash "$TEST_DIR/nacos-setup.sh" db-conf edit /tmp/test_db_conf.properties 2>&1)
    if echo "$output" | grep -q "Fetching versions"; then
        test_fail "db-conf edit should not fetch versions"
    else
        test_pass "db-conf edit does not fetch versions (local mode)"
    fi

    # 清理测试文件
    rm -f /tmp/test_db_conf.properties
else
    test_fail "nacos-setup.sh not found"
fi

echo ""
test_summary
