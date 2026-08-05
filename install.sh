#!/bin/bash
# install.sh - Install aikitoria P2P-patched NVIDIA modules on CachyOS via DKMS
# Version: 1.0.0
set -euo pipefail

REPO_URL="https://github.com/aikitoria/open-gpu-kernel-modules.git"
HOOK_DIR="/usr/share/libalpm/hooks"
SCRIPT_DIR="/usr/local/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[nvidia-p2p]${NC} $*"; }
warn()  { echo -e "${YELLOW}[nvidia-p2p]${NC} $*"; }
error() { echo -e "${RED}[nvidia-p2p]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Run with sudo"

command -v clang    &>/dev/null || error "clang not installed: sudo pacman -S clang lld"
command -v git      &>/dev/null || error "git not installed: sudo pacman -S git"
command -v dkms     &>/dev/null || error "dkms not installed: sudo pacman -S dkms"

# --- Switch from pre-built to DKMS driver ---
if ! pacman -Q nvidia-open-dkms &>/dev/null; then
    # Find all installed pre-built nvidia-open packages
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
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "Secure Boot is enabled. DKMS modules may fail to load."
        warn "Either disable Secure Boot or enroll the MOK key when prompted."
        read -rp "Continue anyway? [y/N] " -r
        [[ $REPLY =~ ^[Yy]$ ]] || error "Aborted"
    fi
fi

# --- IOMMU passthrough check ---
if ! grep -q "iommu=pt" /proc/cmdline; then
    warn "IOMMU passthrough not detected in kernel cmdline."
    warn "Add 'amd_iommu=on iommu=pt' to your bootloader config."
    read -rp "Continue anyway? [y/N] " -r
    [[ $REPLY =~ ^[Yy]$ ]] || error "Aborted"
fi

# --- Find latest aikitoria patch ---
info "Querying aikitoria repo for patches..."
AIKIT_BRANCHES=$(timeout 30 git ls-remote --heads "${REPO_URL}" 2>/dev/null | grep -oP 'refs/heads/\K[0-9]+\.[0-9]+\.[0-9]+-p2p' | sort -V | uniq || true)
[ -z "$AIKIT_BRANCHES" ] && error "Could not query aikitoria branches."

# Use installed driver version, not repo version (IgnorePkg may block updates)
INSTALLED_DRIVER=$(pacman -Q nvidia-open-dkms 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//')
[ -z "$INSTALLED_DRIVER" ] && error "nvidia-open-dkms is not installed. Run: sudo pacman -S nvidia-open-dkms"

LATEST_PATCH=""
for BRANCH in $AIKIT_BRANCHES; do
    PATCH_VER=$(echo "$BRANCH" | sed 's/-p2p$//')
    if [ "$(printf '%s\n%s\n' "$INSTALLED_DRIVER" "$PATCH_VER" | sort -V | head -n1)" = "$PATCH_VER" ]; then
        LATEST_PATCH="$PATCH_VER"
    fi
done
[ -z "$LATEST_PATCH" ] && error "No aikitoria patch available for driver version ${INSTALLED_DRIVER}."

# Version equality guard — refuse to install older patch against newer userspace
if [ "$LATEST_PATCH" != "$INSTALLED_DRIVER" ]; then
    error "aikitoria patch (${LATEST_PATCH}) does not match installed driver (${INSTALLED_DRIVER})."
    error "Installing an older module against newer userspace causes NVML version mismatch on reboot."
    error "Wait for aikitoria to release a patch for ${INSTALLED_DRIVER}."
fi

REPO_BRANCH="${LATEST_PATCH}-p2p"
info "Using aikitoria patch: ${LATEST_PATCH} (branch: ${REPO_BRANCH})"

# --- Remove existing DKMS modules ---
STOCK_VER=$(dkms status 2>/dev/null | grep "^nvidia/" | head -1 | cut -d/ -f2 | cut -d, -f1)
if [ -n "$STOCK_VER" ]; then
    info "Removing existing DKMS modules ${STOCK_VER}..."
    dkms remove "nvidia/${STOCK_VER}" --all 2>/dev/null || true
    rm -rf "/usr/src/nvidia-${STOCK_VER}"
fi

# --- Clone aikitoria source ---
DKMS_SRC="/usr/src/nvidia-${LATEST_PATCH}"
info "Installing aikitoria source to ${DKMS_SRC}..."
rm -rf "${DKMS_SRC}"
git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${DKMS_SRC}"

# --- Generate dkms.conf ---
info "Generating dkms.conf..."
cat > "${DKMS_SRC}/dkms.conf" << DKMSCONF
PACKAGE_NAME="nvidia"
PACKAGE_VERSION="${LATEST_PATCH}"
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

# --- Register and build with DKMS ---
info "Registering with DKMS..."
dkms add "nvidia/${LATEST_PATCH}"

info "Building patched modules for all installed kernels..."
dkms install "nvidia/${LATEST_PATCH}" --force

# --- Regenerate initramfs ---
info "Regenerating initramfs..."
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

# --- Pin driver and userspace ---
info "Pinning driver and userspace via IgnorePkg..."
sed -i '/^#.*IgnorePkg.*nvidia-open-dkms/d' /etc/pacman.conf
if grep -q "^IgnorePkg" /etc/pacman.conf; then
    for PKG in nvidia-open-dkms nvidia-utils nvidia-settings opencl-nvidia lib32-opencl-nvidia; do
        if ! grep -q "^IgnorePkg.*${PKG}" /etc/pacman.conf; then
            sed -i '0,/^IgnorePkg/{s/^IgnorePkg.*/& '${PKG}'/}' /etc/pacman.conf
        fi
    done
else
    sed -i '/^\[options\]/a IgnorePkg = nvidia-open-dkms nvidia-utils nvidia-settings opencl-nvidia lib32-opencl-nvidia' /etc/pacman.conf
fi

# --- Install pacman hook for auto-rebuild on driver upgrade ---
info "Installing pacman hook for driver upgrades..."
REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "${REPO_PATH}/99-nvidia-p2p-driver.hook" "${HOOK_DIR}/"
cp "${REPO_PATH}/rebuild-nvidia-p2p-driver.sh" "${SCRIPT_DIR}/"
chmod +x "${SCRIPT_DIR}/rebuild-nvidia-p2p-driver.sh"

# --- Install systemd timer for weekly patch checks ---
info "Installing systemd timer for weekly patch checks..."
cp "${REPO_PATH}/nvidia-p2p-check.service" /etc/systemd/system/
cp "${REPO_PATH}/nvidia-p2p-check.timer" /etc/systemd/system/
cp "${REPO_PATH}/check-p2p-update.sh" "${SCRIPT_DIR}/"
chmod +x "${SCRIPT_DIR}/check-p2p-update.sh"
systemctl daemon-reload
systemctl enable --now nvidia-p2p-check.timer

info "Done. Reboot to load patched modules:"
info "  sudo reboot"
info ""
info "After reboot, verify P2P is working:"
info "  nvidia-smi topo -p2p r"
info "  All pairs should show OK."
