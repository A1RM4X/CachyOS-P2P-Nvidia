# CachyOS P2P NVIDIA

One-command install of [aikitoria/open-gpu-kernel-modules](https://github.com/aikitoria/open-gpu-kernel-modules) on CachyOS with automatic kernel and driver update handling.

Enables PCIe BAR1 P2P on consumer GPUs (RTX 3090, 4090, 5090) where NVLink is not available.

> **⚠️ Driver version lag:** The aikitoria repo maintains version-specific branches (e.g., `610.43.03-p2p`). This script detects the latest available patch, builds it via DKMS, and pins the driver via `IgnorePkg`. When aikitoria releases a new patch, the pacman hook automatically rebuilds.

## What This Does

- Switches from CachyOS's pre-built `linux-cachyos-*-nvidia-open` to `nvidia-open-dkms` (so the driver is decoupled from the kernel version)
- Replaces stock `nvidia-open-dkms` modules with aikitoria's P2P-patched versions
- Queries aikitoria's repo for the latest available P2P patch
- Builds patched modules via DKMS for all installed kernels
- Pins the driver via `IgnorePkg` so P2P is never lost on system upgrades
- Pins `nvidia-open-dkms`, `nvidia-utils`, `nvidia-settings`, `opencl-nvidia`, `lib32-opencl-nvidia`, and `lib32-nvidia-utils` to prevent version mismatches
- Installs a pacman hook that auto-rebuilds when aikitoria releases new patches
- Installs a weekly systemd timer that checks for new patches
- Applies kernel API compat patches (`patches/*.compat.patch`) so the pinned driver still builds when a new kernel changes a driver API
- Runs weekly boot-chain verification of every Limine menu entry (ESP image hash, module tree, GPU driver)
- Ships a `verify.sh` one-shot check that proves P2P is actually engaged
- Guards the DKMS build with a lock (no two concurrent builds) and rotates its logs

## Requirements

- CachyOS with `linux-cachyos` or `linux-cachyos-lts` kernel (or any CachyOS kernel variant)
- Kernel headers (`linux-cachyos-headers`)
- Clang + LLD toolchain (`clang`, `lld`)
- DKMS (`dkms`)
- Git (`git`)
- zstd (`zstd`) — `verify.sh` reads `.zst`-compressed modules via `unzstd`
- IOMMU passthrough: `amd_iommu=on iommu=pt` in kernel cmdline
- Secure Boot disabled (or MOK key enrolled)
- **Large BAR1 enabled on GPU firmware** — the patch maps the full VRAM aperture through BAR1. Cards whose VBIOS caps BAR1 at 256 MB will build cleanly but P2P will still fail. Check with:
  ```bash
  # First find your GPU bus ID:
  lspci | grep -i vga
  # Then check BAR1 size (replace 01:00.0 with your actual bus ID):
  sudo lspci -vv -s 01:00.0 | grep -A4 "Physical Resizable BAR"
  ```
  BAR 1 must show `supported: 32768 MiB` (or your GPU's VRAM size). If it tops out at 256 MB, you need a ReBAR-capable VBIOS from the board vendor first. Not rare on RTX 3090s.

## Install

```bash
git clone https://github.com/A1RM4X/CachyOS-P2P-Nvidia.git
cd CachyOS-P2P-Nvidia
sudo ./install.sh
sudo reboot
```

## Verify

Run the one-shot check after every reboot (and after any driver/kernel update + reboot):

```bash
sudo ./verify.sh
```

It proves the patch is actually in use — the patched module is byte-identical in
metadata to the stock one, so "the module is loaded" alone doesn't prove P2P.
It checks, in order:

1. `nvidia-smi` works (module + userspace in sync)
2. the loaded module's `srcversion` matches the on-disk patched module
3. `nvidia-smi topo -p2p r` reports `OK` on every peer pair (any `GNS`/`CNS`/`DR` fails)

Exit code is `0` on success, `1` if any check fails.

Check 3 proves the driver **grants peer access** (topology level). It does not
exercise an actual NCCL/vLLM collective, which can still fail for unrelated
reasons. For real bandwidth, build and run [`p2pBandwidthLatencyTest`](#building-p2pbandwidthlatencytest). If you just want the raw
topology:

```bash
nvidia-smi topo -p2p r
# All pairs should show OK (NVLink pairs) or OK (cross-pair via BAR1)
```

## Benchmark

```bash
/opt/cuda-samples/bin/p2pBandwidthLatencyTest
```

Results (4x RTX 3090 with NVLink bridges 0<->2, 1<->3):

| Pair type | Unidirectional | Bidirectional |
|---|---|---|
| NVLink (0<->2, 1<->3) | ~52.8 GB/s | ~101.7 GB/s |
| Cross-pair **with patch** (BAR1) | ~26.1 GB/s | ~51.2 GB/s |
| Cross-pair **without patch** (CPU) | ~11.3 GB/s | ~15.2 GB/s |

The patch improves cross-pair bandwidth by ~2.3x unidirectional and ~3.4x bidirectional.

> **Note:** These raw interconnect ratios don't directly translate to end-to-end inference speedups. Real workloads are memory-bound, not interconnect-bound. On 2×3090 TP=2 we measured ~+2% narrative / ~+9% code generation, and ~+19–22% on speculative decoding paths.

### Building p2pBandwidthLatencyTest

```bash
sudo pacman -S cmake
git clone --depth 1 https://github.com/NVIDIA/cuda-samples.git
cd cuda-samples
git checkout tags/v13.3  # match your nvcc version
cd cpp/5_Domain_Specific/p2pBandwidthLatencyTest
mkdir build && cd build
cmake .. -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc
cmake --build .
sudo mkdir -p /opt/cuda-samples/bin
sudo cp p2pBandwidthLatencyTest /opt/cuda-samples/bin/
```

## How Updates Work

### Kernel updates (automatic)

When you run `pacman -Syu` and a new kernel is installed, DKMS automatically rebuilds the patched modules for the new kernel. No action needed.

### Driver updates (semi-automatic)

1. CachyOS updates `nvidia-open-dkms` in the repo
2. `IgnorePkg` blocks the update — you stay on the patched version
3. The weekly systemd timer checks if aikitoria has a patch for the new driver
4. If a patch exists, `IgnorePkg` is removed
5. You run `pacman -Syu` — the pacman hook automatically rebuilds patched modules
6. Reboot

### No patch available

If aikitoria hasn't patched the new driver yet, `IgnorePkg` stays active. You remain on the older patched driver until aikitoria catches up.

## Kernel API compatibility

A new CachyOS kernel can change a kernel API the pinned driver uses (kernel 7.3.0 changed `dmem_cgroup_register_region()` to take a `struct dmem_cgroup_init *`). When that happens the DKMS build for the new kernel fails and the new kernel gets no GPU driver — while the boot menu still offers it.

`patches/*.compat.patch` ports the compat handling NVIDIA ships in newer stock drivers (a conftest compile-probe plus an `#if` shim) into the pinned aikitoria tree:

- `install.sh` and the rebuild hook apply them to the fresh clone **before** DKMS registration. Idempotent — if a future aikitoria branch already carries the fix, they're skipped as "already present".
- If a patch no longer applies to a new driver version, a warning is logged and the DKMS build failure is the loud signal (fix the patch, re-run `install.sh`).

### Boot-chain verification

`verify-boot-chain.sh` audits every Limine menu entry and catches the three states in which a reboot silently lands on a broken GPU box:

| State | Meaning |
|---|---|
| `STALE` | ESP vmlinuz doesn't match the installed kernel (upgrade whose post-transaction hook was interrupted) |
| `ORPHAN` | entry boots a kernel whose `/usr/lib/modules/<ver>` was deleted (zero loadable modules → ESP mount, LVM, networking all fail) |
| `NODEV` | a menu kernel has no nvidia module built for it (failed DKMS build) |

Run it any time: `sudo verify-boot-chain.sh`. `--fix` additionally auto-repairs `STALE` entries whose module tree and GPU driver are intact by re-running the limine mkinitcpio hook for the owning package (the hook reads its kernel targets from **stdin** — that's what `--fix` feeds it). The weekly `nvidia-p2p-bootcheck.timer` runs it automatically; log at `/var/log/nvidia-p2p-bootchain.log`.

> **Don't reboot mid kernel+driver upgrade.** The post-transaction hooks (depmod → dkms → limine) take minutes; an interrupted run leaves a `STALE`/`ORPHAN` entry behind. If it happens anyway: `sudo verify-boot-chain.sh --fix`.

## Troubleshooting

### Secure Boot

If Secure Boot is enabled, DKMS-signed modules may fail to load. Either:
- Disable Secure Boot in BIOS/UEFI, or
- Enroll the MOK key when prompted during DKMS build

### Missing build tools

```bash
sudo pacman -S clang lld dkms git linux-cachyos-headers
```

### Module srcversion mismatch after reboot

The kernel may load stale modules from the initramfs. Regenerate:
```bash
sudo limine-mkinitcpio $(uname -r | cut -d- -f1-2)
sudo reboot
```

### Cross-pair P2P still shows GNS

1. Verify the patched module is actually loaded:
   ```bash
   sudo cat /sys/module/nvidia/srcversion
   modinfo /lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst | grep srcversion
   ```
   If they don't match, reboot.

2. Check GPU firmware supports Large BAR1:
   ```bash
   sudo lspci -vv -s <bus> | grep -A4 "Physical Resizable BAR"
   ```
   BAR 1 must show `supported: 32768 MiB` (or your GPU's VRAM size). If it caps at 256 MB, you need a ReBAR-capable VBIOS from the board vendor. This is not rare on RTX 3090s.

### "Custom allreduce is disabled" in vLLM logs

This is expected on PCIe-only rigs (including pairwise NVLink bridges). vLLM's custom allreduce kernel requires a full NVLink mesh, which consumer GPUs don't provide. NCCL still uses P2P for all-reduce — that's where the bandwidth improvement comes from. On 2×3090 TP=2, expect ~+2% narrative / ~+9% code generation speedup.

## Known Issues

### System sleep/suspend broken

The patched driver breaks suspend/resume on some setups. If you need sleep functionality, revert to stock modules (`sudo ./uninstall.sh`) or keep the system running headless. This is a known limitation of the aikitoria patch, not the installer.

## Update

To refresh the installed scripts after pulling new fixes (no DKMS rebuild, no reboot needed):

```bash
cd CachyOS-P2P-Nvidia
git pull
sudo ./update.sh
```

This deploys updated `check-p2p-update.sh`, `rebuild-nvidia-p2p-driver.sh`, the pacman hook, and the systemd units — only touching files that actually changed. It does **not** rebuild modules or touch `IgnorePkg`. If a release bumped the driver version, follow with `sudo pacman -Syu && sudo reboot`.

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

Removes patched modules, pacman hooks, systemd timer, and restores stock `nvidia-open-dkms`. Optionally switches back to CachyOS pre-built driver.

## Optional: GPU Unlock (RTX 30-series FP/BF16 issue rate)

> **Disclaimer** — the unlock raises the FP/BF16 issue rate; depending on
> your power limits, cooling and workload, clocks and power draw may
> increase. Applying it is at your own responsibility. After enabling it,
> make sure temperatures, clocks and power draw behave normally under your
> usual workload (`nvidia-smi -q -d THERMAL,POWER`); if anything looks off,
> revert with `sudo ./unlock-ga100.sh --remove && sudo reboot`. Provided
> as-is, without warranty of any kind.

`install.sh` offers, on systems with GA10x cards (RTX 3090/3090 Ti/3080/3070/3060), an optional step that installs [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock): an early kernel module that unlocks the FP16/BF16 (and TF32) instruction issue rate to professional-card levels, running **before** the NVIDIA driver binds the card. It does not flash or modify VBIOS, and the P2P patch is unaffected — the two stack.

Expected effect (GA102, from gpu-unlock's 3090 Ti measurements): FP16 ~87→118 TFLOPS, BF16 ~87→157 TFLOPS, TF32 ~42→82 TFLOPS.

Measured on a 4× RTX 3090 box (8192³ cuBLAS GEMM, median of 7 runs, min–max across cards; the stock row is NVIDIA's published dense spec):

| Power limit | BF16 | FP16 | FP32 |
|---|---|---|---|
| stock (no unlock) | ~71 | ~71 | ~35 |
| unlocked @ 220 W cap | 70–88 | 61–76 | ~22 |
| unlocked @ 350 W (default) | 124.6–134.8 | 117.2–119.1 | 26.3 |

At the full 350 W budget that is ≈1.8× stock BF16, matching upstream. Under an aggressive power cap (220 W) the gain is masked — the extra issue rate converts to clock loss and dense GEMM shows no measurable change — so the unlock only pays off when the cards are allowed to spend real power.

```bash
# Standalone (or say yes to the prompt during install.sh)
sudo ./unlock-ga100.sh
sudo reboot

# Verify after reboot
grep gpu_unlock /proc/cmdline          # opt-in present
journalctl -k -b | grep -i gpu_unlock # unlock lines, one per card

# Revert at any time
sudo ./unlock-ga100.sh --remove
sudo reboot
```

Notes:

- Opt-in is the kernel parameter `gpu_unlock.targets=all`, written by the script to a Limine drop-in (`/etc/limine-entry-tool.d/gpu-unlock.conf`). Without it the module is inert.
- The script also installs `zz-p2p-gpu-unlock.conf` (mkinitcpio drop-in): it strips the early nvidia stack (CachyOS chwd adds it for the early KMS console), keeps a single plain `gpu_unlock` entry, and blocks nvidia from loading inside the initramfs so it cannot race the unlock. nvidia loads normally after the root switch. While installed, early boot shows the plain framebuffer instead of the chwd console; the normal console appears once the driver loads.
- Cards that are not GA102/GA103/GA104/GA106 (e.g. RTX 40/50-series) are skipped — no benefit, no harm.
- If a card's firmware never stops, the module logs it and keeps the card usable; power off (not just reboot) before retrying.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT License — see [LICENSE](LICENSE).
