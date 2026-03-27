#!/bin/bash
#
# Preservation Property Tests - skill-scanner 配置保持性测试
#
# **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**
#
# Property 2: Preservation - 非 skill-scanner 配置行为不受影响
#
# These tests should PASS on both unfixed and fixed code.
# They establish the baseline behavior that must not change after the fix.

source "$(dirname "$0")/common.sh"

echo "=== Preservation Property Tests: skill-scanner config ==="

# Source the libraries we need
source "$LIB_DIR/common.sh"
source "$LIB_DIR/skill_scanner_install.sh"

# ============================================================================
# Test 1: Low version numbers → maybe_install_skill_scanner_for_nacos skips
# (Preservation Requirement 3.1)
# Observed: versions < 3.2.0 return 0 with "skip" trace, no config written
# ============================================================================

echo ""
echo "--- Test 1: Version < 3.2.0 skips installation (Req 3.1) ---"

LOW_VERSIONS=("2.0.0" "3.0.0" "3.1.9" "1.0.0" "2.5.3" "3.1.0" "0.9.9")

ALL_SKIP_PASS=true
for ver in "${LOW_VERSIONS[@]}"; do
    # Create a temp config to verify nothing is written
    T1_DIR=$(mktemp -d)
    T1_CONFIG="$T1_DIR/application.properties"
    touch "$T1_CONFIG"

    # Capture stderr for trace messages
    T1_STDERR=$(maybe_install_skill_scanner_for_nacos "$ver" 2>&1)
    T1_RC=$?

    # Check: return code is 0
    if [ "$T1_RC" -ne 0 ]; then
        test_fail "Test 1: version $ver returned $T1_RC (expected 0)"
        ALL_SKIP_PASS=false
        rm -rf "$T1_DIR"
        continue
    fi

    # Check: trace contains "skip" message
    if ! echo "$T1_STDERR" | grep -q "skip:"; then
        test_fail "Test 1: version $ver did not produce skip trace"
        ALL_SKIP_PASS=false
        rm -rf "$T1_DIR"
        continue
    fi

    rm -rf "$T1_DIR"
done

if [ "$ALL_SKIP_PASS" = true ]; then
    test_pass "Test 1: All low versions (${LOW_VERSIONS[*]}) correctly skip installation"
fi

# ============================================================================
# Test 2: NACOS_SETUP_SKIP_SKILL_SCANNER=1 → skips for any version
# (Preservation Requirement 3.2)
# Observed: returns 0 with "skip: NACOS_SETUP_SKIP_SKILL_SCANNER is set"
# ============================================================================

echo ""
echo "--- Test 2: NACOS_SETUP_SKIP_SKILL_SCANNER=1 skips (Req 3.2) ---"

SKIP_TEST_VERSIONS=("3.2.0" "3.3.0" "4.0.0" "2.0.0" "3.2.0-BETA")

ALL_SKIP_ENV_PASS=true
for ver in "${SKIP_TEST_VERSIONS[@]}"; do
    T2_STDERR=$(NACOS_SETUP_SKIP_SKILL_SCANNER=1 maybe_install_skill_scanner_for_nacos "$ver" 2>&1)
    T2_RC=$?

    if [ "$T2_RC" -ne 0 ]; then
        test_fail "Test 2: SKIP_SKILL_SCANNER=1 with version $ver returned $T2_RC (expected 0)"
        ALL_SKIP_ENV_PASS=false
        continue
    fi

    if ! echo "$T2_STDERR" | grep -q "skip: NACOS_SETUP_SKIP_SKILL_SCANNER is set"; then
        test_fail "Test 2: SKIP_SKILL_SCANNER=1 with version $ver did not produce expected skip trace"
        ALL_SKIP_ENV_PASS=false
        continue
    fi
done

if [ "$ALL_SKIP_ENV_PASS" = true ]; then
    test_pass "Test 2: NACOS_SETUP_SKIP_SKILL_SCANNER=1 correctly skips for all versions (${SKIP_TEST_VERSIONS[*]})"
fi

# ============================================================================
# Test 3: configure_skill_scanner_properties writes base three properties
# (Preservation Requirement 3.5)
# Observed: writes exactly enabled=true, type=skill-scanner,
#           skill-scanner.enabled=true
# ============================================================================

echo ""
echo "--- Test 3: Base three properties always written (Req 3.5) ---"

