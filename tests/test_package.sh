#!/bin/bash
#
# Package Script Tests - 打包脚本测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Package Script ==="

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
test_summary
