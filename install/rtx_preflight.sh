#!/usr/bin/env bash
# rtx_preflight.sh - prepare and verify a host for the Docker RTX factory.
#
# Checks the host GPU plumbing that cannot be containerised away: an NVIDIA
# driver plus Docker with the NVIDIA Container Toolkit, so
# `docker run --gpus all` can see the GPU.
#
# Supports apt (Ubuntu/Debian), emerge (Gentoo), dnf (Fedora/RHEL/Rocky),
# pacman (Arch/Manjaro) and zypper (openSUSE). Service restart works with both
# systemd and OpenRC. Always ends with the same verification: run nvidia-smi
# INSIDE a CUDA container.
#
#   ./install/rtx_preflight.sh              # detect OS, help set up, then verify
#   ./install/rtx_preflight.sh --verify     # only run the in-container GPU check
#   ./install/rtx_preflight.sh --install    # install missing pieces when possible
#
# Env:
#   LIMEN_CUDA_VERIFY_IMAGE   image used for the GPU check
#                             (default nvidia/cuda:12.4.1-base-ubuntu22.04)

set -euo pipefail

VERIFY_IMAGE="${LIMEN_CUDA_VERIFY_IMAGE:-nvidia/cuda:12.4.1-base-ubuntu22.04}"
DO_INSTALL=0

log()  { printf '%s\n' "== $*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

detect_os() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

detect_os_like() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID_LIKE:-}"
    fi
}

service_restart_docker() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        sudo systemctl restart docker
    elif command -v rc-service >/dev/null 2>&1; then
        sudo rc-service docker restart
    else
        warn "Could not restart Docker automatically; restart it by hand."
    fi
}

service_enable_docker() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        sudo systemctl enable --now docker 2>/dev/null || sudo systemctl start docker
    elif command -v rc-update >/dev/null 2>&1; then
        sudo rc-update add docker default 2>/dev/null || true
        sudo rc-service docker start 2>/dev/null || true
    fi
}

verify_gpu_in_docker() {
    log "Verifying GPU access inside a container (${VERIFY_IMAGE})"
    if ! command -v docker >/dev/null 2>&1; then
        err "docker not found on PATH. Install Docker first."
        return 1
    fi
    if docker run --rm --gpus all "${VERIFY_IMAGE}" nvidia-smi; then
        log "OK: the GPU is visible inside Docker. The factory stack can run."
        return 0
    fi
    err "Could not access the GPU from inside Docker."
    err "Fix the NVIDIA driver + NVIDIA Container Toolkit, then re-run with --verify."
    return 1
}

host_checks() {
    command -v docker >/dev/null 2>&1 && log "docker: $(docker --version)" \
        || warn "docker not found - install Docker Engine before continuing."
    if docker compose version >/dev/null 2>&1; then
        log "compose: $(docker compose version | head -n1)"
    else
        warn "'docker compose' (v2) not found - install the Compose plugin."
    fi
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        log "host GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
        log "host VRAM: $(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n1)"
    else
        warn "nvidia-smi not working on the host - install the NVIDIA driver first."
    fi
}

install_toolkit_debian() {
    log "Installing the NVIDIA Container Toolkit (apt)"
    local kr list
    kr=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    list=/etc/apt/sources.list.d/nvidia-container-toolkit.list
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o "${kr}"
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=${kr}] https://#g" \
        | sudo tee "${list}" >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    service_restart_docker
    log "Toolkit installed and Docker runtime configured."
}

install_toolkit_rpm() {
    # Fedora / RHEL / Rocky / openSUSE share the libnvidia-container RPM repo.
    local pm="$1"
    log "Installing the NVIDIA Container Toolkit (${pm})"
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
    case "${pm}" in
        dnf) sudo dnf install -y nvidia-container-toolkit ;;
        zypper) sudo zypper --non-interactive install nvidia-container-toolkit ;;
        *) err "unsupported rpm package manager: ${pm}"; return 1 ;;
    esac
    sudo nvidia-ctk runtime configure --runtime=docker
    service_restart_docker
    log "Toolkit installed and Docker runtime configured."
}

