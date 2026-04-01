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

    # --- download_schema / cache tests ---
    echo ""
    test_info "Testing download_schema cache logic"

    # Test cache hit: pre-populate cache and verify it's used
    TEST_CACHE_DIR="/tmp/test_db_schema_cache"
    mkdir -p "$TEST_CACHE_DIR"
    echo "-- cached mysql schema" > "$TEST_CACHE_DIR/3.2.0-mysql-schema.sql"

    result=$(DB_SCHEMA_CACHE_DIR="$TEST_CACHE_DIR" download_schema "3.2.0" "mysql" 2>/dev/null)
    if [ "$result" = "$TEST_CACHE_DIR/3.2.0-mysql-schema.sql" ]; then
        test_pass "download_schema returns cached file when present"
    else
        test_fail "download_schema cache hit: expected cache path, got '$result'"
    fi

    # Test cache file naming convention
    expected_cache_name="3.2.0-BETA-postgresql-schema.sql"
    result=$(DB_SCHEMA_CACHE_DIR="$TEST_CACHE_DIR" _schema_cache_path "3.2.0-BETA" "postgresql")
    if [ "$(basename "$result")" = "$expected_cache_name" ]; then
        test_pass "Cache file naming: $expected_cache_name"
    else
        test_fail "Cache file naming: expected $expected_cache_name, got $(basename "$result")"
    fi

    rm -rf "$TEST_CACHE_DIR"

    # --- db_schema_main integration tests ---
    echo ""
    test_info "Testing db_schema_main function"

    # Test: stderr/stdout separation — log messages should NOT appear in stdout
    TEST_CACHE_DIR2="/tmp/test_db_schema_main"
    mkdir -p "$TEST_CACHE_DIR2"
    echo "CREATE TABLE test_table (id INT);" > "$TEST_CACHE_DIR2/3.2.0-mysql-schema.sql"

    stdout_output=$(DB_SCHEMA_CACHE_DIR="$TEST_CACHE_DIR2" NACOS_INSTALL_BASE="/tmp/nonexistent" db_schema_main "3.2.0" "mysql" 2>/dev/null)
    if echo "$stdout_output" | grep -q "CREATE TABLE"; then
        test_pass "db_schema_main outputs SQL to stdout"
    else
        test_fail "db_schema_main should output SQL to stdout, got: '$stdout_output'"
    fi

    if echo "$stdout_output" | grep -q "\[INFO\]"; then
        test_fail "db_schema_main should not leak log messages to stdout"
    else
        test_pass "db_schema_main keeps log messages on stderr only"
    fi

    # Test: invalid type reports error
    stderr_output=$(db_schema_main "3.2.0" "oracle" 2>&1 >/dev/null)
    if echo "$stderr_output" | grep -qi "unsupported"; then
        test_pass "db_schema_main reports error for invalid type"
    else
        test_fail "db_schema_main should report unsupported type error"
    fi

    rm -rf "$TEST_CACHE_DIR2"

    # --- nacos-setup.sh integration tests ---
    echo ""
    test_info "Testing nacos-setup.sh db-schema integration"

    if [ -f "$TEST_DIR/nacos-setup.sh" ]; then
        # db-schema should not fetch versions (local mode, like db-conf)
        output=$(bash "$TEST_DIR/nacos-setup.sh" db-schema --type mysql -v 99.99.99 2>&1)
        if echo "$output" | grep -q "Fetching versions"; then
            test_fail "db-schema should not fetch versions"
        else
            test_pass "db-schema does not fetch versions (local mode)"
        fi

        # db-schema with unknown type should fail
        output=$(bash "$TEST_DIR/nacos-setup.sh" db-schema --type oracle -v 3.2.0 2>&1)
        exit_code=$?
        if [ $exit_code -ne 0 ]; then
            test_pass "db-schema exits non-zero for unsupported type"
        else
            test_fail "db-schema should exit non-zero for unsupported type"
        fi

        # db-schema shows in help output
        output=$(bash "$TEST_DIR/nacos-setup.sh" -h 2>&1)
        if echo "$output" | grep -q "db-schema"; then
            test_pass "db-schema appears in help output"
        else
            test_fail "db-schema missing from help output"
        fi
    else
        test_fail "nacos-setup.sh not found"
    fi
else
    test_fail "db_schema.sh not found"
fi

echo ""
test_summary
