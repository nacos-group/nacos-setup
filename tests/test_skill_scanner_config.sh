#!/bin/bash
#
# Bug Condition Exploration Tests - skill-scanner 配置 bug 探索性测试
#
# **Validates: Requirements 1.1, 1.2, 1.3, 2.1, 2.2, 2.3**
#
# Property 1: Bug Condition - skill-scanner 配置在用户未安装时被错误写入
#
# These tests are EXPECTED TO FAIL on unfixed code.
# Failure confirms the bug exists.
# After the fix is applied, these tests should PASS.

source "$(dirname "$0")/common.sh"

echo "=== Bug Condition Exploration: skill-scanner config ==="

# ============================================================================
# Scenario A: User did NOT install skill-scanner, but skill-scanner is in PATH
#   → standalone.sh and cluster.sh use "command -v skill-scanner" as the gate
#   → Expected on UNFIXED code: grep finds "command -v skill-scanner" used as
#     the condition for calling configure_skill_scanner_properties  → FAIL
#   → Expected on FIXED code: the condition uses SKILL_SCANNER_INSTALLED flag
#     instead of "command -v"  → PASS
# ============================================================================

echo ""
echo "--- Scenario A: command -v skill-scanner used as config-write gate ---"

# A-1: Create a mock skill-scanner in a temp dir and verify command -v finds it
MOCK_DIR=$(mktemp -d)
cat > "$MOCK_DIR/skill-scanner" << 'MOCKEOF'
#!/bin/bash
echo "mock skill-scanner"
MOCKEOF
chmod +x "$MOCK_DIR/skill-scanner"

# Add mock dir to PATH for this test
export PATH="$MOCK_DIR:$PATH"

if command -v skill-scanner >/dev/null 2>&1; then
    test_pass "A-1: mock skill-scanner is discoverable via command -v (precondition)"
else
    test_fail "A-1: mock skill-scanner should be discoverable via command -v"
fi

# A-2: Check standalone.sh — does it use "command -v skill-scanner" as the
#       condition for calling configure_skill_scanner_properties?
#       On UNFIXED code this grep WILL match → we assert it should NOT match.
test_info "A-2: Checking standalone.sh for 'command -v skill-scanner' config gate"
if grep -q 'command -v skill-scanner' "$LIB_DIR/standalone.sh"; then
    # UNFIXED code: the pattern exists → bug confirmed → test FAILS (expected)
    test_fail "A-2: standalone.sh still uses 'command -v skill-scanner' to gate config writes (bug present)"
else
    # FIXED code: pattern replaced with SKILL_SCANNER_INSTALLED check
    test_pass "A-2: standalone.sh no longer uses 'command -v skill-scanner' to gate config writes"
fi

# A-3: Check cluster.sh — same check
test_info "A-3: Checking cluster.sh for 'command -v skill-scanner' config gate"
if grep -q 'command -v skill-scanner' "$LIB_DIR/cluster.sh"; then
    test_fail "A-3: cluster.sh still uses 'command -v skill-scanner' to gate config writes (bug present)"
else
    test_pass "A-3: cluster.sh no longer uses 'command -v skill-scanner' to gate config writes"
fi

# A-4: Verify that standalone.sh uses SKILL_SCANNER_INSTALLED as the condition
test_info "A-4: Checking standalone.sh for SKILL_SCANNER_INSTALLED flag check"
if grep -q 'SKILL_SCANNER_INSTALLED' "$LIB_DIR/standalone.sh"; then
    test_pass "A-4: standalone.sh uses SKILL_SCANNER_INSTALLED flag"
else
    test_fail "A-4: standalone.sh does not use SKILL_SCANNER_INSTALLED flag (fix not applied)"
fi

# A-5: Verify that cluster.sh uses SKILL_SCANNER_INSTALLED as the condition
test_info "A-5: Checking cluster.sh for SKILL_SCANNER_INSTALLED flag check"
if grep -q 'SKILL_SCANNER_INSTALLED' "$LIB_DIR/cluster.sh"; then
    test_pass "A-5: cluster.sh uses SKILL_SCANNER_INSTALLED flag"
else
    test_fail "A-5: cluster.sh does not use SKILL_SCANNER_INSTALLED flag (fix not applied)"
fi

# Cleanup mock
rm -rf "$MOCK_DIR"

# ============================================================================
# Scenario B: configure_skill_scanner_properties does NOT write the
#   nacos.plugin.ai-pipeline.skill-scanner.command property
#   → Expected on UNFIXED code: property missing → FAIL
#   → Expected on FIXED code: property present → PASS
# ============================================================================

echo ""
echo "--- Scenario B: missing skill-scanner.command config property ---"

# Source the libraries we need
source "$LIB_DIR/common.sh"
source "$LIB_DIR/skill_scanner_install.sh"

# B-1: Create a temp application.properties and call configure_skill_scanner_properties
TEMP_DIR=$(mktemp -d)
TEMP_CONFIG="$TEMP_DIR/application.properties"
touch "$TEMP_CONFIG"

test_info "B-1: Calling configure_skill_scanner_properties on temp config file"
configure_skill_scanner_properties "$TEMP_CONFIG"

# Check that the base three properties are written (sanity check)
if grep -q "nacos.plugin.ai-pipeline.enabled=true" "$TEMP_CONFIG" && \
   grep -q "nacos.plugin.ai-pipeline.type=skill-scanner" "$TEMP_CONFIG" && \
   grep -q "nacos.plugin.ai-pipeline.skill-scanner.enabled=true" "$TEMP_CONFIG"; then
    test_pass "B-1: Base three ai-pipeline properties are written (precondition)"
else
    test_fail "B-1: Base three ai-pipeline properties should be written"
fi

# B-2: Check for the missing command property
test_info "B-2: Checking for nacos.plugin.ai-pipeline.skill-scanner.command property"
if grep -q "nacos.plugin.ai-pipeline.skill-scanner.command=" "$TEMP_CONFIG"; then
    test_pass "B-2: skill-scanner.command property is present in config"
else
    test_fail "B-2: skill-scanner.command property is MISSING from config (bug present)"
fi

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
test_summary
