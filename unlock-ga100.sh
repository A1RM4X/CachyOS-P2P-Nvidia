#!/bin/bash
# unlock-ga100.sh - Optional: unlock FP/BF16 issue rate on GA10x (RTX 30-series)
# cards using Zagitta/gpu-unlock (early kmod that runs before nvidia binds).
#
# Usage:
#   sudo ./unlock-ga100.sh          Install the unlock (package + boot opt-in)
#   sudo ./unlock-ga100.sh --remove  Revert everything
#
# Reversible: removing the cmdline param (or the packages) restores stock
# behavior. No VBIOS is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNLOCK_REPO_URL="https://github.com/Zagitta/gpu-unlock"
SRC_DIR="/usr/src/gpu-unlock"
LOCKFILE="/run/gpu-unlock-build.lock"
LIMINE_DROPIN_DIR="/etc/limine-entry-tool.d"
LIMINE_DROPIN="${LIMINE_DROPIN_DIR}/gpu-unlock.conf"
CMDLINE_PARAM="gpu_unlock.targets=all"
MODULES_DROPIN="/etc/mkinitcpio.conf.d/zz-p2p-gpu-unlock.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[gpu-unlock]${NC} $*"; }
warn()  { echo -e "${YELLOW}[gpu-unlock]${NC} $*"; }
error() { echo -e "${RED}[gpu-unlock]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Run with sudo"

case "${1:-}" in
    "")          MODE=install ;;
    --remove)     MODE=remove ;;
    -h|--help)    grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *)           error "Unknown argument: ${1} (expected --remove or --help)" ;;
esac

# Count GA10x GPUs (GA102/GA103/GA104/GA106). The " [...]" part matches the
# VGA/3D controller line only, not the "GA102 High Definition Audio" companion.
command -v lspci &>/dev/null || error "lspci not found: sudo pacman -S pciutils"
ga10x_count() {
    lspci -nn 2>/dev/null | grep -Ec 'GA10[2346] \[' || true
}

rebuild_boot() {
    info "Rebuilding initramfs + regenerating Limine boot entries..."
    if command -v limine-mkinitcpio &>/dev/null; then
        limine-mkinitcpio
    elif command -v mkinitcpio &>/dev/null; then
        for KDIR in /lib/modules/*-cachyos*; do
            KERNEL=$(basename "$KDIR")
            [ -d "${KDIR}/build" ] && mkinitcpio -k "${KERNEL}"
        done
    else
        error "Neither limine-mkinitcpio nor mkinitcpio found."
    fi
}

add_limine_param() {
    command -v limine-entry-tool &>/dev/null ||
        error "limine-entry-tool not found. Add '${CMDLINE_PARAM}' to your kernel cmdline by hand."
    install -d -m 0755 "${LIMINE_DROPIN_DIR}"
    printf '%s\n' "KERNEL_CMDLINE[default]+=${CMDLINE_PARAM}" > "${LIMINE_DROPIN}"
    info "Wrote ${LIMINE_DROPIN} (appends ${CMDLINE_PARAM} to all kernel entries)"
}

print_verify_steps() {
    info ""
    info "Verification after reboot:"
    info "  grep gpu_unlock /proc/cmdline                      # opt-in present"
    info "  journalctl -k -b | grep -i gpu_unlock              # unlock lines per card"
    info ""
    info "Revert at any time:  sudo ${0##*/} --remove   (then reboot)"
}

case "$MODE" in
remove)
    info "Removing gpu-unlock opt-in..."
    if [ -f "${LIMINE_DROPIN}" ]; then
        rm -f "${LIMINE_DROPIN}"
        info "Removed ${LIMINE_DROPIN}"
    fi
    if [ -f "${MODULES_DROPIN}" ]; then
        rm -f "${MODULES_DROPIN}"
        info "Removed ${MODULES_DROPIN}"
    fi
    if pacman -Q gpu-unlock-dkms &>/dev/null || pacman -Q gpu-unlock-firmware &>/dev/null; then
        info "Uninstalling gpu-unlock packages (rebuilds initramfs via hooks)..."
        pacman -R --noconfirm gpu-unlock-dkms gpu-unlock-firmware
    else
        info "Packages not installed; nothing to remove."
    fi
    rebuild_boot
    info "Done. Reboot to drop the unlock:  sudo reboot"
    exit 0
    ;;
