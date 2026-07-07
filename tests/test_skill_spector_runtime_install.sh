#!/bin/bash
#
# SkillSpector runtime installer tests.

source "$(dirname "$0")/common.sh"

echo "=== Test Group: SkillSpector Runtime Installer ==="

source "$LIB_DIR/common.sh"
source "$LIB_DIR/skill_spector_runtime_install.sh"

TEMP_DIR=$(mktemp -d)
HOME_DIR="$TEMP_DIR/home"
RUNTIME_DIR="$TEMP_DIR/runtime"
CONFIG_FILE="$TEMP_DIR/application.properties"
mkdir -p "$HOME_DIR" "$RUNTIME_DIR/bin"
touch "$CONFIG_FILE"

cat > "$RUNTIME_DIR/bin/skill-spector" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$RUNTIME_DIR/bin/skill-spector"

default_dir=$(HOME="$HOME_DIR" SKILL_SPECTOR_RUNTIME_VERSION=9.9.9 _skill_spector_default_runtime_dir 9.9.9)
if [ "$default_dir" = "$HOME_DIR/ai-infra/ai-pipeline/skill-spector/9.9.9" ]; then
    test_pass "Default runtime dir uses ai-pipeline path"
else
    test_fail "Default runtime dir is incorrect: $default_dir"
fi

cat > "$CONFIG_FILE" << 'EOF'
nacos.plugin.ai-pipeline.type=skill-scanner
EOF

VERSION=3.2.0 SKILL_SPECTOR_RUNTIME_DIR="$RUNTIME_DIR" configure_skill_spector_properties "$CONFIG_FILE"

if grep -q "^nacos.plugin.ai-pipeline.enabled=true$" "$CONFIG_FILE" && \
   grep -q "^nacos.plugin.ai-pipeline.type=skill-scanner,skill-spector$" "$CONFIG_FILE" && \
   grep -q "^nacos.plugin.ai-pipeline.skill-spector.command=$RUNTIME_DIR/bin/skill-spector$" "$CONFIG_FILE"; then
    test_pass "SkillSpector config writes enabled, merged type, and command"
else
    test_fail "SkillSpector config was not written correctly"
fi

if VERSION=3.2.0 SKILL_SPECTOR_RUNTIME_DIR="$RUNTIME_DIR" _skill_spector_should_write_plugin_config; then
    test_pass "SkillSpector config gate allows installed runtime"
else
    test_fail "SkillSpector config gate should allow installed runtime"
fi

if NACOS_SETUP_SKIP_SKILL_SPECTOR=1 VERSION=3.2.0 SKILL_SPECTOR_RUNTIME_DIR="$RUNTIME_DIR" _skill_spector_should_write_plugin_config; then
    test_fail "SkillSpector config gate should honor skip env"
else
    test_pass "SkillSpector config gate honors skip env"
fi

rm -rf "$TEMP_DIR"

echo ""
test_summary
