#!/bin/bash
#
# Nacos Setup Test Suite - 测试运行器
# 运行所有测试用例

set +e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASSED=0
TOTAL_FAILED=0

echo "========================================"
echo "   Nacos Setup Test Suite"
echo "   Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo "========================================"
echo ""

# 测试用例列表
test_cases=(
    "test_syntax.sh:Syntax Check"
    "test_args.sh:Argument Parsing"
    "test_library.sh:Library Functions"
    "test_standalone.sh:Standalone Mode"
    "test_cluster.sh:Cluster Mode"
    "test_security.sh:Security Features"
    "test_java.sh:Java Environment"
    "test_download.sh:Download & Cache"
    "test_dbconf.sh:--db-conf Feature"
    "test_db_schema.sh:db-schema Feature"
    "test_package.sh:Package Script"
    "test_bugs.sh:Bug Verification"
    "test_install_paths.sh:Install Path Constants"
    "test_no_sudo.sh:No Sudo Suggestions"
    "test_skill_scanner_sudo.sh:Skill Scanner Sudo Removal"
    "test_path_management.sh:PATH Management"
    "test_uninstall.sh:Uninstall Cleanup"
)

for test_case in "${test_cases[@]}"; do
    test_script="${test_case%%:*}"
    test_name="${test_case##*:}"

    echo "Running: $test_name"
    echo "----------------------------------------"

    if [ -f "$TEST_DIR/$test_script" ]; then
        # 运行测试并捕获输出
        output=$(bash "$TEST_DIR/$test_script" 2>&1)
        exit_code=$?

        # 提取 Passed/Failed 数量
        passed=$(echo "$output" | grep 'Passed:' | tail -1 | sed 's/.*Passed: //' | tr -dc '0-9' || echo "0")
        failed=$(echo "$output" | grep 'Failed:' | tail -1 | sed 's/.*Failed: //' | tr -dc '0-9' || echo "0")

        TOTAL_PASSED=$((TOTAL_PASSED + passed))
        TOTAL_FAILED=$((TOTAL_FAILED + failed))

        # 显示测试结果
        if [ $exit_code -eq 0 ]; then
            echo "✓ $test_name passed ($passed tests)"
        else
            echo "✗ $test_name failed ($failed tests)"
        fi
    else
        echo "✗ Test script not found: $test_script"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi
    echo ""
done

# 总摘要
echo "========================================"
echo "   Overall Test Summary"
echo "========================================"
echo "Total Passed: $TOTAL_PASSED"
echo "Total Failed: $TOTAL_FAILED"
echo ""

if [ $TOTAL_FAILED -eq 0 ]; then
    echo "All tests passed! ✓"
    exit 0
else
    echo "Some tests failed! ✗"
    exit 1
fi
