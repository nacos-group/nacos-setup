#!/bin/bash
#
# Cluster Mode Tests - 集群模式测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Cluster Mode ==="

# 测试 1: 检查 run_cluster_mode 函数存在
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "^run_cluster_mode()" "$LIB_DIR/cluster.sh"; then
        test_pass "run_cluster_mode function exists"
    else
        test_fail "run_cluster_mode function not found"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 2: 检查集群模式必要的环境变量初始化
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "ClusterId\|CLUSTER_ID" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode initializes required variables"
    else
        test_fail "Cluster mode missing variable initialization"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 3: 检查集群模式端口分配
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "find_available_port_pair\|find_available_port" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode uses port manager for port allocation"
    else
        test_fail "Cluster mode should use port manager"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 4: 检查集群模式 cluster.conf 生成
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "cluster.conf" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode generates cluster.conf"
    else
        test_fail "Cluster mode should generate cluster.conf"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 5: 检查集群模式多节点启动
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "for.*REPLICA_COUNT\|while.*node_index" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode iterates over replica count"
    else
        test_fail "Cluster mode should iterate over nodes"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 6: 检查集群模式节点配置复制
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "cp " "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode copies config to each node"
    else
        test_fail "Cluster mode should copy config to nodes"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 7: 检查集群模式数据源配置
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "load_default_datasource_config\|apply_datasource_config" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode supports external datasource"
    else
        test_fail "Cluster mode should support external datasource"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 7b: 检查集群模式默认 agentspec / skill 数据导入
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "run_post_nacos_config_data_import_hook" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode invokes default data import hook"
    else
        test_fail "Cluster mode should call run_post_nacos_config_data_import_hook"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 8: 检查集群模式 daemon 支持
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "DAEMON_MODE" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode supports daemon mode"
    else
        test_fail "Cluster mode should support daemon mode"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 9: 检查集群模式 cleanup 机制
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "cleanup_cluster\|trap.*EXIT" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode has cleanup mechanism"
    else
        test_fail "Cluster mode should have cleanup"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 10: 检查集群模式节点监控
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "ps \|pgrep" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode monitors node processes"
    else
        test_fail "Cluster mode should monitor processes"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 11: 检查集群模式 join 功能
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "join_mode\|JOIN_MODE" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode supports join mode"
    else
        test_fail "Cluster mode should support join mode"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 12: 检查集群模式节点排序
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "sort.*numeric\|sort.*-n" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode sorts nodes numerically"
    else
        test_fail "Cluster mode should sort nodes numerically"
    fi
else
    test_fail "cluster.sh not found"
fi

echo ""
test_summary
