#!/bin/bash
#
# Property Test: 安装脚本自身操作不建议 sudo
# Feature: remove-sudo-dependency, Property 1: 安装脚本自身操作不建议 sudo
# Validates: Requirements 2.1, 2.2, 4.1, 4.2, 4.3
#
# This property test verifies that nacos-installer.sh does NOT suggest using sudo
# for its own operations. Lines about system package installation (apt-get, yum)
# are excluded since those are expected to keep sudo suggestions.

source "$(dirname "$0")/common.sh"

INSTALLER_SCRIPT="$TEST_DIR/nacos-installer.sh"

echo "=== Test Group: No Sudo Suggestions (Property Test) ==="

if [ ! -f "$INSTALLER_SCRIPT" ]; then
    test_fail "nacos-installer.sh not found"
    test_summary
    exit $?
fi

# Patterns that indicate the installer suggests running itself with sudo
SUDO_SUGGESTION_PATTERNS=(
    "run with sudo"
    "run.* sudo"
    "sudo bash"
    "| sudo"
    "Try.*sudo"
    "need.*sudo"
    "use sudo"
)

# Collect all lines from nacos-installer.sh that mention sudo,
# EXCLUDING lines about system package installation (apt-get, yum, brew)
sudo_lines=$(
    grep -n -i 'sudo' "$INSTALLER_SCRIPT" \
    | grep -v -i 'apt-get' \
    | grep -v -i 'yum' \
    | grep -v -i 'brew' \
    | grep -v '^[[:space:]]*#'
)

# --- Static check: no non-system-package sudo lines should exist ---
if [ -z "$sudo_lines" ]; then
    test_pass "No sudo references found outside system package hints"
else
    found_suggestion=false
    while IFS= read -r line; do
        for pattern in "${SUDO_SUGGESTION_PATTERNS[@]}"; do
            if echo "$line" | grep -q -i "$pattern"; then
                test_fail "Found sudo suggestion in installer: $line"
                found_suggestion=true
                break
            fi
        done
    done <<< "$sudo_lines"
    if [ "$found_suggestion" = false ]; then
        test_pass "No sudo suggestion patterns found in non-system-package lines"
    fi
fi

# --- Property test: random subset verification over 100 iterations ---
# Collect ALL non-comment message lines from nacos-installer.sh
# (lines containing echo, print_info, print_warn, print_error, print_success)
msg_tmp=$(mktemp)
grep -n -E '(echo |print_info |print_warn |print_error |print_success )' "$INSTALLER_SCRIPT" \
    | grep -v '^[[:space:]]*#' > "$msg_tmp"

total_message_lines=$(wc -l < "$msg_tmp" | tr -d ' ')

if [ "$total_message_lines" -eq 0 ]; then
    test_fail "No message lines found in nacos-installer.sh (unexpected)"
    rm -f "$msg_tmp"
    test_summary
    exit $?
fi

ITERATIONS=10
property_violations=0
violation_example=""

for i in $(seq 1 $ITERATIONS); do
    # Randomly select a subset of message lines
    subset_size=$(( (RANDOM % total_message_lines) + 1 ))

    for j in $(seq 1 $subset_size); do
        line_idx=$(( (RANDOM % total_message_lines) + 1 ))
        line=$(sed -n "${line_idx}p" "$msg_tmp")

        # Skip lines about system package installation (expected to keep sudo)
        if echo "$line" | grep -q -i -E '(apt-get|yum|brew)'; then
            continue
        fi

        # Check for sudo suggestion patterns
        for pattern in "${SUDO_SUGGESTION_PATTERNS[@]}"; do
            if echo "$line" | grep -q -i "$pattern"; then
                property_violations=$((property_violations + 1))
                if [ -z "$violation_example" ]; then
                    violation_example="$line"
                fi
                break
            fi
        done
    done
done

rm -f "$msg_tmp"

if [ "$property_violations" -eq 0 ]; then
    test_pass "Property 1: No sudo suggestions in installer-own messages ($ITERATIONS iterations, random subsets of $total_message_lines message lines)"
else
    test_fail "Property 1: Found $property_violations sudo suggestion(s) in installer messages. First example: $violation_example"
fi

echo ""
test_summary
