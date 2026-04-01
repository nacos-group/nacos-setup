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

    # --- find_local_schema tests ---
    echo ""
    test_info "Testing find_local_schema function"

    # Create fake Nacos install with old-style schema
    OLD_NACOS_HOME="/tmp/test_nacos_old/nacos"
    mkdir -p "$OLD_NACOS_HOME/conf"
    echo "-- old mysql schema" > "$OLD_NACOS_HOME/conf/mysql-schema.sql"

    result=$(NACOS_INSTALL_BASE="/tmp/test_nacos_old" find_local_schema "test" "mysql" 2>/dev/null)
    if [ "$result" = "$OLD_NACOS_HOME/conf/mysql-schema.sql" ]; then
        test_pass "find_local_schema finds old-style schema (conf/)"
    else
        test_fail "find_local_schema old-style: expected $OLD_NACOS_HOME/conf/mysql-schema.sql, got '$result'"
    fi

    # Create fake Nacos install with new-style schema (plugin-ext)
    NEW_NACOS_HOME="/tmp/test_nacos_new/nacos"
    mkdir -p "$NEW_NACOS_HOME/plugin-ext/nacos-datasource-plugin-mysql"
    echo "-- new mysql schema" > "$NEW_NACOS_HOME/plugin-ext/nacos-datasource-plugin-mysql/mysql-schema.sql"

    result=$(NACOS_INSTALL_BASE="/tmp/test_nacos_new" find_local_schema "test" "mysql" 2>/dev/null)
    if [ "$result" = "$NEW_NACOS_HOME/plugin-ext/nacos-datasource-plugin-mysql/mysql-schema.sql" ]; then
        test_pass "find_local_schema finds new-style schema (plugin-ext/)"
    else
        test_fail "find_local_schema new-style: expected plugin-ext path, got '$result'"
    fi

    # New-style takes priority when both exist
    BOTH_NACOS_HOME="/tmp/test_nacos_both/nacos"
    mkdir -p "$BOTH_NACOS_HOME/conf"
    mkdir -p "$BOTH_NACOS_HOME/plugin-ext/nacos-datasource-plugin-mysql"
    echo "-- old" > "$BOTH_NACOS_HOME/conf/mysql-schema.sql"
    echo "-- new" > "$BOTH_NACOS_HOME/plugin-ext/nacos-datasource-plugin-mysql/mysql-schema.sql"

    result=$(NACOS_INSTALL_BASE="/tmp/test_nacos_both" find_local_schema "test" "mysql" 2>/dev/null)
    if [ "$result" = "$BOTH_NACOS_HOME/plugin-ext/nacos-datasource-plugin-mysql/mysql-schema.sql" ]; then
        test_pass "find_local_schema prefers new-style when both exist"
    else
        test_fail "find_local_schema priority: expected new-style path, got '$result'"
    fi

    # Non-existent version returns empty
    result=$(NACOS_INSTALL_BASE="/tmp/test_nacos_nonexistent" find_local_schema "99.99.99" "mysql" 2>/dev/null)
    if [ -z "$result" ]; then
        test_pass "find_local_schema returns empty for non-existent version"
    else
        test_fail "find_local_schema non-existent: expected empty, got '$result'"
    fi

    # Cleanup
    rm -rf /tmp/test_nacos_old /tmp/test_nacos_new /tmp/test_nacos_both
else
    test_fail "db_schema.sh not found"
fi

echo ""
test_summary