esac

# --- Install path ---
GA10X=$(ga10x_count)
if [ "${GA10X:-0}" -eq 0 ]; then
    info "No GA10x (RTX 30-series) cards found; nothing to do."
    exit 0
fi
info "Found ${GA10X} GA10x card(s). Unlocking FP/BF16 issue rate (pre-nvidia, no VBIOS change)..."

exec 9>"$LOCKFILE"
flock -n 9 || error "Another gpu-unlock build is already running; try again in a moment."

# --- Build + install the packages (downloads pinned NVIDIA inputs, ~10 min on
# slow links; firmware is generated locally from the pinned inputs) ---
# makepkg refuses to run as root, so build as the invoking user, then install
# the result as root with pacman -U.
BUILD_USER="${SUDO_USER:-}"
[ -n "${BUILD_USER}" ] || error "Cannot determine the invoking user; run this script via sudo."
for DEP in git python3 zstd; do
    command -v "${DEP}" &>/dev/null || error "${DEP} not installed: sudo pacman -S ${DEP}"
done

if pacman -Q gpu-unlock-dkms &>/dev/null; then
    info "gpu-unlock packages already installed; skipping build."
else
    info "Cloning ${UNLOCK_REPO_URL} to ${SRC_DIR}..."
    rm -rf "${SRC_DIR}"
    git clone --depth 1 "${UNLOCK_REPO_URL}" "${SRC_DIR}"
    chown -R "${BUILD_USER}" "${SRC_DIR}"
    info "Building gpu-unlock as user ${BUILD_USER}. This downloads pinned"
    info "NVIDIA inputs and may take several minutes..."
    sudo -u "${BUILD_USER}" make -C "${SRC_DIR}" arch
    info "Installing packages..."
    pacman -U --noconfirm "${SRC_DIR}/packaging/arch/gpu-unlock-"*.pkg.tar.zst
fi

# --- Compat: strip the optional '?' marker from the package's drop-in ---
# mkinitcpio's systemd-initramfs writer dumps MODULES verbatim (marker and
# all) into the image's /etc/modules-load.d/, so the early loader looks for a
# module literally named 'gpu_unlock?' and fails; the unlock then never runs.
# A plain entry is safe: a missing module for one kernel only means the unlock
# is inert for that kernel (module failure in the initramfs is non-fatal).
if [ -f /etc/mkinitcpio.conf.d/zz-gpu-unlock.conf ]; then
    if grep -q 'gpu_unlock?' /etc/mkinitcpio.conf.d/zz-gpu-unlock.conf; then
        sed -i 's/gpu_unlock?/gpu_unlock/g' /etc/mkinitcpio.conf.d/zz-gpu-unlock.conf
        info "Patched zz-gpu-unlock.conf: stripped the optional '?' marker so the"
        info "module name reaches the initramfs loader cleanly."
    fi
fi

# --- Integration drop-in: finalizes the early MODULES list and blocks nvidia
# --- inside the initramfs so the unlock always runs on free cards.
if [ -f "${SCRIPT_DIR}/zz-p2p-gpu-unlock.conf" ]; then
    install -m 0644 "${SCRIPT_DIR}/zz-p2p-gpu-unlock.conf" "${MODULES_DROPIN}"
    info "Installed ${MODULES_DROPIN} (no early nvidia, single plain gpu_unlock)."
fi

# --- Opt-in: append gpu_unlock.targets=all to the Limine kernel cmdline ---
add_limine_param

# --- Final initramfs rebuild + Limine.conf regeneration ---
# The package's post-install already rebuilt images once; this second pass makes
# sure the new cmdline (from the drop-in above) is in the regenerated
# /boot/limine.conf before the next boot.
rebuild_boot

info "Installed. Reboot to activate:  sudo reboot"
print_verify_steps
