#!/bin/bash
#
# Syntax Check Tests - 语法检查测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Syntax Check ==="

scripts=(
    "nacos-setup.sh"
    "lib/common.sh"
    "lib/standalone.sh"
    "lib/cluster.sh"
    "lib/download.sh"
    "lib/data_import.sh"
    "lib/config_manager.sh"
    "lib/port_manager.sh"
    "lib/java_manager.sh"
    "lib/process_manager.sh"
)

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
test_summary
