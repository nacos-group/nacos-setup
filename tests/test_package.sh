#!/bin/bash
#
# Package Script Tests - 打包脚本测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Package Script ==="

if [ -f "$TEST_DIR/package.sh" ]; then
    if bash -n "$TEST_DIR/package.sh"; then
        test_pass "package.sh syntax OK"
    else
        test_fail "package.sh syntax ERROR"
    fi

    # 检查命名规则
    if grep -q "nacos-setup-\$VERSION" "$TEST_DIR/package.sh" && \
       grep -q "nacos-setup-windows-\$VERSION" "$TEST_DIR/package.sh"; then
        test_pass "Package naming: Linux=original, Windows=lowercase"
    else
        test_fail "Package naming incorrect"
    fi
else
    test_fail "package.sh not found"
fi

if [ -f "$TEST_DIR/windows/nacos-installer.ps1" ] && [ -f "$TEST_DIR/versions" ]; then
    cli_version=$(grep '^NACOS_CLI_VERSION=' "$TEST_DIR/versions" | cut -d'=' -f2)
    setup_version=$(grep '^NACOS_SETUP_VERSION=' "$TEST_DIR/versions" | cut -d'=' -f2)
    server_version=$(grep '^NACOS_SERVER_VERSION=' "$TEST_DIR/versions" | cut -d'=' -f2)

    if grep -q "\$DefaultNacosCliVersion    = \"$cli_version\"" "$TEST_DIR/windows/nacos-installer.ps1" && \
       grep -q "\$DefaultNacosSetupVersion  = \"$setup_version\"" "$TEST_DIR/windows/nacos-installer.ps1" && \
       grep -q "\$DefaultNacosServerVersion = \"$server_version\"" "$TEST_DIR/windows/nacos-installer.ps1"; then
        test_pass "Windows installer fallback versions match versions file"
    else
        test_fail "Windows installer fallback versions do not match versions file"
    fi
else
    test_fail "windows/nacos-installer.ps1 or versions file not found"
fi

echo ""
test_summary
