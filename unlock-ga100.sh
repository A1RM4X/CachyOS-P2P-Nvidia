#!/bin/bash
# unlock-ga100.sh - Optional: unlock the FP/BF16 issue rate on NVIDIA
# 20/30/40-series cards using Zagitta/gpu-unlock (early kmod that runs
# before nvidia binds). Filename kept from the 30-series-only days.
#
# Usage:
#   sudo ./unlock-ga100.sh          Install the unlock (package + boot opt-in)
#   sudo ./unlock-ga100.sh --yes    Same, skipping the interactive confirmation
#   sudo ./unlock-ga100.sh --remove  Revert everything
#
# Build source: the vendored packaging/p2p-gpu-unlock/PKGBUILD in this repo,
# pinned to an exact upstream commit (sha256-checked tarball) with sha256-
# pinned NVIDIA inputs. Upgrades happen by bumping that pin in a visible diff;
# upstream HEAD is never pulled implicitly.
#
# Package names are p2p-gpu-unlock-* deliberately: they never match the AUR
# gpu-unlock-* names, so AUR helpers (paru etc.) do not track or offer
# upgrades for them. --remove cleans both namespaces.
#
# Reversible: removing the cmdline param (or the packages) restores stock
# behavior. No VBIOS is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKGBUILD_DIR="${SCRIPT_DIR}/packaging/p2p-gpu-unlock"
BUILD_DIR="/usr/src/p2p-gpu-unlock"
LOCKFILE="/run/gpu-unlock-build.lock"
LIMINE_DROPIN_DIR="/etc/limine-entry-tool.d"
LIMINE_DROPIN="${LIMINE_DROPIN_DIR}/gpu-unlock.conf"
CMDLINE_PARAM="gpu_unlock.targets=all"
MODULES_DROPIN="/etc/mkinitcpio.conf.d/zz-p2p-gpu-unlock.conf"
PKG_DKMS="p2p-gpu-unlock-dkms"
PKG_FW="p2p-gpu-unlock-firmware"
# AUR / pre-rename names: --remove and migration both cover these.
LEGACY_PKGS=(gpu-unlock-dkms gpu-unlock-firmware)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[gpu-unlock]${NC} $*"; }
warn()  { echo -e "${YELLOW}[gpu-unlock]${NC} $*"; }
error() { echo -e "${RED}[gpu-unlock]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Run with sudo"

case "${1:-}" in
    "")          MODE=install ;;
    --yes)       MODE=install; ASSUME_YES=1 ;;
    --remove)     MODE=remove ;;
    -h|--help)    grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *)           error "Unknown argument: ${1} (expected --yes, --remove or --help)" ;;
esac

# --- GPU detection ---------------------------------------------------------
# Chip names appear in `lspci -nn` lines like "NVIDIA Corporation GA102
# [GeForce RTX 3090] (rev a1)" — the "[...]" part matches the VGA/3D
# controller line only, not the "GA102 High Definition Audio" companion.
#   GA10x = Ampere RTX 30 (stable upstream)
#   AD10x = Ada RTX 40, TU10x = Turing RTX 20 (both EXPERIMENTAL upstream)
#   GB20x = Blackwell RTX 50 (NOT supported — noted and skipped)
command -v lspci &>/dev/null || error "lspci not found: sudo pacman -S pciutils"
count_chips() {
    local n
    n=$(lspci -nn 2>/dev/null | grep -Ec "$1 \[" || true)
    echo "${n:-0}"
}
N_SUPPORTED=$(count_chips '(GA10[23467]|AD10[2-7]|TU10[246])')
N_EXPERIMENTAL=$(count_chips '(AD10[2-7]|TU10[246])')
N_BLACKWELL=$(count_chips '(GB20[2356])')

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
    present=()
    for P in "${PKG_DKMS}" "${PKG_FW}" "${LEGACY_PKGS[@]}"; do
        pacman -Q "${P}" &>/dev/null && present+=("${P}")
    done
    if [ "${#present[@]}" -gt 0 ]; then
        info "Uninstalling: ${present[*]} (rebuilds initramfs via hooks)..."
        pacman -R --noconfirm "${present[@]}"
    else
        info "No gpu-unlock packages installed (p2p or AUR names); boot files only."
    fi
    rebuild_boot
    info "Done. Reboot to drop the unlock:  sudo reboot"
    exit 0
    ;;
esac

# --- Install path -----------------------------------------------------------
if [ "${N_SUPPORTED:-0}" -eq 0 ]; then
    if [ "${N_BLACKWELL:-0}" -gt 0 ]; then
        info "Only RTX 50-series (Blackwell) cards found; not supported by gpu-unlock. Nothing to do."
    else
        info "No supported NVIDIA cards (RTX 20/30/40-series) found; nothing to do."
    fi
    exit 0
fi
info "Found ${N_SUPPORTED} supported card(s). Unlocking FP/BF16 issue rate (pre-nvidia, no VBIOS change)..."
if [ "${N_EXPERIMENTAL:-0}" -gt 0 ]; then
    warn "Note: Ada (RTX 40) / Turing (RTX 20) support is EXPERIMENTAL upstream."
fi
if [ "${N_BLACKWELL:-0}" -gt 0 ]; then
    warn "RTX 50-series (Blackwell) card(s) ignored: unsupported upstream."
fi

