#!/bin/bash
# check-p2p-update.sh - Check for new aikitoria P2P patches
set -euo pipefail

REPO_URL="https://github.com/aikitoria/open-gpu-kernel-modules.git"
LOG="/var/log/nvidia-p2p-check.log"

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

# Use installed driver version, not repo version (IgnorePkg may block updates)
INSTALLED_DRIVER=$(pacman -Q nvidia-open-dkms 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//')
if [ -z "$INSTALLED_DRIVER" ]; then
    echo "[nvidia-p2p] ERROR: nvidia-open-dkms is not installed"
    exit 1
fi

# Check if CachyOS repo has a newer driver
REPO_DRIVER=$(pacman -Si nvidia-open-dkms 2>/dev/null | grep "^Version" | awk '{print $2}' | sed 's/-[0-9]*$//')
if [ -z "$REPO_DRIVER" ]; then
    echo "[nvidia-p2p] ERROR: Could not query CachyOS repo"
    exit 1
fi

# Only check if the repo has a newer driver than what's installed
if [ "$(printf '%s\n%s\n' "$REPO_DRIVER" "$INSTALLED_DRIVER" | sort -V | head -n1)" = "$REPO_DRIVER" ] && [ "$REPO_DRIVER" != "$INSTALLED_DRIVER" ]; then
    echo "[nvidia-p2p] CachyOS has newer driver (${REPO_DRIVER}) but we're on ${INSTALLED_DRIVER}"
else
    echo "[nvidia-p2p] Already on latest CachyOS driver: ${INSTALLED_DRIVER}"
    exit 0
fi

# Check if aikitoria has a patch for the newer driver
AIKIT_BRANCHES=$(timeout 30 git ls-remote --heads "${REPO_URL}" 2>/dev/null | grep -oP 'refs/heads/\K[0-9]+\.[0-9]+\.[0-9]+-p2p' | sort -V | uniq || true)
if [ -z "$AIKIT_BRANCHES" ]; then
    echo "[nvidia-p2p] ERROR: Could not query aikitoria branches"
    exit 1
fi

LATEST_PATCH=""
for BRANCH in $AIKIT_BRANCHES; do
    PATCH_VER=$(echo "$BRANCH" | sed 's/-p2p$//')
    if [ "$(printf '%s\n%s\n' "$REPO_DRIVER" "$PATCH_VER" | sort -V | head -n1)" = "$PATCH_VER" ]; then
        LATEST_PATCH="$PATCH_VER"
    fi
done

if [ -z "$LATEST_PATCH" ]; then
    echo "[nvidia-p2p] No aikitoria patch available for driver ${REPO_DRIVER}"
    exit 0
fi

if [ "$LATEST_PATCH" != "$REPO_DRIVER" ]; then
    echo "[nvidia-p2p] aikitoria patch (${LATEST_PATCH}) does not match repo driver (${REPO_DRIVER})"
    exit 0
fi

echo "[nvidia-p2p] UPDATE AVAILABLE: ${INSTALLED_DRIVER} -> ${REPO_DRIVER}"
echo "[nvidia-p2p] Removed IgnorePkg. Run 'pacman -Syu' to update."

# Remove IgnorePkg so the next pacman -Syu will update the driver
# Clean up commented lines and remove all pinned NVIDIA packages (preserving other packages)
sed -i '/^#.*IgnorePkg.*nvidia-open-dkms/d' /etc/pacman.conf
sed -i 's/ *nvidia-open-dkms//g' /etc/pacman.conf
sed -i 's/ *nvidia-utils//g' /etc/pacman.conf
sed -i 's/ *nvidia-settings//g' /etc/pacman.conf
sed -i 's/ *opencl-nvidia//g' /etc/pacman.conf
sed -i 's/ *lib32-opencl-nvidia lib32-nvidia-utils//g' /etc/pacman.conf
