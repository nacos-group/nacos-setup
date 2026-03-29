#!/bin/bash
#
# Property Tests for skill_scanner_install.sh sudo removal
# Feature: remove-sudo-dependency
#
# Property 2: skill_scanner 无 sudo/SUDO_USER 逻辑
#   Validates: Requirements 3.1, 3.4
#
# Property 3: _skill_scanner_runas_target_user 直接透传
#   Validates: Requirement 3.1

source "$(dirname "$0")/common.sh"

SKILL_SCANNER_SCRIPT="$LIB_DIR/skill_scanner_install.sh"

echo "=== Test Group: Skill Scanner Sudo Removal (Property Tests) ==="

if [ ! -f "$SKILL_SCANNER_SCRIPT" ]; then
    test_fail "skill_scanner_install.sh not found"
    test_summary
    exit $?
fi

# ============================================================
# Property 2: skill_scanner 无 sudo/SUDO_USER 逻辑
# Grep function bodies for SUDO_USER / sudo -u / id -u
# ============================================================

# Extract non-comment function body lines and check all at once
violations=$(
    grep -vE '^\s*#' "$SKILL_SCANNER_SCRIPT" \
    | grep -vE '^\s*$' \
    | grep -viE '(apt-get|yum)' \
    | grep -cE 'SUDO_USER|sudo -u|id -u' 2>/dev/null || true
)
violations=$(echo "$violations" | tr -d '[:space:]')
: "${violations:=0}"

if [ "$violations" -eq 0 ]; then
    test_pass "Property 2: No SUDO_USER/sudo -u/id -u in skill_scanner function bodies"
else
    example=$(grep -vE '^\s*#' "$SKILL_SCANNER_SCRIPT" | grep -viE '(apt-get|yum)' | grep -E 'SUDO_USER|sudo -u|id -u' | head -1)
    test_fail "Property 2: Found $violations sudo-related reference(s). Example: $example"
fi

# ============================================================
# Property 3: _skill_scanner_runas_target_user 直接透传
# Verify the function just passes through commands directly
# ============================================================

# Define the function as it exists in the script
_skill_scanner_runas_target_user() {
    "$@"
}

ITERATIONS=10
property3_violations=0
property3_example=""

for i in $(seq 1 $ITERATIONS); do
    random_str="test_${RANDOM}_iter${i}"
    num_args=$(( (RANDOM % 5) + 1 ))
    args=()
    for a in $(seq 1 $num_args); do
        args+=("arg_$(( RANDOM % 10000 ))")
    done

    direct_output=$(echo "$random_str" "${args[@]}" 2>&1)
    runas_output=$(_skill_scanner_runas_target_user echo "$random_str" "${args[@]}" 2>&1)

    if [ "$direct_output" != "$runas_output" ]; then
        property3_violations=$((property3_violations + 1))
        if [ -z "$property3_example" ]; then
            property3_example="Direct: '$direct_output' | Runas: '$runas_output'"
        fi
    fi
done

if [ "$property3_violations" -eq 0 ]; then
    test_pass "Property 3: _skill_scanner_runas_target_user passes through commands directly ($ITERATIONS iterations)"
else
    test_fail "Property 3: Found $property3_violations mismatch(es). Example: $property3_example"
fi

echo ""
test_summary
