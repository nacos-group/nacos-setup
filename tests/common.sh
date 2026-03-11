#!/bin/bash
#
# Common test utilities - 测试工具函数

set +e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

test_summary() {
    echo "========================================"
    echo "   Test Summary"
    echo "========================================"
    echo "Passed: $PASSED"
    echo "Failed: $FAILED"
    echo ""

    if [ $FAILED -eq 0 ]; then
        echo "All tests passed!"
        return 0
    else
        echo "Some tests failed!"
        return 1
    fi
}

export TEST_DIR LIB_DIR PASSED FAILED
export -f test_info test_pass test_fail test_summary
