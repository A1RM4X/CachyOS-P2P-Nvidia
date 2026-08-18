#!/bin/bash
# update.sh - Refresh installed scripts without rebuilding DKMS modules.
# Use after `git pull` to deploy updated scripts to a system where
# CachyOS-P2P-Nvidia was already installed. Safe: does NOT touch
# kernel modules, IgnorePkg, or initramfs. Takes a few seconds.
set -euo pipefail

SCRIPT_DIR="/usr/local/bin"
HOOK_DIR="/usr/share/libalpm/hooks"
REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
info()  { echo -e "${GREEN}[nvidia-p2p]${NC} $*"; }
error() { echo -e "${RED}[nvidia-p2p]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Run with sudo"

# --- Sanity: running from a valid repo checkout? ---
for F in check-p2p-update.sh rebuild-nvidia-p2p-driver.sh \
         99-nvidia-p2p-driver.hook nvidia-p2p-check.service nvidia-p2p-check.timer; do
    [ -f "${REPO_PATH}/${F}" ] || error "Missing ${F}. Run this from the CachyOS-P2P-Nvidia repo root."
done

# --- Only proceed if previously installed ---
if [ ! -f "${SCRIPT_DIR}/check-p2p-update.sh" ] && [ ! -f "${SCRIPT_DIR}/rebuild-nvidia-p2p-driver.sh" ]; then
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

deploy "${REPO_PATH}/check-p2p-update.sh"            "${SCRIPT_DIR}/check-p2p-update.sh"
deploy "${REPO_PATH}/rebuild-nvidia-p2p-driver.sh"   "${SCRIPT_DIR}/rebuild-nvidia-p2p-driver.sh"
deploy "${REPO_PATH}/99-nvidia-p2p-driver.hook"      "${HOOK_DIR}/99-nvidia-p2p-driver.hook"
deploy "${REPO_PATH}/nvidia-p2p-check.service"       "/etc/systemd/system/nvidia-p2p-check.service"
deploy "${REPO_PATH}/nvidia-p2p-check.timer"         "/etc/systemd/system/nvidia-p2p-check.timer"

chmod +x "${SCRIPT_DIR}/check-p2p-update.sh" "${SCRIPT_DIR}/rebuild-nvidia-p2p-driver.sh"

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
info "If a new version bumped the driver, run: sudo pacman -Syu && sudo reboot"
