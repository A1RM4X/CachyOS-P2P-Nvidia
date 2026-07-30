# Contributing

## Reporting Issues

Use the issue templates. Include:
- CachyOS kernel version (`uname -r`)
- NVIDIA driver version (`nvidia-smi`)
- GPU model and topology (`nvidia-smi topo -m`)
- Whether you're using NVLink bridges
- Full output of `sudo ./install.sh` or `cat /var/log/nvidia-p2p-driver-rebuild.log`

## Pull Requests

- Keep scripts POSIX-compatible where possible
- Test on a real CachyOS system before submitting
- Follow existing formatting (spaces, not tabs)
- Update README if behavior changes

## Script Structure

- `install.sh` — main installer, runs interactively
- `uninstall.sh` — cleanup, runs interactively
- `check-p2p-update.sh` — weekly systemd timer, runs silently (logs to `/var/log/nvidia-p2p-check.log`)
- `rebuild-nvidia-p2p-driver.sh` — pacman hook, runs automatically (logs to `/var/log/nvidia-p2p-driver-rebuild.log`)

All scripts use `set -euo pipefail` and exit on first error.
