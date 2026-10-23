#!/bin/bash
# verify-boot-chain.sh - Audit every kernel on the Limine boot menu.
#
# Catches the three states in which "reboot" silently lands on a broken
# GPU box (all seen in the wild):
#   STALE   the entry's vmlinuz on the ESP != the installed kernel image
#           (an upgrade whose post-transaction hook was interrupted, e.g. by
#            a reboot during the upgrade)
#   ORPHAN  /usr/lib/modules/<ver> was deleted but the ESP entry still boots
#           that kernel -> zero loadable modules -> ESP mount, LVM and
#           networking all fail, emergency mode
#   NODEV   a kernel on the menu has no nvidia module built for it (DKMS
#           build failed, e.g. pinned driver vs a new kernel API)
#
# Usage: verify-boot-chain.sh [--fix]
#   --fix  for entries that are STALE but whose module tree + GPU driver are
#          intact, re-run the limine mkinitcpio hook for the owning package.
# Exit:  0 clean, 1 problems found, 2 usage/system error.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

CONF="/boot/limine.conf"
[ -f "$CONF" ] || { echo "[nvidia-p2p] ERROR: ${CONF} not found (Limine not installed?)"; exit 2; }

LOG="/var/log/nvidia-p2p-bootchain.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

problems=0
# Parse limine.conf into "label<TAB>version<TAB>vmlinuz-file".
# EFI-fallback entries carry no kernel version and are skipped below.
while IFS=$'\t' read -r label ver file; do
    [ -n "$ver" ] || continue
    entry_stale=0
    esp="/boot${file}"

    if [ ! -f "$esp" ]; then
        echo "[nvidia-p2p] PROBLEM (${label}): ESP image missing: ${esp}"
        problems=$((problems + 1))
        continue
    fi

    # STALE check: does the ESP image match the installed kernel image?
    # (The conf's #hash suffix is BLAKE3 per Limine's integrity scheme, so
    # compare actual bytes via sha256 against the installed vmlinuz instead.)
    ref="/usr/lib/modules/${ver}/vmlinuz"
    if [ -f "$ref" ]; then
        if [ "$(sha256sum "$esp" | awk '{print $1}')" != "$(sha256sum "$ref" | awk '{print $1}')" ]; then
            echo "[nvidia-p2p] STALE (${label}): ${file} on the ESP does not match the installed kernel image"
            problems=$((problems + 1))
            entry_stale=1
        fi
    fi

    if [ ! -d "/usr/lib/modules/${ver}" ]; then
        echo "[nvidia-p2p] ORPHAN (${label}): /usr/lib/modules/${ver} does not exist -"
        echo "[nvidia-p2p]   this entry boots a kernel with NO modules (ESP mount, LVM, networking will fail)."
        problems=$((problems + 1))
    else
        # GPU driver present for this kernel? Check each location separately:
        # 'ls a*' 'b*' with a non-matching pattern returns nonzero even if the
        # other pattern matched (multi-operand ls pitfall).
        if ls "/usr/lib/modules/${ver}"/updates/dkms/nvidia.ko* >/dev/null 2>&1 \
           || ls "/usr/lib/modules/${ver}"/extra/nvidia/nvidia.ko* >/dev/null 2>&1 \
           || grep -qx 'kernel/drivers/video/nvidia' "/usr/lib/modules/${ver}/modules.builtin" 2>/dev/null; then
            :
        else
            echo "[nvidia-p2p] NODEV (${label}): no nvidia module for kernel ${ver} (DKMS build failed?)"
            problems=$((problems + 1))
        fi

        # Auto-heal stale ESP images when the module tree and GPU driver are
        # intact: re-run the limine hook for the owning package.
        if [ "$entry_stale" -eq 1 ] && [ "$FIX" -eq 1 ]; then
            pkg="$(pacman -Qo "/usr/lib/modules/${ver}/modules.builtin" 2>/dev/null || true)"
            HOOK=/usr/share/libalpm/scripts/limine-mkinitcpio-install
            if [ -n "$pkg" ] && [ -f "$HOOK" ]; then
                echo "[nvidia-p2p] FIX (${label}): re-running limine hook for ${pkg}..."
                # The hook reads its kernel targets from STDIN (pacman
                # needs-targets contract); a bare call with argv args does
                # nothing and prints "No kernel found."
                if printf '%s\n' "$pkg" | "$HOOK" >/dev/null 2>&1; then
                    echo "[nvidia-p2p] FIX (${label}): done - rerun verify-boot-chain.sh to confirm."
                else
                    echo "[nvidia-p2p] FIX (${label}): hook failed - inspect manually."
                fi
            fi
        fi
    fi
done < <(awk '
    /^[[:space:]]*\/\//           { label = $1; sub(/^\/+/, "", label) }
    /comment: Kernel version:/    { ver = $4 }
    $1 == "path:" {
        p = $2; sub(/^boot\(\):/, "", p)
        n = split(p, a, "#")
        # label must be non-empty: with an empty leading field the tab-IFS
        # read in bash drops it and every column shifts left.
        if (ver != "" && label != "" && n >= 1) print label "\t" ver "\t" a[1]
        ver = ""
    }
' "$CONF")

if [ "$problems" -eq 0 ]; then
    echo "[nvidia-p2p] Boot chain OK: every menu entry has a matching ESP image, module tree and GPU driver."
    exit 0
fi
echo "[nvidia-p2p] ${problems} problem(s) found."
exit 1
