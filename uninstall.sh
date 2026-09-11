#!/bin/bash
# uninstall.sh - Remove aikitoria P2P-patched NVIDIA modules and restore stock driver
# Version: 1.1.0
set -euo pipefail

# Shared helpers (IgnorePkg handling).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=p2p-lib.sh
source "${SCRIPT_DIR}/p2p-lib.sh"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

echo "[nvidia-p2p] Removing patched DKMS modules..."
STOCK_VER=$(dkms status 2>/dev/null | grep "^nvidia/" | head -1 | cut -d/ -f2 | cut -d, -f1 | sed 's/:.*//' || true)
if [ -n "$STOCK_VER" ]; then
    dkms remove "nvidia/${STOCK_VER}" --all 2>/dev/null || true
    rm -rf "/usr/src/nvidia-${STOCK_VER}"
fi

# Also clean up any stale 'nvidia-p2p' registrations left from early versions.
STALE_P2P=$(dkms status 2>/dev/null | grep "^nvidia-p2p/" | cut -d/ -f2 | cut -d, -f1 | sed 's/:.*//' | sort -u || true)
for SV in $STALE_P2P; do
    echo "[nvidia-p2p] Removing stale nvidia-p2p/${SV} DKMS registration..."
    dkms remove "nvidia-p2p/${SV}" --all 2>/dev/null || true
    rm -rf "/usr/src/nvidia-p2p-${SV}"
done

echo "[nvidia-p2p] Removing IgnorePkg pins..."
unpin_p2p_packages

echo "[nvidia-p2p] Installing stock nvidia-open-dkms..."
pacman -S --noconfirm --needed nvidia-open-dkms

# Optionally switch back to CachyOS pre-built driver packages.
read -rp "Switch back to pre-built linux-cachyos-*-nvidia-open? [Y/n] " -r
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo "[nvidia-p2p] Switching back to pre-built driver..."
    # Remove stock DKMS first so the pre-built packages can own the module dirs.
    pacman -R --noconfirm --nosave nvidia-open-dkms
    # For each installed CachyOS kernel, find the linux-* package that owns its
    # module directory, then install the matching pre-built driver package
    # (e.g. linux-cachyos-lts -> linux-cachyos-lts-nvidia-open).
    INSTALLED_LINUX=$(pacman -Qq 2>/dev/null | grep -E '^linux-' || true)
    for KD in /lib/modules/*-cachyos*; do
        KERNEL=$(basename "$KD")
        OWNER=""
        for P in $INSTALLED_LINUX; do
            if pacman -Ql "$P" 2>/dev/null | grep -q "/usr/lib/modules/${KERNEL}/"; then
                OWNER="$P"; break
            fi
        done
        [ -n "$OWNER" ] || continue
        PREBUILT="${OWNER}-nvidia-open"
        if pacman -Si "$PREBUILT" &>/dev/null; then
            echo "[nvidia-p2p] Installing ${PREBUILT}..."
            pacman -S --noconfirm --needed "$PREBUILT"
        else
            echo "[nvidia-p2p] NOTE: no pre-built ${PREBUILT} in repo, leaving stock DKMS for this kernel."
        fi
    done
fi

echo "[nvidia-p2p] Removing pacman hooks..."
rm -f /usr/share/libalpm/hooks/99-nvidia-p2p-driver.hook
rm -f /usr/local/bin/rebuild-nvidia-p2p-driver.sh

echo "[nvidia-p2p] Disabling systemd timer..."
systemctl disable --now nvidia-p2p-check.timer 2>/dev/null || true
rm -f /etc/systemd/system/nvidia-p2p-check.timer
rm -f /etc/systemd/system/nvidia-p2p-check.service
rm -f /usr/local/bin/check-p2p-update.sh
rm -f /usr/local/bin/p2p-lib.sh
rm -f /usr/local/bin/verify.sh
rm -f /etc/logrotate.d/nvidia-p2p.conf
systemctl daemon-reload

echo "[nvidia-p2p] Done. Reboot to load stock modules:"
echo "  sudo reboot"
