#!/bin/bash
#
# Java Environment Tests - Java 环境测试

source "$(dirname "$0")/common.sh"

echo "=== Test Group: Java Environment ==="

# 测试 1: 检查 Java 检测函数存在
if [ -f "$LIB_DIR/java_manager.sh" ]; then
    if grep -q "check_java\|detect_java" "$LIB_DIR/java_manager.sh"; then
        test_pass "Java check function exists"
    else
        test_fail "Java check function not found"
    fi
else
    test_fail "java_manager.sh not found"
fi

# 测试 2: 检查 Java 版本解析
if [ -f "$LIB_DIR/java_manager.sh" ]; then
    if grep -q "java.*version\|VERSION" "$LIB_DIR/java_manager.sh"; then
        test_pass "Java version parsing exists"
    else
        test_fail "Java version parsing not found"
    fi
else
    test_fail "java_manager.sh not found"
fi

# 测试 3: 检查 Java 版本要求
if [ -f "$LIB_DIR/java_manager.sh" ]; then
    if grep -q "17\|1.8\|8" "$LIB_DIR/java_manager.sh"; then
        test_pass "Java version requirements defined"
    else
        test_fail "Java version requirements not defined"
    fi
else
    test_fail "java_manager.sh not found"
fi

# 测试 4: 检查单机模式调用 Java 检测
if [ -f "$LIB_DIR/standalone.sh" ]; then
    if grep -q "check_java\|java_manager" "$LIB_DIR/standalone.sh"; then
        test_pass "Standalone mode checks Java"
    else
        test_fail "Standalone mode should check Java"
    fi
else
    test_fail "standalone.sh not found"
fi

# 测试 5: 检查集群模式调用 Java 检测
if [ -f "$LIB_DIR/cluster.sh" ]; then
    if grep -q "check_java\|java_manager" "$LIB_DIR/cluster.sh"; then
        test_pass "Cluster mode checks Java"
    else
        test_fail "Cluster mode should check Java"
    fi
else
    test_fail "cluster.sh not found"
fi

# 测试 6: bundled JDK 下载前应先复用系统扫描到的 Java 17+
tmp_java_dir=$(mktemp -d 2>/dev/null || mktemp -d -t nacos-java-test)
mock_java_home="$tmp_java_dir/jdk-21"
mock_java="$mock_java_home/bin/java"
mkdir -p "$mock_java_home/bin"
printf '%s\n' \
    '#!/bin/sh' \
    'echo "openjdk version \"21.0.2\" 2024-01-16" >&2' \
    'exit 0' > "$mock_java"
chmod +x "$mock_java"

if (
    source "$LIB_DIR/common.sh"

    command() {
        if [ "$1" = "-v" ] && [ "${2:-}" = "java" ]; then
            return 1
        fi
        builtin command "$@"
    }

    search_java_installation() {
        printf '%s\n' "$mock_java"
    }

    resolve_java_home_from_cmd() {
        printf '%s\n' "$mock_java_home"
    }

    unset JAVA_HOME
    source "$LIB_DIR/bundled_jre_install.sh"

    _confirm_bundled_jre_install() {
        return 1
    }

    ensure_bundled_java17_for_nacos_setup "3.2.0" >/dev/null 2>&1 &&
        [ "$JAVA_HOME" = "$mock_java_home" ]
); then
    test_pass "Bundled JDK gate reuses scanned Java 21 before prompting"
else
    test_fail "Bundled JDK gate did not reuse scanned Java 21"
fi
rm -rf "$tmp_java_dir"

echo ""
test_summary
