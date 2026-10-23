#!/bin/bash
# apply-kernel-compat-patches.sh - Apply kernel API compat patches to a freshly
# cloned driver source tree, BEFORE dkms add.
#
# Why: a new kernel can change an API the pinned driver uses (kernel 7.3.0
# changed dmem_cgroup_register_region() to take a struct dmem_cgroup_init *).
# The P2P patch does not cover this. The patches in patches/ port the compat
# handling NVIDIA ships in newer stock drivers (conftest compile-probe +
# #if shim), so the pinned tree compiles against BOTH older and newer kernels.
#
# Usage: apply-kernel-compat-patches.sh <driver-src-dir> [patch-dir]
# Exit:  0  all patches applied or already present
#        1  missing dir, or a patch neither applies nor is already present
#           (the tree may fail to compile on a new kernel; the caller decides
#            severity - install.sh and the rebuild hook treat this as a warning)
set -uo pipefail

SRC_DIR="${1:-}"
if [ -f "/usr/local/bin/p2p-lib.sh" ]; then
    # shellcheck source=/dev/null
    source /usr/local/bin/p2p-lib.sh    # for COMPAT_PATCH_DIR
fi
PATCH_DIR="${2:-${COMPAT_PATCH_DIR:-/usr/local/share/nvidia-p2p/patches}}"

[ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || {
    echo "[nvidia-p2p] ERROR: usage: $0 <driver-src-dir> [patch-dir]"
    exit 1
}
[ -d "$PATCH_DIR" ] || {
    echo "[nvidia-p2p] WARNING: no compat patches dir at ${PATCH_DIR}; skipping"
    exit 0
}

rc=0
shopt -s nullglob
for p in "$PATCH_DIR"/*.patch; do
    name="$(basename "$p")"
    # Dry run first: classify "applies" vs "already present" vs "mismatch".
    out="$(patch -p1 -N --forward --dry-run -d "$SRC_DIR" < "$p" 2>&1)"; dryrc=$?
    if [ "$dryrc" -eq 0 ]; then
        if patch -p1 -N --forward -d "$SRC_DIR" < "$p" >/dev/null 2>&1; then
            echo "[nvidia-p2p] compat patch applied: ${name}"
        else
            echo "[nvidia-p2p] ERROR: compat patch passed dry-run but failed to apply: ${name}"
            rc=1
        fi
    elif printf '%s' "$out" | grep -q 'previously applied'; then
        # Tree already carries the fix (e.g. a newer aikitoria branch that
        # upstreamed it, or a second run of this script). Nothing to do.
        echo "[nvidia-p2p] compat patch already present: ${name}"
    else
        echo "[nvidia-p2p] WARNING: compat patch ${name} does not apply to this tree (context changed?)."
        echo "[nvidia-p2p] The driver may fail to compile on a NEW kernel; older kernels are unaffected."
        printf '%s\n' "$out" | sed 's/^/[nvidia-p2p]   /' | head -n 20
        rc=1
    fi
done
exit "$rc"