# Run multiple times to confirm consistency
T3_ALL_PASS=true
for i in 1 2 3; do
    T3_DIR=$(mktemp -d)
    T3_CONFIG="$T3_DIR/application.properties"
    touch "$T3_CONFIG"

    configure_skill_scanner_properties "$T3_CONFIG" 2>/dev/null

    # Check all three base properties
    if ! grep -q "^nacos.plugin.ai-pipeline.enabled=true$" "$T3_CONFIG"; then
        test_fail "Test 3 (run $i): missing nacos.plugin.ai-pipeline.enabled=true"
        T3_ALL_PASS=false
    fi

    if ! grep -q "^nacos.plugin.ai-pipeline.type=skill-scanner$" "$T3_CONFIG"; then
        test_fail "Test 3 (run $i): missing nacos.plugin.ai-pipeline.type=skill-scanner"
        T3_ALL_PASS=false
    fi

    if ! grep -q "^nacos.plugin.ai-pipeline.skill-scanner.enabled=true$" "$T3_CONFIG"; then
        test_fail "Test 3 (run $i): missing nacos.plugin.ai-pipeline.skill-scanner.enabled=true"
        T3_ALL_PASS=false
    fi

    rm -rf "$T3_DIR"
done

# Also test with a config file that already has some content
T3B_DIR=$(mktemp -d)
T3B_CONFIG="$T3B_DIR/application.properties"
cat > "$T3B_CONFIG" << 'EOF'
server.port=8848
nacos.core.auth.enabled=true
EOF

configure_skill_scanner_properties "$T3B_CONFIG" 2>/dev/null

if ! grep -q "^nacos.plugin.ai-pipeline.enabled=true$" "$T3B_CONFIG"; then
    test_fail "Test 3 (existing config): missing nacos.plugin.ai-pipeline.enabled=true"
    T3_ALL_PASS=false
fi
if ! grep -q "^nacos.plugin.ai-pipeline.type=skill-scanner$" "$T3B_CONFIG"; then
    test_fail "Test 3 (existing config): missing nacos.plugin.ai-pipeline.type=skill-scanner"
    T3_ALL_PASS=false
fi
if ! grep -q "^nacos.plugin.ai-pipeline.skill-scanner.enabled=true$" "$T3B_CONFIG"; then
    test_fail "Test 3 (existing config): missing nacos.plugin.ai-pipeline.skill-scanner.enabled=true"
    T3_ALL_PASS=false
fi

# Verify existing properties are preserved
if ! grep -q "^server.port=8848$" "$T3B_CONFIG"; then
    test_fail "Test 3 (existing config): existing server.port was corrupted"
    T3_ALL_PASS=false
fi
if ! grep -q "^nacos.core.auth.enabled=true$" "$T3B_CONFIG"; then
    test_fail "Test 3 (existing config): existing auth config was corrupted"
    T3_ALL_PASS=false
fi

rm -rf "$T3B_DIR"

if [ "$T3_ALL_PASS" = true ]; then
    test_pass "Test 3: configure_skill_scanner_properties always writes base three properties and preserves existing config"
fi

# ============================================================================
# Test 4: _ensure_skill_scanner_in_path PATH search logic
# (Preservation Requirement 3.3)
# Observed: returns 0 when skill-scanner is found in PATH
# ============================================================================

echo ""
echo "--- Test 4: _ensure_skill_scanner_in_path PATH search (Req 3.3) ---"

# Create a mock skill-scanner in a temp dir
T4_MOCK_DIR=$(mktemp -d)
cat > "$T4_MOCK_DIR/skill-scanner" << 'MOCKEOF'
#!/bin/bash
echo "mock skill-scanner"
MOCKEOF
chmod +x "$T4_MOCK_DIR/skill-scanner"

# Save original PATH
T4_ORIG_PATH="$PATH"

# Set PATH to include mock dir
export PATH="$T4_MOCK_DIR:$T4_ORIG_PATH"

_ensure_skill_scanner_in_path
T4_RC=$?

if [ "$T4_RC" -eq 0 ]; then
    test_pass "Test 4: _ensure_skill_scanner_in_path returns 0 when skill-scanner is in PATH"
else
    test_fail "Test 4: _ensure_skill_scanner_in_path returned $T4_RC (expected 0) when skill-scanner is in PATH"
fi

# Restore PATH and cleanup
export PATH="$T4_ORIG_PATH"
rm -rf "$T4_MOCK_DIR"

echo ""
test_summary
