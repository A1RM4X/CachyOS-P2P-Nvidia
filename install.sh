#!/bin/bash
# install.sh - Install aikitoria P2P-patched NVIDIA modules on CachyOS via DKMS
# Version: 1.1.0
set -euo pipefail

# Shared helpers (patch discovery, dkms.conf, IgnorePkg handling).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=p2p-lib.sh
source "${SCRIPT_DIR}/p2p-lib.sh"

HOOK_DIR="/usr/share/libalpm/hooks"
DEST_DIR="/usr/local/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[nvidia-p2p]${NC} $*"; }
warn()  { echo -e "${YELLOW}[nvidia-p2p]${NC} $*"; }
error() { echo -e "${RED}[nvidia-p2p]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Run with sudo"

command -v clang    &>/dev/null || error "clang not installed: sudo pacman -S clang lld"
command -v git      &>/dev/null || error "git not installed: sudo pacman -S git"
command -v dkms     &>/dev/null || error "dkms not installed: sudo pacman -S dkms"

# --- Concurrency guard: never run two installs at once ---
LOCKFILE="/run/nvidia-p2p-build.lock"
exec 9>"$LOCKFILE"
flock -n 9 || error "Another nvidia-p2p build is already running; try again in a moment."

# --- Switch from pre-built to DKMS driver ---
if ! pacman -Q nvidia-open-dkms &>/dev/null; then
    PREBUILT_PKGS=$(pacman -Qeq 'linux-cachyos-*nvidia-open' 2>/dev/null || true)
    if [ -n "$PREBUILT_PKGS" ]; then
        info "Switching from pre-built driver to nvidia-open-dkms..."
        info "Removing: ${PREBUILT_PKGS}"
        pacman -R --noconfirm --nosave ${PREBUILT_PKGS}
        pacman -S --noconfirm --needed nvidia-open-dkms
        info "DKMS driver installed."
    else
        error "No NVIDIA driver found. Install linux-cachyos-nvidia-open or nvidia-open-dkms first."
    fi
fi

# --- Secure Boot check ---
if [ -f /sys/firmware/efi/efivars ] && command -v mokutil &>/dev/null; then
    MOK_STATE=$(mokutil --sb-state 2>/dev/null || true)
    case "$MOK_STATE" in
        *[Ee]nabled*)
        warn "Secure Boot is enabled. DKMS modules may fail to load."
        warn "Either disable Secure Boot or enroll the MOK key when prompted."
        read -rp "Continue anyway? [y/N] " -r
        # shellcheck disable=SC2317  # error() invoked on the false-branch of [[ ]]
        [[ $REPLY =~ ^[Yy]$ ]] || error "Aborted"
        ;;
    esac
fi

# --- IOMMU passthrough check ---
if ! grep -q "iommu=pt" /proc/cmdline; then
    warn "IOMMU passthrough not detected in kernel cmdline."
    warn "Add 'amd_iommu=on iommu=pt' to your bootloader config."
    read -rp "Continue anyway? [y/N] " -r
    # shellcheck disable=SC2317  # error() invoked on the false-branch of [[ ]]
    [[ $REPLY =~ ^[Yy]$ ]] || error "Aborted"
fi

