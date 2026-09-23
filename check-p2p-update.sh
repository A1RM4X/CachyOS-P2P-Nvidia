#!/bin/bash
# check-p2p-update.sh - Check for new aikitoria P2P patches
# Run weekly by the nvidia-p2p-check.timer systemd unit.
set -euo pipefail

# Shared helpers (patch discovery, IgnorePkg handling).
if [ -f "/usr/local/bin/p2p-lib.sh" ]; then
    # shellcheck source=/dev/null
    source /usr/local/bin/p2p-lib.sh
else
    echo "[nvidia-p2p] ERROR: p2p-lib.sh not found (expected at /usr/local/bin/p2p-lib.sh)" >&2
    exit 1
fi

LOG="/var/log/nvidia-p2p-check.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

# --- Maintain local bare mirror (for pacman hooks that lack network) ---
# Full clone (not shallow): a shallow clone only fetches the default branch,
# missing all the -p2p version branches we need.
# A mirror is "valid" if git can resolve HEAD against it (catches a partial
# clone left by an interrupted first run).
mirror_valid() {
    [ -d "$MIRROR_DIR" ] && git -C "$MIRROR_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

# Create the mirror by cloning into a temp dir and mv'ing it into place, so an
# interrupted/timed-out clone can't leave a half-written repo where the real
# one goes (which would break every later fetch and the rebuild hook's clone).
create_mirror() {
    local tmp
    tmp=$(mktemp -d "${MIRROR_DIR}.XXXXXX")
    if git clone --bare "${AIKIT_REPO_URL}" "${tmp}" >/dev/null 2>&1; then
        rm -rf "${MIRROR_DIR}"
        mv "${tmp}" "${MIRROR_DIR}"
    else
        rm -rf "${tmp}"
        return 1
    fi
}

if ! mirror_valid; then
    echo "[nvidia-p2p] Creating local mirror at ${MIRROR_DIR}..."
    create_mirror || { echo "[nvidia-p2p] ERROR: could not clone mirror"; exit 1; }
else
    echo "[nvidia-p2p] Updating local mirror..."
    # Explicit refspec: in a bare repo 'git fetch --all' only updates
    # FETCH_HEAD, leaving refs/heads/* (what 'git ls-remote --heads' reads)
    # stale, so newly released branches would be missed until a re-clone.
    if ! git -C "${MIRROR_DIR}" fetch origin '+refs/heads/*:refs/heads/*' --prune 2>&1; then
        # Fetch failed (network / corrupt repo). Try a clean re-clone once.
        echo "[nvidia-p2p] Fetch failed; re-cloning mirror..."
        create_mirror || { echo "[nvidia-p2p] WARNING: mirror still invalid; using cached state"; }
    fi
fi

# Use installed driver version, not repo version (IgnorePkg may block updates).
INSTALLED_DRIVER=$(pacman -Q nvidia-open-dkms 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//')
if [ -z "$INSTALLED_DRIVER" ]; then
    echo "[nvidia-p2p] ERROR: nvidia-open-dkms is not installed"
    exit 1
fi

# Check if the CachyOS repo has a newer driver than what's installed.
# Refresh the DB first (this script runs via the timer with no user in front of
# a fresh 'pacman -Sy'): a stale local DB would give a wrong version and could
# silently skip a real update.
pacman -Sy --noconfirm nvidia-open-dkms >/dev/null 2>&1 || true
# shellcheck disable=SC2337  # '|| true' contains the grep -m1 SIGPIPE
REPO_DRIVER=$(pacman -Si nvidia-open-dkms 2>/dev/null | grep -m1 "^Version" | awk '{print $3}' | sed 's/-[0-9]*$//' || true)
if [ -z "$REPO_DRIVER" ]; then
    echo "[nvidia-p2p] ERROR: Could not query CachyOS repo"
    exit 1
fi

if [ "$REPO_DRIVER" = "$INSTALLED_DRIVER" ]; then
    echo "[nvidia-p2p] Already on latest CachyOS driver: ${INSTALLED_DRIVER}"
    exit 0
fi
# Proceed only if the repo driver is NEWER than what's installed. If the
# installed one is the smaller of the two, we're already ahead of the repo.
if [ "$(printf '%s\n%s\n' "$REPO_DRIVER" "$INSTALLED_DRIVER" | sort -V | head -n1)" != "$INSTALLED_DRIVER" ]; then
    echo "[nvidia-p2p] Installed driver (${INSTALLED_DRIVER}) is newer than repo (${REPO_DRIVER}); nothing to do."
    exit 0
fi
echo "[nvidia-p2p] CachyOS has newer driver (${REPO_DRIVER}) but we're on ${INSTALLED_DRIVER}"

# Does aikitoria have a patch for the newer driver?
LATEST_PATCH=$(find_latest_patch "$REPO_DRIVER" "$MIRROR_DIR" || true)
if [ -z "$LATEST_PATCH" ]; then
    echo "[nvidia-p2p] No aikitoria patch available for driver ${REPO_DRIVER}"
    exit 0
fi
if [ "$LATEST_PATCH" != "$REPO_DRIVER" ]; then
    echo "[nvidia-p2p] aikitoria patch (${LATEST_PATCH}) does not match repo driver (${REPO_DRIVER})"
    exit 0
fi

# A matching patch exists: let the next `pacman -Syu` pull the new driver.
# The pacman hook will then rebuild the patched modules automatically.
echo "[nvidia-p2p] UPDATE AVAILABLE: ${INSTALLED_DRIVER} -> ${REPO_DRIVER}"
echo "[nvidia-p2p] Removing IgnorePkg. Run 'pacman -Syu' to update."
unpin_p2p_packages
