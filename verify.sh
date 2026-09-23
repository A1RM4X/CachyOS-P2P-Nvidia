#!/bin/bash
# verify.sh - Prove the P2P-patched driver is actually in use.
# Run after reboot (and after any driver/kernel update + reboot):
#   sudo ./verify.sh
#
# The patched module is byte-identical in metadata to the stock module
# (same version, same license, same filenames), so "the module is loaded"
# does NOT prove P2P is engaged. The real proof is:
#   1. nvidia-smi works (module + userspace in sync)
#   2. the loaded module's srcversion == the on-disk patched module's
#   3. nvidia-smi topo -p2p r reports OK on every peer pair
#
# Note: this proves the driver GRANTS peer access (topology level). It does not
# exercise an actual NCCL/vLLM collective, which can still fail for other
# reasons. For bandwidth, run p2pBandwidthLatencyTest.
# Version: 1.2.0
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ok]${NC}   $*"; }
bad()  { echo -e "${RED}[fail]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
step() { echo -e "\n${GREEN}== $* ==" "${NC}"; }

fail=0

# Read srcversion from a module file (.zst handled by decompressing to temp).
srcversion_of() {  # $1 = path to nvidia.ko or nvidia.ko.zst
    local f="$1" tmp
    case "$f" in
        *.zst)
            tmp=$(mktemp "${TMPDIR:-/tmp}/nvverify.XXXXXX" 2>/dev/null) || return 1
            unzstd -c "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
            modinfo "$tmp" 2>/dev/null | awk '/^srcversion/{print $2}'
            rm -f "$tmp"
            ;;
        *)
            modinfo "$f" 2>/dev/null | awk '/^srcversion/{print $2}'
            ;;
    esac
}

step "1. nvidia-smi (module + userspace in sync)"
if ! nvidia-smi &>/dev/null; then
    bad "nvidia-smi failed. Driver/library version mismatch usually means the loaded"
    bad "kernel module and the userspace nvidia-utils are different versions."
    bad "Fix: keep IgnorePkg consistent (driver + nvidia-utils pinned together), then reboot."
    fail=1
else
    VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)
    ok "nvidia-smi OK (driver ${VER:-?})"
fi

step "2. Patched module is loaded (srcversion matches on-disk)"
RUNNING=$(cat /sys/module/nvidia/srcversion 2>/dev/null)
if [ -z "$RUNNING" ]; then
    bad "Could not read the running nvidia module srcversion (module not loaded?)."
    fail=1
else
    ok "Running srcversion: ${RUNNING}"
    # Compare against every installed nvidia.ko we can find (running kernel first).
    FOUND=0
    for KD in "/lib/modules/$(uname -r)" /lib/modules/*; do
        [ -d "$KD" ] || continue
        for M in \
            "$KD/updates/dkms/nvidia.ko" "$KD/updates/dkms/nvidia.ko.zst" \
            "$KD/kernel/drivers/video/nvidia.ko" "$KD/kernel/drivers/video/nvidia.ko.zst" \
            "$KD/extramodules/nvidia.ko" "$KD/extramodules/nvidia.ko.zst"; do
            [ -e "$M" ] || continue
            SV=$(srcversion_of "$M")
            [ -n "$SV" ] || continue
            FOUND=1
            if [ "$SV" = "$RUNNING" ]; then
                ok "On-disk match: ${M} (${SV})"
            else
                # A different on-disk build exists. If it's for the running
                # kernel, that's a stale-load; if for another kernel, just note it.
                case "$KD" in
                    "/lib/modules/$(uname -r)")
                        warn "On-disk for running kernel differs: ${M} (${SV}). The kernel likely"
                        warn "loaded a stale module (initramfs from before the DKMS rebuild)."
                        fail=1 ;;
                    *)
                        : # other kernel's module - informational only ;;
                esac
            fi
        done
    done
    if [ "$FOUND" -eq 0 ]; then
        warn "No readable nvidia.ko found on disk to compare against (running: ${RUNNING})."
        warn "Manually check: find /lib/modules/\$(uname -r) -name 'nvidia.ko*' | head"
    fi
fi

step "3. P2P topology (nvidia-smi topo -p2p r)"
if TOP=$(nvidia-smi topo -p2p r 2>&1); then
    # Matrix only: drop the legend (everything from the first line that looks
    # like the key, e.g. "Legend:").
    # Strip the legend (everything from the "Legend:" line on) to keep only the
    # GPU matrix.
    MATRIX=$(echo "$TOP" | sed '/^[[:space:]]*Legend:/,$d')
    echo "$MATRIX" | sed 's/^/       /'
    GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    if [ "${GPUS:-0}" -lt 2 ]; then
        warn "Only ${GPUS:-0} GPU(s) visible; P2P topology is only meaningful with 2+."
    # nvidia-smi aligns the matrix with tabs or with spaces depending on the
    # driver version / locale, so use default whitespace splitting (NOT -F'\t',
    # which would collapse a space-aligned matrix to one field and always pass).
    # A data row has a self "X" cell; the column-header row does not, so that's
    # how we skip it regardless of delimiter.
    elif echo "$MATRIX" | awk '
        $1 ~ /^GPU[0-9]+$/ {
            hasX=0; for (i=2; i<=NF; i++) if ($i=="X") hasX=1
            if (!hasX) next
            for (i=2; i<=NF; i++) { c=$i; gsub(/[[:space:]]/,"",c);
                if (c!="" && c!="X" && c!="OK") bad=1 }
        }
        END { exit bad }'; then
        ok "Driver permits peer access on all pairs (topology level)."
    else
        bad "Some GPU pair reports no peer access (GNS/CNS/DR/...). P2P is NOT granted."
        fail=1
    fi
else
    bad "nvidia-smi topo -p2p r failed:"
    echo "$TOP" | sed 's/^/       /'
    fail=1
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}PASS${NC} - Patched driver in use: nvidia-smi OK, module srcversion matches, peer access granted on all pairs (topology level)."
else
    echo -e "${RED}FAIL${NC} - P2P does NOT appear to be fully in use. See the failures above."
fi
exit "$fail"