install_gentoo() {
    log "Installing Docker + NVIDIA Container Toolkit (emerge)"
    # Driver is left to the operator: it often needs a reboot and USE flags.
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        warn "nvidia-smi missing. Install the driver first:"
        warn "  emerge -av x11-drivers/nvidia-drivers && reboot"
    fi
    sudo emerge -av app-containers/docker app-containers/docker-cli \
        app-containers/nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    service_enable_docker
    service_restart_docker
    log "Packages installed. Confirm with: nvidia-smi && docker compose version"
}

install_arch() {
    log "Installing NVIDIA Container Toolkit (pacman)"
    sudo pacman -Sy --noconfirm nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    service_restart_docker
}

print_manual() {
    local os="$1"
    cat <<EOF
== Manual setup (${os}) ==
Install three host pieces, then re-run with --verify:

  1. NVIDIA proprietary driver so \`nvidia-smi\` works on the host.
  2. Docker Engine + Compose v2 (\`docker compose version\`).
  3. NVIDIA Container Toolkit, then:
       nvidia-ctk runtime configure --runtime=docker
       # systemd:  systemctl restart docker
       # OpenRC:   rc-service docker restart

Universal check (same on every distribution):
  docker run --rm --gpus all ${VERIFY_IMAGE} nvidia-smi
EOF
}

maybe_install() {
    local os="$1" like
    like="$(detect_os_like)"
    case "${os}" in
        ubuntu|debian)
            if command -v nvidia-ctk >/dev/null 2>&1; then
                log "NVIDIA Container Toolkit already present; skipping install."
            else
                install_toolkit_debian
            fi
            ;;
        gentoo)
            if [ "${DO_INSTALL}" = "1" ]; then
                install_gentoo
            else
                print_manual gentoo
                cat <<'EOF'

Gentoo packages (when you are ready to install):
  emerge -av x11-drivers/nvidia-drivers
  emerge -av app-containers/docker app-containers/docker-cli
  emerge -av app-containers/nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  rc-update add docker default && rc-service docker start   # OpenRC
  # or: systemctl enable --now docker                       # systemd profile
Then: ./install/rtx_preflight.sh --verify
Or:   ./install/rtx_preflight.sh --install
EOF
            fi
            ;;
        fedora|rhel|rocky|centos|almalinux)
            if command -v nvidia-ctk >/dev/null 2>&1; then
                log "NVIDIA Container Toolkit already present; skipping install."
            elif [ "${DO_INSTALL}" = "1" ] || [ "${os}" = "fedora" ]; then
                install_toolkit_rpm dnf
            else
                print_manual "${os}"
            fi
            ;;
        opensuse*|sles)
            if command -v nvidia-ctk >/dev/null 2>&1; then
                log "NVIDIA Container Toolkit already present; skipping install."
            elif [ "${DO_INSTALL}" = "1" ]; then
                install_toolkit_rpm zypper
            else
                print_manual "${os}"
            fi
            ;;
        arch|manjaro|endeavouros)
            if command -v nvidia-ctk >/dev/null 2>&1; then
                log "NVIDIA Container Toolkit already present; skipping install."
            elif [ "${DO_INSTALL}" = "1" ]; then
                install_arch
            else
                print_manual "${os}"
            fi
            ;;
        *)
            # ID_LIKE may still point at a known family.
            case " ${like} " in
                *" debian "*|*" ubuntu "*)
                    if ! command -v nvidia-ctk >/dev/null 2>&1; then
                        install_toolkit_debian
                    fi
                    ;;
                *" rhel "*|*" fedora "*|*" centos "*)
                    if ! command -v nvidia-ctk >/dev/null 2>&1 && [ "${DO_INSTALL}" = "1" ]; then
                        install_toolkit_rpm dnf
                    else
                        print_manual "${os}"
                    fi
                    ;;
                *)
                    print_manual "${os}"
                    ;;
            esac
            ;;
    esac
}

main() {
    case "${1:-}" in
        --verify)
            verify_gpu_in_docker
            return $?
            ;;
        --install)
            DO_INSTALL=1
            ;;
        -h|--help)
            sed -n '2,22p' "$0"
            return 0
            ;;
    esac

    local os; os="$(detect_os)"
    log "Detected OS: ${os} (ID_LIKE=$(detect_os_like))"
    host_checks
    maybe_install "${os}"
    echo
    verify_gpu_in_docker
}

main "$@"
