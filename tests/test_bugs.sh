#!/bin/bash
#
# Bug Verification Tests - Bug 修复验证测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Bug Verification ==="

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

# Bug 8: 检查 beta 版本比较兼容性
if bash -lc "source \"$LIB_DIR/common.sh\" && version_ge '3.2.0-BETA' '3.2.0'" >/dev/null 2>/dev/null; then
    test_pass "Bug Fix: version_ge handles prerelease suffixes"
else
    test_fail "Bug Fix: version_ge fails on prerelease suffixes"
fi

echo ""
test_summary
