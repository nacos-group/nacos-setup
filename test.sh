#!/bin/bash
#
# Nacos Setup Test Suite - 测试当前分支

set +e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
PASSED=0
FAILED=0

test_info() {
    echo "[TEST] $1"
}

test_pass() {
    echo "[PASS] $1"
    PASSED=$((PASSED + 1))
}

test_fail() {
    echo "[FAIL] $1"
    FAILED=$((FAILED + 1))
}

echo "========================================"
echo "   Nacos Setup Test Suite"
echo "   Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo "========================================"
echo ""

# ============================================================================
# 测试 1: 语法检查
echo "=== Test Group 1: Syntax Check ==="
scripts=("nacos-setup.sh" "lib/common.sh" "lib/standalone.sh" "lib/cluster.sh" "lib/download.sh" "lib/config_manager.sh" "lib/port_manager.sh" "lib/java_manager.sh" "lib/process_manager.sh")

for script in "${scripts[@]}"; do
    if [ -f "$TEST_DIR/$script" ]; then
        if bash -n "$TEST_DIR/$script"; then
            test_pass "$script - syntax OK"
        else
            test_fail "$script - syntax ERROR"
        fi
    else
        test_fail "$script - file not found"
    fi
done
echo ""

# ============================================================================
# 测试 2: 帮助信息
echo "=== Test Group 2: Help Message ==="
if [ -f "$TEST_DIR/nacos-setup.sh" ]; then
    if bash "$TEST_DIR/nacos-setup.sh" --help >/dev/null 2>&1; then
        test_pass "--help flag works"
    else
        test_fail "--help flag failed"
    fi
else
    test_fail "nacos-setup.sh not found"
fi
echo ""

# ============================================================================
# 测试 3: 参数解析
echo "=== Test Group 3: Argument Parsing ==="

if [ -f "$TEST_DIR/nacos-setup.sh" ]; then
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
else
    test_fail "nacos-setup.sh not found - skipping arg tests"
fi
echo ""

# ============================================================================
# 测试 4: Bug 检查
echo "=== Test Group 4: Bug Verification ==="

# Bug 1: 检查 macOS IP 检测是否使用 ipconfig
if grep -q "ipconfig getifaddr" "$LIB_DIR/common.sh" 2>/dev/null; then
    test_pass "Bug Fix: macOS IP detection uses ipconfig"
else
    test_fail "Bug Fix: macOS IP detection missing ipconfig"
fi

# Bug 2: 检查全局变量声明
if grep -q 'TOKEN_SECRET=""' "$LIB_DIR/standalone.sh" 2>/dev/null; then
    test_pass "Bug Fix: Global vars declared in standalone.sh"
else
    test_fail "Bug Fix: Global vars not declared in standalone.sh"
fi

# Bug 3: 检查目录查找逻辑
if grep -q "maxdepth 2" "$LIB_DIR/download.sh" 2>/dev/null; then
    test_pass "Bug Fix: Directory search depth improved"
else
    test_fail "Bug Fix: Directory search depth not improved"
fi

# Bug 4: 检查节点排序
if grep -q "sort -t'-' -k1,1n" "$LIB_DIR/cluster.sh" 2>/dev/null; then
    test_pass "Bug Fix: Node sorting uses numeric sort"
else
    test_fail "Bug Fix: Node sorting not fixed"
fi

# Bug 5: 检查配置备份函数
if grep -q "backup_config_file" "$LIB_DIR/common.sh" 2>/dev/null; then
    test_pass "Bug Fix: Config backup function added"
else
    test_fail "Bug Fix: Config backup function not added"
fi

# Bug 6: 检查端口检测兼容性（多层级 fallback）
if grep -q "/proc/net/tcp" "$LIB_DIR/port_manager.sh" 2>/dev/null; then
    test_pass "Bug Fix: Port detection has /proc/net/tcp fallback"
else
    test_fail "Bug Fix: Port detection missing fallback methods"
fi

# Bug 7: 检查 Python socket fallback
if grep -q "python.*socket" "$LIB_DIR/port_manager.sh" 2>/dev/null; then
    test_pass "Bug Fix: Port detection has Python socket fallback"
else
    test_fail "Bug Fix: Port detection missing Python fallback"
fi

echo ""

# ============================================================================
# 测试 5: 库函数测试
echo "=== Test Group 5: Library Functions ==="

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
    test_fail "common.sh not found - skipping lib tests"
fi
echo ""

# ============================================================================
# 测试 6: 端口管理
echo "=== Test Group 6: Port Manager ==="

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

# ============================================================================
# 测试 7: 打包脚本
echo "=== Test Group 7: Package Script ==="

if [ -f "$TEST_DIR/package.sh" ]; then
    if bash -n "$TEST_DIR/package.sh"; then
        test_pass "package.sh syntax OK"
    else
        test_fail "package.sh syntax ERROR"
    fi
    
    # 检查命名规则
    if grep -q "nacos-setup-\$VERSION" "$TEST_DIR/package.sh" && \
       grep -q "nacos-setup-windows-\$VERSION" "$TEST_DIR/package.sh"; then
        test_pass "Package naming: Linux=original, Windows=lowercase"
    else
        test_fail "Package naming incorrect"
    fi
else
    test_fail "package.sh not found"
fi
echo ""

# ============================================================================
# 测试 8: --db-conf 功能测试
echo "=== Test Group 8: --db-conf Feature ==="

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
    test_fail "config_manager.sh not found - skipping db-conf tests"
fi

# 测试 db-conf show 命令（不访问网络）
if [ -f "$TEST_DIR/nacos-setup.sh" ]; then
    test_info "Testing db-conf show command (local mode)"
    
    # 测试 db-conf show 不应获取版本（本地模式）
    output=$(bash "$TEST_DIR/nacos-setup.sh" db-conf show 2>&1)
    if echo "$output" | grep -q "Fetching versions"; then
        test_fail "db-conf show should not fetch versions"
    else
        test_pass "db-conf show does not fetch versions (local mode)"
    fi
    
    # 测试 db-conf edit 不应获取版本（本地模式）
    # 使用 echo 模拟用户输入，测试命令不报错
    output=$(echo -e "1\nlocalhost\n3306\nnacos\nroot\npassword" | bash "$TEST_DIR/nacos-setup.sh" db-conf edit /tmp/test_db_conf.properties 2>&1)
    if echo "$output" | grep -q "Fetching versions"; then
        test_fail "db-conf edit should not fetch versions"
    else
        test_pass "db-conf edit does not fetch versions (local mode)"
    fi
    
    # 清理测试文件
    rm -f /tmp/test_db_conf.properties
else
    test_fail "nacos-setup.sh not found - skipping db-conf command tests"
fi
echo ""

# ============================================================================
# 测试摘要
echo "========================================"
echo "   Test Summary"
echo "========================================"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed!"
    exit 1
fi