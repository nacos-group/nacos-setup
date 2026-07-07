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
    skill_spector_runtime_version=$(grep '^SKILL_SPECTOR_RUNTIME_VERSION=' "$TEST_DIR/versions" | cut -d'=' -f2)

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

if [ -f "$TEST_DIR/lib/versions.sh" ] && [ -f "$TEST_DIR/lib/skill_spector_runtime_install.sh" ]; then
    skill_spector_get_version=$(bash -c "source '$TEST_DIR/lib/versions.sh'; SKILL_SPECTOR_RUNTIME_VERSION='$skill_spector_runtime_version' get_version skill-spector-runtime 0")
    skill_spector_install_default=$(bash -c "source '$TEST_DIR/lib/skill_spector_runtime_install.sh'; SKILL_SPECTOR_RUNTIME_VERSION='$skill_spector_runtime_version' _skill_spector_default_runtime_version")
    skill_spector_usage=$(bash -c "source '$TEST_DIR/lib/skill_spector_runtime_install.sh'; print_skill_spector_install_usage")

    if [ "$skill_spector_get_version" = "$skill_spector_runtime_version" ] && \
       [ "$skill_spector_install_default" = "$skill_spector_runtime_version" ]; then
        test_pass "SkillSpector runtime version uses unified version management"
    else
        test_fail "SkillSpector runtime version is not aligned with unified version management"
    fi

    if echo "$skill_spector_usage" | grep -q "Default: https://download.nacos.io/skill-spector" && \
       echo "$skill_spector_usage" | grep -q "URL/skillspector-runtime-<version>-<platform>.tar.gz" && \
       echo "$skill_spector_usage" | grep -q "~/ai-infra/ai-pipeline/skill-spector/<version>"; then
        test_pass "SkillSpector runtime default download path is skill-spector"
    else
        test_fail "SkillSpector runtime default download path is incorrect"
    fi
else
    test_fail "lib/versions.sh or lib/skill_spector_runtime_install.sh not found"
fi

echo ""
test_summary
