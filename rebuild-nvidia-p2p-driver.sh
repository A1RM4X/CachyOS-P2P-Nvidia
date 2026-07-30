#!/bin/bash
# rebuild-nvidia-p2p-driver.sh - Pacman hook: auto-rebuild patched modules after driver upgrade
set -euo pipefail

REPO_URL="https://github.com/aikitoria/open-gpu-kernel-modules.git"
LOG="/var/log/nvidia-p2p-driver-rebuild.log"

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

# Detect new driver version (installed, not repo)
NEW_VER=$(pacman -Q nvidia-open-dkms 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//')
[ -z "$NEW_VER" ] && { echo "[nvidia-p2p] ERROR: Could not determine new driver version"; exit 1; }

# Check if aikitoria has a patch
AIKIT_BRANCHES=$(timeout 30 git ls-remote --heads "${REPO_URL}" 2>/dev/null | grep -oP 'refs/heads/\K[0-9]+\.[0-9]+\.[0-9]+-p2p' | sort -V | uniq || true)
[ -z "$AIKIT_BRANCHES" ] && { echo "[nvidia-p2p] ERROR: Could not query aikitoria branches"; exit 1; }

LATEST_PATCH=""
for BRANCH in $AIKIT_BRANCHES; do
    PATCH_VER=$(echo "$BRANCH" | sed 's/-p2p$//')
    if [ "$(printf '%s\n%s\n' "$NEW_VER" "$PATCH_VER" | sort -V | head -n1)" = "$PATCH_VER" ]; then
        LATEST_PATCH="$PATCH_VER"
    fi
done

if [ -z "$LATEST_PATCH" ]; then
    echo "[nvidia-p2p] WARNING: No aikitoria patch for driver ${NEW_VER}. Stock modules will be used."
    # Re-pin IgnorePkg so we don't keep getting updates without patches
    sed -i '/^#.*IgnorePkg.*nvidia-open-dkms/d' /etc/pacman.conf
    if grep -q "^IgnorePkg" /etc/pacman.conf; then
        if ! grep -q "^IgnorePkg.*nvidia-open-dkms" /etc/pacman.conf; then
            sed -i '0,/^IgnorePkg/{s/^IgnorePkg.*/& nvidia-open-dkms/}' /etc/pacman.conf
        fi
    else
        sed -i '/^\[options\]/a IgnorePkg = nvidia-open-dkms' /etc/pacman.conf
    fi
    exit 0
fi

if [ "$LATEST_PATCH" != "$NEW_VER" ]; then
    echo "[nvidia-p2p] WARNING: aikitoria patch (${LATEST_PATCH}) does not match installed driver (${NEW_VER})."
    # Re-pin IgnorePkg
    sed -i '/^#.*IgnorePkg.*nvidia-open-dkms/d' /etc/pacman.conf
    if grep -q "^IgnorePkg" /etc/pacman.conf; then
        if ! grep -q "^IgnorePkg.*nvidia-open-dkms" /etc/pacman.conf; then
            sed -i '0,/^IgnorePkg/{s/^IgnorePkg.*/& nvidia-open-dkms/}' /etc/pacman.conf
        fi
    else
        sed -i '/^\[options\]/a IgnorePkg = nvidia-open-dkms' /etc/pacman.conf
    fi
    exit 0
fi

echo "[nvidia-p2p] Rebuilding patched modules for driver ${NEW_VER}..."

# Remove old DKMS modules
OLD_VER=$(dkms status 2>/dev/null | grep "^nvidia/" | head -1 | cut -d/ -f2 | cut -d, -f1 || true)
if [ -n "$OLD_VER" ]; then
    dkms remove "nvidia/${OLD_VER}" --all 2>/dev/null || true
    rm -rf "/usr/src/nvidia-${OLD_VER}"
fi

# Clone aikitoria source
DKMS_SRC="/usr/src/nvidia-${NEW_VER}"
rm -rf "${DKMS_SRC}"
git clone --branch "${NEW_VER}-p2p" --depth 1 "${REPO_URL}" "${DKMS_SRC}"

# Generate dkms.conf
cat > "${DKMS_SRC}/dkms.conf" << DKMSCONF
PACKAGE_NAME="nvidia"
PACKAGE_VERSION="${NEW_VER}"
AUTOINSTALL="yes"

MAKE[0]="'make' -j\`nproc\` IGNORE_PREEMPT_RT_PRESENCE=1 IGNORE_CC_MISMATCH=1 objtool=/bin/true NV_EXCLUDE_BUILD_MODULES='' KERNEL_UNAME=\${kernelver} modules"

BUILT_MODULE_NAME[0]="nvidia"
DEST_MODULE_LOCATION[0]="/kernel/drivers/video"
BUILT_MODULE_NAME[1]="nvidia-uvm"
DEST_MODULE_LOCATION[1]="/kernel/drivers/video"
BUILT_MODULE_NAME[2]="nvidia-modeset"
DEST_MODULE_LOCATION[2]="/kernel/drivers/video"
BUILT_MODULE_NAME[3]="nvidia-drm"
DEST_MODULE_LOCATION[3]="/kernel/drivers/video"
BUILT_MODULE_NAME[4]="nvidia-peermem"
DEST_MODULE_LOCATION[4]="/kernel/drivers/video"

BUILT_MODULE_LOCATION[0]="kernel-open"
BUILT_MODULE_LOCATION[1]="kernel-open"
BUILT_MODULE_LOCATION[2]="kernel-open"
BUILT_MODULE_LOCATION[3]="kernel-open"
BUILT_MODULE_LOCATION[4]="kernel-open"

CLEAN="make clean"
DKMSCONF

# Register and build
dkms add "nvidia/${NEW_VER}"
dkms install "nvidia/${NEW_VER}" --force

# Regenerate initramfs
if command -v limine-mkinitcpio &>/dev/null; then
    for KDIR in /lib/modules/*-cachyos*; do
        KERNEL=$(basename "$KDIR")
        [ -d "${KDIR}/build" ] && limine-mkinitcpio "${KERNEL}"
    done
elif command -v mkinitcpio &>/dev/null; then
    for KDIR in /lib/modules/*-cachyos*; do
        KERNEL=$(basename "$KDIR")
        [ -d "${KDIR}/build" ] && mkinitcpio -k "${KERNEL}"
    done
fi

# Re-pin IgnorePkg
sed -i '/^#.*IgnorePkg.*nvidia-open-dkms/d' /etc/pacman.conf
if grep -q "^IgnorePkg" /etc/pacman.conf; then
    if ! grep -q "^IgnorePkg.*nvidia-open-dkms" /etc/pacman.conf; then
        sed -i '0,/^IgnorePkg/{s/^IgnorePkg.*/& nvidia-open-dkms/}' /etc/pacman.conf
    fi
else
    sed -i '/^\[options\]/a IgnorePkg = nvidia-open-dkms' /etc/pacman.conf
fi

echo "[nvidia-p2p] Success. Reboot to load patched modules."
