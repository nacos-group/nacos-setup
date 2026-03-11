#!/usr/bin/env bash

set -euo pipefail

# package.sh - create nacos-setup-Linux-VERSION.zip and nacos-setup-Windows-VERSION.zip
# Usage: ./package.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# ============================================================================
# Version Configuration - MODIFY THIS TO CHANGE VERSION
# ============================================================================
DEFAULT_VERSION="0.0.2"

print() { echo "[package] $*"; }

usage() {
    cat <<EOF
Usage: $0 [version]

If version is not provided, uses DEFAULT_VERSION defined in this script: $DEFAULT_VERSION

Output: 
  ./dist/nacos-setup-VERSION.zip (Linux/macOS)
  ./dist/nacos-setup-windows-VERSION.zip
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

# Use command line argument if provided, otherwise use default version
VERSION="${1:-$DEFAULT_VERSION}"

if [ -z "$VERSION" ]; then
    echo "[package] Error: No version specified"
    echo "Either modify DEFAULT_VERSION in this script or provide version as argument: ./package.sh 1.2.3"
    exit 1
fi

DIST_DIR="$PROJECT_ROOT/dist"
mkdir -p "$DIST_DIR"

# ====================
# Package Linux version (also for macOS)
# ====================
package_linux() {
    local name="nacos-setup-$VERSION"
    local tmp_dir="/tmp/${name}-package-$$"
    
    print "Packaging Linux version: $VERSION"
    print "Staging to: $tmp_dir"
    
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir/$name"
    
    # Linux files only (exclude installer and Windows files)
    local include=("nacos-setup.sh" "lib" "README.md" "LICENSE")
    
    for f in "${include[@]}"; do
        if [ -e "$PROJECT_ROOT/$f" ]; then
            cp -a "$PROJECT_ROOT/$f" "$tmp_dir/$name/"
        else
            print "Warning: $f not found, skipping"
        fi
    done
    
    # Ensure scripts are executable
    if [ -d "$tmp_dir/$name/lib" ]; then
        chmod +x "$tmp_dir/$name/lib"/*.sh 2>/dev/null || true
    fi
    if [ -f "$tmp_dir/$name/nacos-setup.sh" ]; then
        chmod +x "$tmp_dir/$name/nacos-setup.sh" 2>/dev/null || true
    fi
    
    pushd "$tmp_dir" >/dev/null
    local zipfile="$DIST_DIR/${name}.zip"
    print "Creating zip: $zipfile"
    zip -r -q "$zipfile" "$name"
    popd >/dev/null
    
    # Verify
    if unzip -tqq "$zipfile" >/dev/null 2>&1; then
        print "Linux package verified: OK"
    else
        print "Linux package verification: FAILED"
        exit 1
    fi
    
    rm -rf "$tmp_dir"
    print "Linux package: $zipfile"
}

# ====================
# Package Windows version
# ====================
package_windows() {
    local name="nacos-setup-windows-$VERSION"
    local tmp_dir="/tmp/${name}-package-$$"
    
    print "Packaging Windows version: $VERSION"
    print "Staging to: $tmp_dir"
    
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir/$name"
    
    # Windows files only (exclude nacos-installer.ps1)
    if [ -d "$PROJECT_ROOT/windows" ]; then
        # Copy all files from windows directory except nacos-installer.ps1
        for item in "$PROJECT_ROOT/windows"/*; do
            local basename=$(basename "$item")
            if [ "$basename" != "nacos-installer.ps1" ]; then
                cp -a "$item" "$tmp_dir/$name/"
            fi
        done
    else
        print "Error: windows directory not found"
        exit 1
    fi
    
    # Also explicitly remove any installer files from temp dir
    rm -f "$tmp_dir/$name/nacos-installer.ps1" 2>/dev/null || true
    
    # Copy shared documentation
    cp "$PROJECT_ROOT/README.md" "$tmp_dir/$name/" 2>/dev/null || true
    cp "$PROJECT_ROOT/LICENSE" "$tmp_dir/$name/" 2>/dev/null || true
    
    pushd "$tmp_dir" >/dev/null
    local zipfile="$DIST_DIR/${name}.zip"
    print "Creating zip: $zipfile"
    zip -r -q "$zipfile" "$name"
    popd >/dev/null
    
    # Verify
    if unzip -tqq "$zipfile" >/dev/null 2>&1; then
        print "Windows package verified: OK"
    else
        print "Windows package verification: FAILED"
        exit 1
    fi
    
    rm -rf "$tmp_dir"
    print "Windows package: $zipfile"
}

# ====================
# Main
# ====================
print "========================================"
print "Packaging Nacos Setup v$VERSION"
print "========================================"
echo ""

package_linux
echo ""
package_windows

echo ""
print "========================================"
print "All packages created successfully!"
print "========================================"
print "Output directory: $DIST_DIR"
ls -lh "$DIST_DIR"/*.zip

exit 0
