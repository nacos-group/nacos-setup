#!/bin/bash
#
# db-schema Feature Tests - 数据库 Schema 导出功能测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: db-schema Feature ==="

# Load db_schema module
if [ -f "$LIB_DIR/db_schema.sh" ]; then
    source "$LIB_DIR/common.sh" 2>/dev/null
    source "$LIB_DIR/db_schema.sh" 2>/dev/null

    # --- validate_db_type tests ---
    test_info "Testing validate_db_type function"

    if validate_db_type "mysql" 2>/dev/null; then
        test_pass "validate_db_type accepts 'mysql'"
    else
        test_fail "validate_db_type should accept 'mysql'"
    fi

    if validate_db_type "postgresql" 2>/dev/null; then
        test_pass "validate_db_type accepts 'postgresql'"
    else
        test_fail "validate_db_type should accept 'postgresql'"
    fi

    if validate_db_type "oracle" 2>/dev/null; then
        test_fail "validate_db_type should reject 'oracle'"
    else
        test_pass "validate_db_type rejects 'oracle'"
    fi

    if validate_db_type "" 2>/dev/null; then
        test_fail "validate_db_type should reject empty string"
    else
        test_pass "validate_db_type rejects empty string"
    fi
else
    test_fail "db_schema.sh not found"
fi

echo ""
test_summary
