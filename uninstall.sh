#!/bin/bash
# uninstall.sh - Remove aikitoria P2P-patched NVIDIA modules and restore stock driver
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

echo "[nvidia-p2p] Removing patched DKMS modules..."
STOCK_VER=$(dkms status 2>/dev/null | grep "^nvidia/" | head -1 | cut -d/ -f2 | cut -d, -f1)
if [ -n "$STOCK_VER" ]; then
    dkms remove "nvidia/${STOCK_VER}" --all 2>/dev/null || true
    rm -rf "/usr/src/nvidia-${STOCK_VER}"
fi

echo "[nvidia-p2p] Removing IgnorePkg..."
sed -i '/^#.*IgnorePkg.*nvidia-open-dkms/d' /etc/pacman.conf
sed -i 's/ *nvidia-open-dkms//g' /etc/pacman.conf
sed -i 's/ *nvidia-utils//g' /etc/pacman.conf
sed -i 's/ *nvidia-settings//g' /etc/pacman.conf
sed -i 's/ *opencl-nvidia//g' /etc/pacman.conf
sed -i 's/ *lib32-opencl-nvidia//g' /etc/pacman.conf
sed -i 's/ *lib32-nvidia-utils//g' /etc/pacman.conf

echo "[nvidia-p2p] Installing stock nvidia-open-dkms..."
pacman -S --noconfirm --needed nvidia-open-dkms

read -rp "Switch back to pre-built linux-cachyos-*-nvidia-open? [Y/n] " -r
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo "[nvidia-p2p] Switching back to pre-built driver..."
    pacman -R --noconfirm --nosave nvidia-open-dkms
    # Reinstall the same pre-built packages that match installed kernels
    for KDIR in /lib/modules/*-cachyos*; do
        KERNEL=$(basename "$KDIR")
        PKG="linux-${KERNEL}-nvidia-open"
        if pacman -Si "$PKG" &>/dev/null; then
            echo "[nvidia-p2p] Installing ${PKG}..."
            pacman -S --noconfirm --needed "$PKG"
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
systemctl daemon-reload

echo "[nvidia-p2p] Done. Reboot to load stock modules:"
echo "  sudo reboot"
