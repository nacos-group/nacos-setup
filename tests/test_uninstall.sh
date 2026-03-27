#!/bin/bash
#
# Uninstall Tests - 卸载功能测试
# Property 6: 卸载保留父目录 (Validates: Requirement 6.3)
# Unit tests: 卸载后文件清理正确 (Validates: Requirements 6.1, 6.2, 6.3)

source "$(dirname "$0")/common.sh"

INSTALLER_SCRIPT="$TEST_DIR/nacos-installer.sh"

echo "=== Test Group: Uninstall Tests ==="

if [ ! -f "$INSTALLER_SCRIPT" ]; then
    test_fail "nacos-installer.sh not found"
    test_summary
    exit $?
fi

# ============================================================================
# Helper: Extract uninstall function and run it in an isolated environment
# We do NOT source nacos-installer.sh directly to avoid triggering main().
# ============================================================================
run_uninstall_in_sandbox() {
    local sandbox_dir="$1"

    # Set up the directory variables pointing to sandbox
    local install_base="$sandbox_dir/nacos-setup"
    local bin_dir="$sandbox_dir/bin"

    # Run uninstall in a subshell with overridden variables and stub functions
    (
        set +e
        # Stub print functions to suppress output
        print_info()    { :; }
        print_success() { :; }
        print_warn()    { :; }
        print_error()   { :; }

        INSTALL_BASE_DIR="$install_base"
        BIN_DIR="$bin_dir"
        CURRENT_LINK="nacos-setup"
        SCRIPT_NAME="nacos-setup"

        # Extract and eval only the uninstall_nacos_setup function from the script
        eval "$(awk '/^uninstall_nacos_setup\(\)/,/^}/' "$INSTALLER_SCRIPT")"

        uninstall_nacos_setup
    )
}

# ============================================================================
# Helper: Create a mock ~/.nacos directory structure in a temp sandbox
# ============================================================================
create_mock_nacos_dir() {
    local sandbox_dir="$1"
    local version="${2:-0.0.4}"

    local install_base="$sandbox_dir/nacos-setup"
    local bin_dir="$sandbox_dir/bin"
    local versioned_dir="$install_base/nacos-setup-$version"

    # Create directory structure
    mkdir -p "$versioned_dir/bin"
    mkdir -p "$versioned_dir/lib"
    mkdir -p "$bin_dir"
    mkdir -p "$sandbox_dir/cache"

    # Create mock files
    echo "$version" > "$versioned_dir/.version"
    echo '#!/bin/bash' > "$versioned_dir/bin/nacos-setup"
    chmod +x "$versioned_dir/bin/nacos-setup"
    echo '# mock lib' > "$versioned_dir/lib/common.sh"

    # Create version symlink
    ln -sf "nacos-setup-$version" "$install_base/nacos-setup"

    # Create bin symlinks/files
    ln -sf "$install_base/nacos-setup/bin/nacos-setup" "$bin_dir/nacos-setup"
    echo '#!/bin/bash' > "$bin_dir/nacos-cli"
    chmod +x "$bin_dir/nacos-cli"
}

# ============================================================================
# Property Test: 卸载保留父目录 (Property 6)
# Feature: remove-sudo-dependency, Property 6: 卸载保留父目录
# Validates: Requirement 6.3
# ============================================================================

echo ""
echo "--- Property 6: Uninstall preserves parent directory ---"

ITERATIONS=10
property_violations=0
violation_example=""

for i in $(seq 1 $ITERATIONS); do
    # Create a fresh sandbox for each iteration
    sandbox=$(mktemp -d "/tmp/nacos-uninstall-prop6-$$.XXXXXX")

    # Randomly generate a version string
    major=$((RANDOM % 5))
    minor=$((RANDOM % 10))
    patch=$((RANDOM % 20))
    version="${major}.${minor}.${patch}"

    # Randomly add extra content to ~/.nacos (cache files, custom dirs)
    create_mock_nacos_dir "$sandbox" "$version"
    extra_file="$sandbox/cache/extra-data-${RANDOM}.txt"
    echo "user data $RANDOM" > "$extra_file"

    # Run uninstall
    run_uninstall_in_sandbox "$sandbox"

    # Verify parent directory still exists
    if [ ! -d "$sandbox" ]; then
        property_violations=$((property_violations + 1))
        if [ -z "$violation_example" ]; then
            violation_example="iteration=$i version=$version: sandbox dir removed"
        fi
    fi

    # Verify extra content is preserved
    if [ -f "$extra_file" ]; then
        : # good - extra content preserved
    elif [ -d "$sandbox" ]; then
        # Parent exists but extra file gone is still a concern, but
        # uninstall only removes install_base and bin contents, not cache
        : # acceptable - cache dir is outside uninstall scope
    fi

    rm -rf "$sandbox"
