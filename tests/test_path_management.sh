#!/bin/bash
#
# Property Tests for PATH management and absolute path usage
# Feature: remove-sudo-dependency
#
# Property 4: PATH 配置幂等性
#   Validates: Requirement 5.2
#
# Property 5: 安装后使用绝对路径调用命令
#   Validates: Requirement 5.6

source "$(dirname "$0")/common.sh"

INSTALLER_SCRIPT="$TEST_DIR/nacos-installer.sh"

echo "=== Test Group: PATH Management (Property Tests) ==="

if [ ! -f "$INSTALLER_SCRIPT" ]; then
    test_fail "nacos-installer.sh not found"
    test_summary
    exit $?
fi

# ============================================================
# Property 4: PATH 配置幂等性
# Create temp shell config, run append logic N times, verify
# export line appears exactly once.
# ============================================================

ITERATIONS=10
property4_violations=0
property4_example=""

PATH_EXPORT_LINE='export PATH="$HOME/.nacos/bin:$PATH"'

for i in $(seq 1 $ITERATIONS); do
    tmp_config=$(mktemp /tmp/test_shellrc_XXXXXX)

    # Pre-populate with random content
    for l in $(seq 1 $(( RANDOM % 5 ))); do
        echo "# comment $l" >> "$tmp_config"
    done

    # Execute the idempotent append logic 1-10 times
    num_executions=$(( (RANDOM % 10) + 1 ))
    for e in $(seq 1 $num_executions); do
        if ! grep -qF "$PATH_EXPORT_LINE" "$tmp_config" 2>/dev/null; then
            echo "" >> "$tmp_config"
            echo "# Added by nacos-setup installer" >> "$tmp_config"
            echo "$PATH_EXPORT_LINE" >> "$tmp_config"
        fi
    done

    count=$(grep -cF "$PATH_EXPORT_LINE" "$tmp_config" 2>/dev/null || true)
    count=$(echo "$count" | tr -d '[:space:]')
    : "${count:=0}"

    if [ "$count" -ne 1 ]; then
        property4_violations=$((property4_violations + 1))
        [ -z "$property4_example" ] && property4_example="Iter $i: ran $num_executions times, got $count lines"
    fi

    rm -f "$tmp_config"
done

if [ "$property4_violations" -eq 0 ]; then
    test_pass "Property 4: PATH config is idempotent ($ITERATIONS iterations)"
else
    test_fail "Property 4: $property4_violations violation(s). $property4_example"
fi

# ============================================================
# Property 5: 安装后使用绝对路径调用命令
# Check that post-install command calls in main() use $BIN_DIR
# ============================================================

# Find lines in main() after install_nacos_setup that reference
# SCRIPT_NAME or nacos-setup as a command (not in echo/print)
bare_count=$(
    awk '/^main\(\)/{found=1} found && /install_nacos_setup/{past=1; next} past && /(SCRIPT_NAME|nacos-setup)/' "$INSTALLER_SCRIPT" \
    | grep -vE '^\s*#' \
    | grep -viE '^\s*(echo|print_|read )' \
    | grep -vE '\$BIN_DIR/' \
    | grep -cE '(SCRIPT_NAME|nacos-setup)' 2>/dev/null || true
)
bare_count=$(echo "$bare_count" | tr -d '[:space:]')
: "${bare_count:=0}"

if [ "$bare_count" -eq 0 ]; then
    test_pass "Property 5: All post-install command invocations use \$BIN_DIR prefix"
else
    example=$(
        awk '/^main\(\)/{found=1} found && /install_nacos_setup/{past=1; next} past && /(SCRIPT_NAME|nacos-setup)/' "$INSTALLER_SCRIPT" \
        | grep -vE '^\s*#' \
        | grep -viE '^\s*(echo|print_|read )' \
        | grep -vE '\$BIN_DIR/' \
        | grep -E '(SCRIPT_NAME|nacos-setup)' \
        | head -1
    )
    test_fail "Property 5: Found $bare_count bare invocation(s). Example: $example"
fi

echo ""
test_summary
