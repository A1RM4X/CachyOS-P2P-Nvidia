#!/bin/bash
# rebuild-nvidia-p2p-driver.sh - Pacman hook: auto-rebuild patched modules after driver upgrade
# Triggered PostTransaction on nvidia-open-dkms upgrade.
set -euo pipefail

# Shared helpers (patch discovery, dkms.conf, IgnorePkg handling).
# This script is deployed to /usr/local/bin/ next to p2p-lib.sh.
if [ -f "/usr/local/bin/p2p-lib.sh" ]; then
    # shellcheck source=/dev/null
    source /usr/local/bin/p2p-lib.sh
elif [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/p2p-lib.sh" ]; then
    # shellcheck source=/dev/null
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/p2p-lib.sh"
else
    echo "[nvidia-p2p] ERROR: p2p-lib.sh not found (expected at /usr/local/bin/p2p-lib.sh)" >&2
    exit 1
fi

LOG="/var/log/nvidia-p2p-driver-rebuild.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

# Pacman hooks lack network access. Use the local bare mirror maintained by
# check-p2p-update.sh (systemd timer, has network). Fall back to the remote
# URL if the mirror is missing (e.g. fresh install before first timer run).
if [ -d "$MIRROR_DIR" ]; then
    GIT_SRC="$MIRROR_DIR"
else
    GIT_SRC="$AIKIT_REPO_URL"
    echo "[nvidia-p2p] WARNING: local mirror ${MIRROR_DIR} not found, using remote (may fail if network is blocked)"
fi

# --- Concurrency guard: never rebuild while another build is running ---
LOCKFILE="/run/nvidia-p2p-build.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[nvidia-p2p] Another build is in progress; will retry next timer run."; exit 0; }

# Detect the new driver version (installed, not repo).
NEW_VER=$(pacman -Q nvidia-open-dkms 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//')
[ -n "$NEW_VER" ] || { echo "[nvidia-p2p] ERROR: Could not determine new driver version"; exit 1; }

# Does aikitoria have a matching patch?
LATEST_PATCH=$(find_latest_patch "$NEW_VER" "$GIT_SRC" || true)

if [ -z "$LATEST_PATCH" ]; then
    echo "[nvidia-p2p] WARNING: No aikitoria patch for driver ${NEW_VER}. Stock modules will be used."
    # Re-pin IgnorePkg so we don't keep getting updates without patches.
    pin_p2p_packages
    exit 0
fi

if [ "$LATEST_PATCH" != "$NEW_VER" ]; then
    echo "[nvidia-p2p] WARNING: aikitoria patch (${LATEST_PATCH}) does not match installed driver (${NEW_VER})."
    # Re-pin IgnorePkg.
    pin_p2p_packages
    exit 0
fi

echo "[nvidia-p2p] Rebuilding patched modules for driver ${NEW_VER}..."

# Remove old DKMS modules.
OLD_VER=$(dkms status 2>/dev/null | grep "^nvidia/" | head -1 | cut -d/ -f2 | cut -d, -f1 | sed 's/:.*//' || true)
if [ -n "$OLD_VER" ]; then
    dkms remove "nvidia/${OLD_VER}" --all 2>/dev/null || true
    rm -rf "/usr/src/nvidia-${OLD_VER}"
fi

# Clone aikitoria source (from the local mirror - no network needed in hook env).
DKMS_SRC="/usr/src/nvidia-${NEW_VER}"
rm -rf "${DKMS_SRC}"
git clone --branch "${NEW_VER}-p2p" "${GIT_SRC}" "${DKMS_SRC}"

# Generate dkms.conf and build.
write_dkms_conf "${DKMS_SRC}" "${NEW_VER}"
dkms add "nvidia/${NEW_VER}"

# Build for each installed kernel that has headers (skip header-less kernels
# during a kernel transition instead of aborting).
BUILT=0
for KDIR in /lib/modules/*; do
    KERNEL=$(basename "$KDIR")
    [ -e "$KDIR/build" ] || { echo "[nvidia-p2p] Skipping ${KERNEL}: no kernel headers installed."; continue; }
    dkms install "nvidia/${NEW_VER}" -k "$KERNEL" --force
    BUILT=1
done
if [ "$BUILT" -ne 1 ]; then
    echo "[nvidia-p2p] ERROR: No kernel with headers available to build for."
    exit 1
fi

# Regenerate initramfs.
if command -v limine-mkinitcpio &>/dev/null; then
    # limine-mkinitcpio ignores its kernel argument and rebuilds initramfs for
    # EVERY installed kernel, so a single call is enough (looping over kernels
    # made each iteration re-do the full N-kernel rebuild -> N^2).
    limine-mkinitcpio
elif command -v mkinitcpio &>/dev/null; then
    # mkinitcpio DOES honor -k, so rebuild each CachyOS kernel individually.
    for KDIR in /lib/modules/*-cachyos*; do
        KERNEL=$(basename "$KDIR")
        [ -d "${KDIR}/build" ] && mkinitcpio -k "${KERNEL}"
    done
fi

# Re-pin IgnorePkg (stock DKMS was replaced by the hook's trigger, so the
# driver is back in sync and should stay pinned at this version).
pin_p2p_packages

echo "[nvidia-p2p] Success. Reboot to load patched modules."
