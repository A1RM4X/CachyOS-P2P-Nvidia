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
- Installs a pacman hook that auto-rebuilds when aikitoria releases new patches
- Installs a weekly systemd timer that checks for new patches

## Requirements

- CachyOS with `linux-cachyos` or `linux-cachyos-lts` kernel (or any CachyOS kernel variant)
- Kernel headers (`linux-cachyos-headers`)
- Clang + LLD toolchain (`clang`, `lld`)
- DKMS (`dkms`)
- Git (`git`)
- IOMMU passthrough: `amd_iommu=on iommu=pt` in kernel cmdline
- Secure Boot disabled (or MOK key enrolled)

## Install

```bash
git clone https://github.com/A1RM4X/CachyOS-P2P-Nvidia.git
cd CachyOS-P2P-Nvidia
sudo ./install.sh
sudo reboot
```

## Verify

```bash
# Check patched module is loaded
sudo cat /sys/module/nvidia/srcversion
# Cross-reference with on-disk module:
modinfo /lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst | grep srcversion
# Both should match.

# Check P2P topology
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

Verify the patched module is actually loaded:
```bash
sudo cat /sys/module/nvidia/srcversion
modinfo /lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst | grep srcversion
```
If they don't match, reboot.

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

Removes patched modules, pacman hooks, systemd timer, and restores stock `nvidia-open-dkms`. Optionally switches back to CachyOS pre-built driver.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT License — see [LICENSE](LICENSE).
