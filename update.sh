#!/bin/bash
# update.sh - Refresh installed scripts without rebuilding DKMS modules.
# Use after `git pull` to deploy updated scripts to a system where
# CachyOS-P2P-Nvidia was already installed. Safe: does NOT touch
# kernel modules, IgnorePkg, or initramfs. Takes a few seconds.
# Version: 1.1.0
set -euo pipefail

DEST_DIR="/usr/local/bin"
HOOK_DIR="/usr/share/libalpm/hooks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[nvidia-p2p]${NC} $*"; }
error() { echo -e "${RED}[nvidia-p2p]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Run with sudo"

# --- Sanity: running from a valid repo checkout? ---
for F in p2p-lib.sh check-p2p-update.sh rebuild-nvidia-p2p-driver.sh \
         99-nvidia-p2p-driver.hook nvidia-p2p-check.service nvidia-p2p-check.timer; do
    [ -f "${SCRIPT_DIR}/${F}" ] || error "Missing ${F}. Run this from the CachyOS-P2P-Nvidia repo root."
done

# --- Only proceed if previously installed ---
if [ ! -f "${DEST_DIR}/check-p2p-update.sh" ] && [ ! -f "${DEST_DIR}/rebuild-nvidia-p2p-driver.sh" ]; then
    error "CachyOS-P2P-Nvidia doesn't appear to be installed. Run install.sh instead."
fi

# --- Deploy files, reporting what changed ---
declare -a CHANGED=()
deploy() {
    local SRC="$1" DEST="$2"
    if ! cmp -s "${SRC}" "${DEST}" 2>/dev/null; then
        cp "${SRC}" "${DEST}"
        CHANGED+=("$(basename "${DEST}")")
    fi
}

deploy "${SCRIPT_DIR}/p2p-lib.sh"                   "${DEST_DIR}/p2p-lib.sh"
deploy "${SCRIPT_DIR}/check-p2p-update.sh"         "${DEST_DIR}/check-p2p-update.sh"
deploy "${SCRIPT_DIR}/rebuild-nvidia-p2p-driver.sh" "${DEST_DIR}/rebuild-nvidia-p2p-driver.sh"
deploy "${SCRIPT_DIR}/verify.sh"                    "${DEST_DIR}/verify.sh"
deploy "${SCRIPT_DIR}/99-nvidia-p2p-driver.hook"    "${HOOK_DIR}/99-nvidia-p2p-driver.hook"
deploy "${SCRIPT_DIR}/logrotate.conf"               "/etc/logrotate.d/nvidia-p2p.conf"
deploy "${SCRIPT_DIR}/nvidia-p2p-check.service"     "/etc/systemd/system/nvidia-p2p-check.service"
deploy "${SCRIPT_DIR}/nvidia-p2p-check.timer"        "/etc/systemd/system/nvidia-p2p-check.timer"

chmod +x "${DEST_DIR}/check-p2p-update.sh" "${DEST_DIR}/rebuild-nvidia-p2p-driver.sh" "${DEST_DIR}/verify.sh"

# --- Reload systemd (always, so enabled/started state is current) ---
systemctl daemon-reload
systemctl enable --now nvidia-p2p-check.timer

# --- Report ---
if [ ${#CHANGED[@]} -eq 0 ]; then
    info "Everything is already up to date. Nothing changed."
else
    info "Updated ${#CHANGED[@]} file(s):"
    for f in "${CHANGED[@]}"; do
        info "  - ${f}"
    done
fi

info "Done. No reboot needed (DKMS modules were not touched)."
info "If a release bumped the driver, follow with: sudo pacman -Syu && sudo reboot"