# --- Find the aikitoria patch matching the installed driver ---
info "Querying aikitoria repo for patches..."
# Use the installed driver version, not the repo version (IgnorePkg may block
# updates, so the repo can be newer than what's actually on disk).
INSTALLED_DRIVER=$(pacman -Q nvidia-open-dkms 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//')
[ -n "$INSTALLED_DRIVER" ] || error "nvidia-open-dkms is not installed. Run: sudo pacman -S nvidia-open-dkms"

LATEST_PATCH=$(find_latest_patch "$INSTALLED_DRIVER" "$AIKIT_REPO_URL")
[ -n "$LATEST_PATCH" ] || error "No aikitoria patch at or below driver version ${INSTALLED_DRIVER}."

# Version equality guard — refuse to install an older patch against newer
# userspace (that yields "Failed to initialize NVML: Driver/library version
# mismatch" on reboot).
if [ "$LATEST_PATCH" != "$INSTALLED_DRIVER" ]; then
    error "aikitoria patch (${LATEST_PATCH}) does not match installed driver (${INSTALLED_DRIVER})."
    error "Installing an older module against newer userspace causes an NVML version mismatch on reboot."
    error "Wait for aikitoria to release a patch for ${INSTALLED_DRIVER}."
fi

REPO_BRANCH="${LATEST_PATCH}-p2p"
info "Using aikitoria patch: ${LATEST_PATCH} (branch: ${REPO_BRANCH})"

# --- Remove existing stock DKMS modules ---
STOCK_VER=$(dkms status 2>/dev/null | grep "^nvidia/" | head -1 | cut -d/ -f2 | cut -d, -f1 | sed 's/:.*//' || true)
if [ -n "$STOCK_VER" ]; then
    info "Removing existing DKMS modules ${STOCK_VER}..."
    dkms remove "nvidia/${STOCK_VER}" --all 2>/dev/null || true
    rm -rf "/usr/src/nvidia-${STOCK_VER}"
fi

# --- Clean up stale 'nvidia-p2p' DKMS registrations ---
# Early versions of this script registered modules under the name 'nvidia-p2p'
# instead of 'nvidia'. Those leftover registrations are broken (unquoted MAKE
# line -> /Kbuild error) and fail on every kernel update. Remove them.
STALE_P2P=$(dkms status 2>/dev/null | grep "^nvidia-p2p/" | cut -d/ -f2 | cut -d, -f1 | sed 's/:.*//' | sort -u || true)
if [ -n "$STALE_P2P" ]; then
    for SV in $STALE_P2P; do
        info "Removing stale nvidia-p2p/${SV} DKMS registration..."
        dkms remove "nvidia-p2p/${SV}" --all 2>/dev/null || true
        rm -rf "/usr/src/nvidia-p2p-${SV}"
    done
fi

# --- Clone aikitoria source ---
DKMS_SRC="/usr/src/nvidia-${LATEST_PATCH}"
info "Installing aikitoria source to ${DKMS_SRC}..."
rm -rf "${DKMS_SRC}"
git clone --branch "${REPO_BRANCH}" --depth 1 "${AIKIT_REPO_URL}" "${DKMS_SRC}"

# --- Generate dkms.conf ---
info "Generating dkms.conf..."
write_dkms_conf "${DKMS_SRC}" "${LATEST_PATCH}"

# --- Register and build with DKMS ---
info "Registering with DKMS..."
dkms add "nvidia/${LATEST_PATCH}"

info "Building patched modules for installed kernels (with headers)..."
BUILT=0
for KDIR in /lib/modules/*; do
    KERNEL=$(basename "$KDIR")
    # A kernel without its -headers package has no build dir; skip it rather than
    # letting DKMS abort the whole install. It will be built on the next kernel
    # update (or right after reboot into it).
    [ -e "$KDIR/build" ] || { warn "Skipping ${KERNEL}: no kernel headers installed."; continue; }
    dkms install "nvidia/${LATEST_PATCH}" -k "$KERNEL" --force
    BUILT=1
done
[ "$BUILT" -eq 1 ] || error "No kernel with headers available to build for. Install linux-cachyos-headers and retry."

# --- Regenerate initramfs ---
info "Regenerating initramfs..."
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

# --- Pin driver and userspace (single source of truth in p2p-lib.sh) ---
info "Pinning driver and userspace via IgnorePkg..."
pin_p2p_packages

# --- Deploy scripts + shared lib ---
info "Installing pacman hook for driver upgrades..."
cp "${SCRIPT_DIR}/p2p-lib.sh"                   "${DEST_DIR}/"
cp "${SCRIPT_DIR}/99-nvidia-p2p-driver.hook"    "${HOOK_DIR}/"
cp "${SCRIPT_DIR}/rebuild-nvidia-p2p-driver.sh" "${DEST_DIR}/"
cp "${SCRIPT_DIR}/verify.sh"                    "${DEST_DIR}/"
chmod +x "${DEST_DIR}/rebuild-nvidia-p2p-driver.sh" "${DEST_DIR}/verify.sh"
cp "${SCRIPT_DIR}/logrotate.conf" /etc/logrotate.d/nvidia-p2p.conf

# --- Install systemd timer for weekly patch checks ---
info "Installing systemd timer for weekly patch checks..."
cp "${SCRIPT_DIR}/nvidia-p2p-check.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/nvidia-p2p-check.timer"   /etc/systemd/system/
cp "${SCRIPT_DIR}/check-p2p-update.sh" "${DEST_DIR}/"
chmod +x "${DEST_DIR}/check-p2p-update.sh"
systemctl daemon-reload
systemctl enable --now nvidia-p2p-check.timer

info "Done. Reboot to load patched modules:"
info "  sudo reboot"
info ""
info "After reboot, verify P2P is working:"
info "  sudo ./verify.sh   # or: nvidia-smi topo -p2p r  (all pairs OK)"
