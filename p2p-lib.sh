#!/bin/bash
# p2p-lib.sh - Shared helpers for the CachyOS-P2P-Nvidia scripts.
# Sourced by install.sh, rebuild-nvidia-p2p-driver.sh, check-p2p-update.sh.
# NOT meant to be executed directly.
#
# This file is the single source of truth for:
#   - which NVIDIA packages are pinned (PINNED_PKGS)
#   - how /etc/pacman.conf IgnorePkg is edited (pin/unpin)
#   - how aikitoria patch branches are discovered
#   - how the DKMS build configuration is generated

# aikitoria repo and local bare mirror. Overridable for testing.
AIKIT_REPO_URL="${AIKIT_REPO_URL:-https://github.com/aikitoria/open-gpu-kernel-modules.git}"
MIRROR_DIR="${MIRROR_DIR:-/opt/nvidia-p2p-mirror}"
# /etc/pacman.conf, overridable for testing.
PACMAN_CONF="${PACMAN_CONF:-/etc/pacman.conf}"

# NVIDIA packages pinned via IgnorePkg so the userspace never walks past the
# pinned kernel module. If a new nvidia userspace package needs pinning, add
# it HERE ONLY - every script that sources this file picks it up automatically.
PINNED_PKGS="nvidia-open-dkms nvidia-utils nvidia-settings opencl-nvidia lib32-opencl-nvidia lib32-nvidia-utils"

# --- /etc/pacman.conf IgnorePkg handling -----------------------------------
# All functions are idempotent and preserve any unrelated packages the user
# already has pinned.

# Print the package tokens on the first active IgnorePkg line (space-delimited).
_ignorepkg_tokens() {
    local line
    line=$(grep -E '^IgnorePkg' "$PACMAN_CONF" | head -n1 || true)
    [ -z "$line" ] && return 0
    # Drop the directive name and '='; collapse whitespace.
    echo "$line" | sed -E 's/^IgnorePkg[[:space:]]*=?[[:space:]]*//; s/[[:space:]]+/ /g; s/ +$//'
}

# Write the first IgnorePkg line from a token list ($1, may be empty).
# Creates the line under [options] if none exists.
_ignorepkg_set() {  # $1 = space-delimited tokens (may be empty -> drop the line)
    local tokens
    # Collapse whitespace, then drop invalid tokens (a real pacman package name
    # matches [A-Za-z0-9._+@-] and never ends in '-') and de-duplicate. This
    # self-heals any legacy junk that ended up on the IgnorePkg line.
    tokens=$(printf '%s' "$1" | tr ' ' '\n' \
        | grep -E '^[A-Za-z0-9._+@-]+$' | grep -Ev -- '-$' | awk '!seen[$0]++' \
        | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/ +$//' || true)
    local existing
    existing=$(grep -nE '^IgnorePkg' "$PACMAN_CONF" | head -n1 | cut -d: -f1)
    if [ -z "$tokens" ]; then
        # No valid tokens left: an empty IgnorePkg line is meaningless, remove it.
        [ -n "$existing" ] && sed -i "${existing}d" "$PACMAN_CONF"
        return 0
    fi
    if [ -n "$existing" ]; then
        sed -i "${existing}s/.*/IgnorePkg = ${tokens}/" "$PACMAN_CONF"
    else
        sed -i "/^\[options\]/a IgnorePkg = ${tokens}" "$PACMAN_CONF"
    fi
}

# Add every PINNED_PKGS to the active IgnorePkg line, if not already present.
# Matching is exact-token (space-delimited), so pinning "opencl-nvidia" is not
# fooled by an existing "lib32-opencl-nvidia" token. Idempotent.
pin_p2p_packages() {
    local have pkg
    have=" $(_ignorepkg_tokens) "
    for pkg in $PINNED_PKGS; do
        case "$have" in
            *" $pkg "*) : ;;                 # already present
            *) have="${have}${pkg} " ;;
        esac
    done
    _ignorepkg_set "$(echo "$have" | sed -E 's/[[:space:]]+/ /g; s/ +//; s/^ +//')"
}

# Remove every PINNED_PKGS from the active IgnorePkg line. Only tokens that
# exactly equal a pinned package are dropped, so unrelated packages the user
# had (and "lib32-opencl-nvidia" when only "opencl-nvidia" is pinned) survive.
unpin_p2p_packages() {
    local t p kept
    kept=""
    for t in $(_ignorepkg_tokens); do
        local drop=0
        for p in $PINNED_PKGS; do
            [ "$t" = "$p" ] && { drop=1; break; }
        done
        [ "$drop" = 0 ] && kept="$kept $t"
    done
    _ignorepkg_set "$(echo "$kept" | sed -E 's/[[:space:]]+/ /g; s/ +//; s/^ +//')"
}

# --- aikitoria patch discovery ---------------------------------------------

# Print aikitoria "-p2p" branch versions, semver ascending.
aikitoria_patches() {  # $1 = git URL or local bare-repo path
    timeout 30 git ls-remote --heads "$1" 2>/dev/null \
        | grep -oE 'refs/heads/[0-9]+\.[0-9]+\.[0-9]+-p2p' \
        | sed 's#refs/heads/##; s/-p2p$//' \
        | sort -Vu
}

# Print the newest aikitoria patch version that is <= $1 (installed driver).
# Prints nothing if there is no patch at or below $1.
find_latest_patch() {  # $1 = driver version, $2 = git URL or path
    local target="$1" src="$2" p latest=""
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        # p <= target ?  (sort -V head is the smallest of the pair)
        if [ "$(printf '%s\n%s\n' "$target" "$p" | sort -V | head -n1)" = "$p" ]; then
            latest="$p"
        fi
    done < <(aikitoria_patches "$src")
    [ -n "$latest" ] && printf '%s\n' "$latest"
    return 0
}

# --- DKMS build configuration ------------------------------------------------

# Write the dkms.conf that builds the aikitoria source for driver version $2.
# NOTE the Makefile is invoked as a literal 'make' (quoted) so DKMS does not
# append KERNELRELEASE=... on the command line (which makes the Makefile take
# the Kbuild code path and fail with "/Kbuild: No such file"). objtool is
# bypassed and IGNORE_CC_MISMATCH set because the CachyOS kernel is LTO/clang
# and the module compiler can differ.
write_dkms_conf() {  # $1 = source dir, $2 = driver version
    local dir="$1" ver="$2"
    cat > "${dir}/dkms.conf" << DKMSCONF
PACKAGE_NAME="nvidia"
PACKAGE_VERSION="${ver}"
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
}
