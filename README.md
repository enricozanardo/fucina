# FUCINA — the LIMEN-AI RTX knowledge-base factory

**FUCINA** (*Fuzzy Compiler for Interpretable Neuralized Axioms*, Italian for
"forge") is the GPU half of LIMEN-AI. This Docker Compose stack runs it on a
machine with an NVIDIA RTX-class GPU; your **LUCIA** board (PYNQ-Z2) pairs to it
on port **8770**.

This repository holds only what an operator needs:

- `docker-compose.yml` — pull-by-tag factory + llama.cpp
- `install/fucina.sh` — whiptail/dialog TUI (or plain prompts)
- `install/rtx_preflight.sh` — multi-distro GPU-in-Docker check
- `configs/model_catalog.json` — profiles sized against your card (including
  **Qwen3-4B** for 6 GB GPUs such as an RTX 4050)

The factory image is public on GHCR:

`ghcr.io/enricozanardo/limen-factory`

No GitHub token or `docker login` is required to install. The image keeps the
older `limen-factory` name because GHCR cannot rename a published package.

## Quick start

```bash
git clone https://github.com/enricozanardo/fucina.git
cd fucina

# Ubuntu/Debian/Fedora/Arch/Gentoo: driver + Docker + NVIDIA Container Toolkit
./install/rtx_preflight.sh --install   # or follow the distro table in docs/
./install/rtx_preflight.sh --verify

./install/fucina.sh                    # interactive
# or:
./install/fucina.sh --no-tui install
```

Pair the board to `http://<this-lan-ip>:8770`.

## Update

```bash
git pull
./install/fucina.sh update
# or: ./install/fucina.sh --no-tui update
```

## Full guide

See [docs/fucina-guide.md](docs/fucina-guide.md) for per-distro prerequisites
(including Gentoo/OpenRC), model sizing, board pairing and troubleshooting.
