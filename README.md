# LIMEN-AI RTX factory (public bootstrap)

Docker Compose stack that runs the LIMEN-AI knowledge-base factory on a machine
with an NVIDIA RTX-class GPU. The board (PYNQ-Z2) pairs to this host on port
**8770**.

This repository holds only what an operator needs:

- `docker-compose.yml` — pull-by-tag factory + llama.cpp
- `install/limen-rtx.sh` — whiptail/dialog TUI (or plain prompts)
- `install/rtx_preflight.sh` — multi-distro GPU-in-Docker check
- `configs/model_catalog.json` — profiles sized against your card (including
  **Qwen3-4B** for 6 GB GPUs such as an RTX 4050)

The factory image is public on GHCR:

`ghcr.io/enricozanardo/limen-factory`

No GitHub token or `docker login` is required to install.

## Quick start

```bash
git clone https://github.com/enricozanardo/limen-rtx.git
cd limen-rtx

# Ubuntu/Debian/Fedora/Arch/Gentoo: driver + Docker + NVIDIA Container Toolkit
./install/rtx_preflight.sh --install   # or follow the distro table in docs/
./install/rtx_preflight.sh --verify

./install/limen-rtx.sh                 # interactive
# or:
./install/limen-rtx.sh --no-tui install
```

Pair the board to `http://<this-lan-ip>:8770`.

## Update

```bash
git pull
./install/limen-rtx.sh update
# or: ./install/limen-rtx.sh --no-tui update
```

## Full guide

See [docs/rtx-factory-docker.md](docs/rtx-factory-docker.md) for per-distro
prerequisites (including Gentoo/OpenRC), model sizing, board pairing and
troubleshooting.