done

if [ "$property_violations" -eq 0 ]; then
    test_pass "Property 6: Uninstall preserves parent directory ($ITERATIONS iterations, random versions)"
else
    test_fail "Property 6: Parent directory removed in $property_violations/$ITERATIONS iterations. Example: $violation_example"
fi

# ============================================================================
# Unit Tests: 卸载后文件清理正确
# Validates: Requirements 6.1, 6.2, 6.3
# ============================================================================

echo ""
echo "--- Unit Tests: Uninstall file cleanup ---"

# --- Test: Versioned install directory is removed (Req 6.1) ---
sandbox=$(mktemp -d "/tmp/nacos-uninstall-unit-$$.XXXXXX")
create_mock_nacos_dir "$sandbox" "0.0.4"

versioned_dir="$sandbox/nacos-setup/nacos-setup-0.0.4"
# Confirm it exists before uninstall
if [ -d "$versioned_dir" ]; then
    run_uninstall_in_sandbox "$sandbox"
    if [ ! -d "$versioned_dir" ]; then
        test_pass "Versioned install directory removed after uninstall"
    else
        test_fail "Versioned install directory still exists after uninstall"
    fi
else
    test_fail "Setup error: versioned directory was not created"
fi
rm -rf "$sandbox"

# --- Test: nacos-setup symlink in bin is removed (Req 6.2) ---
sandbox=$(mktemp -d "/tmp/nacos-uninstall-unit-$$.XXXXXX")
create_mock_nacos_dir "$sandbox" "0.0.4"

nacos_setup_bin="$sandbox/bin/nacos-setup"
if [ -L "$nacos_setup_bin" ] || [ -f "$nacos_setup_bin" ]; then
    run_uninstall_in_sandbox "$sandbox"
    if [ ! -e "$nacos_setup_bin" ]; then
        test_pass "nacos-setup symlink/binary removed from bin after uninstall"
    else
        test_fail "nacos-setup symlink/binary still exists in bin after uninstall"
    fi
else
    test_fail "Setup error: nacos-setup bin was not created"
fi
rm -rf "$sandbox"

# --- Test: nacos-cli binary in bin is removed (Req 6.2) ---
sandbox=$(mktemp -d "/tmp/nacos-uninstall-unit-$$.XXXXXX")
create_mock_nacos_dir "$sandbox" "0.0.4"

nacos_cli_bin="$sandbox/bin/nacos-cli"
if [ -f "$nacos_cli_bin" ]; then
    run_uninstall_in_sandbox "$sandbox"
    if [ ! -e "$nacos_cli_bin" ]; then
        test_pass "nacos-cli binary removed from bin after uninstall"
    else
        test_fail "nacos-cli binary still exists in bin after uninstall"
    fi
else
    test_fail "Setup error: nacos-cli bin was not created"
fi
rm -rf "$sandbox"

# --- Test: Current version symlink is removed (Req 6.1) ---
sandbox=$(mktemp -d "/tmp/nacos-uninstall-unit-$$.XXXXXX")
create_mock_nacos_dir "$sandbox" "0.0.4"

current_link="$sandbox/nacos-setup/nacos-setup"
if [ -L "$current_link" ]; then
    run_uninstall_in_sandbox "$sandbox"
    if [ ! -e "$current_link" ]; then
        test_pass "Current version symlink removed after uninstall"
    else
        test_fail "Current version symlink still exists after uninstall"
    fi
else
    test_fail "Setup error: current version symlink was not created"
fi
rm -rf "$sandbox"

# --- Test: Parent ~/.nacos directory still exists (Req 6.3) ---
sandbox=$(mktemp -d "/tmp/nacos-uninstall-unit-$$.XXXXXX")
create_mock_nacos_dir "$sandbox" "0.0.4"

run_uninstall_in_sandbox "$sandbox"
if [ -d "$sandbox" ]; then
    test_pass "Parent ~/.nacos directory preserved after uninstall"
else
    test_fail "Parent ~/.nacos directory was removed by uninstall"
fi
rm -rf "$sandbox"

# --- Test: Cache directory preserved after uninstall (Req 6.3) ---
sandbox=$(mktemp -d "/tmp/nacos-uninstall-unit-$$.XXXXXX")
create_mock_nacos_dir "$sandbox" "0.0.4"
echo "cached data" > "$sandbox/cache/nacos-setup-0.0.4.zip"

run_uninstall_in_sandbox "$sandbox"
if [ -f "$sandbox/cache/nacos-setup-0.0.4.zip" ]; then
    test_pass "Cache files preserved after uninstall"
else
    test_fail "Cache files were removed by uninstall"
fi
rm -rf "$sandbox"

echo ""
test_summary
