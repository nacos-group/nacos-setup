#!/bin/bash
#
# Nacos Setup Test Suite - 测试入口
# 调用 tests/ 目录下的模块化测试

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 如果 tests/run_all.sh 存在，使用新的模块化测试框架
if [ -f "$TEST_DIR/tests/run_all.sh" ]; then
    bash "$TEST_DIR/tests/run_all.sh"
    exit $?
else
    echo "Error: tests/run_all.sh not found"
    exit 1
fi