# --- Disclaimer + explicit confirmation (hardware-level tweak) ---
# --yes is only valid for the install.sh flow, which asks its own prompt;
# direct interactive runs must always confirm; non-interactive direct runs
# are refused so nobody gets the tweak without seeing this.
cat <<'EOF'
WARNING — read before continuing:
The GPU unlock raises the FP/BF16 issue rate of supported NVIDIA cards.
Depending on your power limits, cooling and workload, the cards may then
run at higher clocks and draw more power than before.

- You apply this tweak at your own responsibility.
- After enabling it, verify that temperatures, clocks and power draw are
  in a normal range for your hardware under your usual workload, e.g.:
      nvidia-smi -q -d THERMAL,POWER
      nvidia-smi -q -d CLOCK
- If any card overheats, throttles abnormally or becomes unstable, revert:
      sudo ./unlock-ga100.sh --remove && sudo reboot

The unlock is provided as-is, without warranty of any kind.
EOF

if [ -n "${ASSUME_YES:-}" ]; then
    info "Continuing (confirmed via --yes)..."
elif [ -t 0 ]; then
    read -rp "Apply the GPU unlock? [y/N] " -r CONFIRM </dev/tty || CONFIRM=""
    case "${CONFIRM:-}" in
        [Yy]*) ;;
        *) info "Aborted; nothing was changed."; exit 0 ;;
    esac
else
    error "Non-interactive run: re-run interactively, or pass --yes if you already confirmed."
fi

exec 9>"$LOCKFILE"
flock -n 9 || error "Another gpu-unlock build is already running; try again in a moment."

# --- Build + install the packages ---
# makepkg refuses to run as root, so build as the invoking user, then install
# as root with pacman -U. All sources are pinned (exact upstream commit,
# sha256 NVIDIA inputs); the download is the pinned tarball plus the two
# NVIDIA inputs (~325 MB) on first build.
BUILD_USER="${SUDO_USER:-}"
[ -n "${BUILD_USER}" ] || error "Cannot determine the invoking user; run this script via sudo."
for DEP in python3 zstd; do
    command -v "${DEP}" &>/dev/null || error "${DEP} not installed: sudo pacman -S ${DEP}"
done

PKGVER_EXPECTED="$(awk -F= '/^pkgver=/{print $2}' "${PKGBUILD_DIR}/PKGBUILD")-$(awk -F= '/^pkgrel=/{print $2}' "${PKGBUILD_DIR}/PKGBUILD")"
INSTALLED="$(pacman -Q "${PKG_DKMS}" 2>/dev/null | awk 'NR==1{print $2}' || true)"

if [ -n "${INSTALLED}" ] && [ "${INSTALLED}" = "${PKGVER_EXPECTED}" ]; then
    info "${PKG_DKMS} ${INSTALLED} already installed; skipping build."
else
    [ -z "${INSTALLED}" ] || info "${PKG_DKMS} ${INSTALLED} installed; upgrading to ${PKGVER_EXPECTED}..."
    # Pre-remove legacy (AUR-named / pre-rename) installs before the -U:
    # a bare `pacman -U` hits an interactive "Remove <pkg>?" conflict prompt
    # that even --noconfirm does not auto-answer, which breaks unattended runs.
    legacy_present=()
    for L in "${LEGACY_PKGS[@]}"; do
        pacman -Q "${L}" &>/dev/null && legacy_present+=("${L}")
    done
    if [ "${#legacy_present[@]}" -gt 0 ]; then
        warn "Removing legacy packages first: ${legacy_present[*]} (AUR or pre-rename build)."
        pacman -R --noconfirm "${legacy_present[@]}"
    fi
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    cp "${PKGBUILD_DIR}/PKGBUILD" "${PKGBUILD_DIR}/p2p-gpu-unlock.install" "${BUILD_DIR}/"
    chown -R "${BUILD_USER}" "${BUILD_DIR}"
    info "Building p2p-gpu-unlock ${PKGVER_EXPECTED} as user ${BUILD_USER}. This downloads"
    info "the pinned sources and may take several minutes..."
    sudo -u "${BUILD_USER}" bash -c "cd '${BUILD_DIR}' && makepkg --skippgpcheck"
    info "Installing packages..."
    pacman -U --noconfirm "${BUILD_DIR}"/"${PKG_DKMS}"-*.pkg.tar.zst "${BUILD_DIR}"/"${PKG_FW}"-*.pkg.tar.zst
fi

# --- Stale-state check -------------------------------------------------------
# 1.0.0-era package drop-ins wrote 'gpu_unlock?' (optional marker) as a real
# MODULES element; the systemd-initramfs writer dumps MODULES verbatim, so the
# early loader would look for a module literally named 'gpu_unlock?' and the
# unlock silently never runs. 2.0.0 writes a plain name (its file mentions
# 'gpu_unlock?' only in a comment, hence the comment-line exclusion), so if
# the marker survives in a real line after install, a legacy state that this
# flow must not paper over is present.
if [ -f /etc/mkinitcpio.conf.d/zz-gpu-unlock.conf ] && \
   grep -v '^[[:space:]]*#' /etc/mkinitcpio.conf.d/zz-gpu-unlock.conf | grep -q 'gpu_unlock?'; then
    error "Stale 'gpu_unlock?' drop-in from a 1.0.0-era install. Run: sudo ${0##*/} --remove && sudo reboot, then re-run this script."
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
