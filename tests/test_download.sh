#!/bin/bash
#
# Download & Cache Tests - 下载和缓存测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Download & Cache ==="

# 测试 1: 检查下载函数存在
if [ -f "$LIB_DIR/download.sh" ]; then
    if grep -q "download_nacos\|download_file" "$LIB_DIR/download.sh"; then
        test_pass "Download function exists"
    else
        test_fail "Download function not found"
    fi
else
    test_fail "download.sh not found"
fi

# 测试 2: 检查缓存目录配置
if [ -f "$LIB_DIR/download.sh" ]; then
    if grep -q "CACHE_DIR\|cache" "$LIB_DIR/download.sh"; then
        test_pass "Cache directory configured"
    else
        test_fail "Cache directory not configured"
    fi
else
    test_fail "download.sh not found"
fi

# 测试 3: 检查缓存复用逻辑
if [ -f "$LIB_DIR/download.sh" ]; then
    if grep -q "exists\|cached\|already" "$LIB_DIR/download.sh"; then
        test_pass "Cache reuse logic exists"
    else
        test_fail "Cache reuse logic not found"
    fi
else
    test_fail "download.sh not found"
fi

# 测试 4: 检查版本 URL 构建
if [ -f "$LIB_DIR/download.sh" ]; then
    if grep -q "download.nacos.io\|nacos.io" "$LIB_DIR/download.sh"; then
        test_pass "Nacos download URL configured"
    else
        test_fail "Nacos download URL not configured"
    fi
else
    test_fail "download.sh not found"
fi

# 测试 5: 检查单机模式调用下载
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "download" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode uses download"
    else
        test_fail "Standalone mode should use download"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 6: 检查集群模式调用下载
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "download" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode uses download"
    else
        test_fail "Cluster mode should use download"
    fi
else
    test_fail "cluster.sh not found"
fi

echo ""
test_summary
