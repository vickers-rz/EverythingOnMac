#!/bin/bash
# ==============================================================================
# EverythingOnMac - Ripgrep Universal Binary Packaging Script
# ==============================================================================
# This script downloads precompiled x86_64 (Intel) and arm64 (Apple Silicon) 
# ripgrep releases and combines them into a single Universal (fat) binary 
# using the macOS 'lipo' utility.
#
# Usage:
#   chmod +x package_rg.sh
#   ./package_rg.sh
# ==============================================================================

set -euo pipefail

RG_VERSION="14.1.0"
WORK_DIR="tmp_rg_build"

echo "=== Starting Ripgrep Packaging Process ==="
echo "Target Ripgrep Version: ${RG_VERSION}"

# 1. Create a clean work directory
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# 2. Download x86_64 (Intel) release
INTEL_TAR="ripgrep-${RG_VERSION}-x86_64-apple-darwin.tar.gz"
echo "Downloading x86_64 release..."
curl -L -O "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${INTEL_TAR}"
tar -xzf "${INTEL_TAR}"
mv "ripgrep-${RG_VERSION}-x86_64-apple-darwin/rg" "rg_x86_64"

# 3. Download arm64 (Apple Silicon) release
ARM_TAR="ripgrep-${RG_VERSION}-aarch64-apple-darwin.tar.gz"
echo "Downloading arm64 release..."
curl -L -O "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${ARM_TAR}"
tar -xzf "${ARM_TAR}"
mv "ripgrep-${RG_VERSION}-aarch64-apple-darwin/rg" "rg_arm64"

# 4. Combine into a Universal Binary using lipo
echo "Combining architectures into a single Universal Binary..."
lipo -create -output "rg" "rg_x86_64" "rg_arm64"

# 5. Verify the architecture of the resulting binary
echo "Verifying build..."
file rg

# 6. Copy binary to the final Resources directory
# In a typical app structure, copy this into the resources build folder
# or Xcode resources group:
# cp rg ../Sources/EverythingOnMac/Resources/rg
echo ""
echo "=== Success! ==="
echo "The universal binary 'rg' is ready at: ${WORK_DIR}/rg"
echo "To package with EverythingOnMac, include this 'rg' file in the App's Resources bundle."
