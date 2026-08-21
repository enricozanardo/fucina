#!/usr/bin/env bash
# limen-rtx.sh - install, update and manage the LIMEN-AI RTX factory.
#
# Entry point for both the private accelerator tree and the public limen-rtx
# bootstrap repo. Prefers a whiptail/dialog TUI; falls back to plain prompts.
# Non-interactive use: pass --no-tui and the action as an argument.
#
#   ./install/limen-rtx.sh                  # interactive menu
#   ./install/limen-rtx.sh --no-tui install
#   ./install/limen-rtx.sh --no-tui update
#   LIMEN_GHCR_TOKEN=ghp_… ./install/limen-rtx.sh --no-tui install
#
# Env:
#   LIMEN_GHCR_TOKEN / --token   read-only PAT for the private GHCR package
#   LIMEN_MODEL_PROFILE          default catalogue profile (auto-picked by VRAM)
#   LIMEN_LLAMA_CTX             default 8192 (4096 on cards under 8 GB)
#   LIMEN_VERSION               image tag (default: VERSION file)
#   LIMEN_SKIP_MODEL=1          reuse an existing GGUF under ./models

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCEL_ROOT="$(cd "${INSTALL_DIR}/.." && pwd)"
ENV_FILE="${ACCEL_ROOT}/docker/factory.env"
CATALOG="${ACCEL_ROOT}/configs/model_catalog.json"
VERSION_FILE="${ACCEL_ROOT}/VERSION"
NO_TUI=0
TOKEN="${LIMEN_GHCR_TOKEN:-}"
ACTION=""

log()  { printf '%s\n' "== $*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    sed -n '2,22p' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-tui) NO_TUI=1; shift ;;
        --token) TOKEN="${2:-}"; shift 2 ;;
        --token=*) TOKEN="${1#--token=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        install|update|status|change-model|pair|uninstall|logs)
            ACTION="$1"; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# UI helpers: whiptail -> dialog -> plain
# ---------------------------------------------------------------------------

UI_BACKEND="plain"
if [ "${NO_TUI}" != "1" ]; then
    if command -v whiptail >/dev/null 2>&1; then
        UI_BACKEND="whiptail"
    elif command -v dialog >/dev/null 2>&1; then
        UI_BACKEND="dialog"
    fi
fi

ui_msg() {
    local title="$1" body="$2"
    case "${UI_BACKEND}" in
        whiptail) whiptail --title "${title}" --msgbox "${body}" 16 72 ;;
        dialog) dialog --title "${title}" --msgbox "${body}" 16 72; clear ;;
        *) printf '\n%s\n%s\n\n' "${title}" "${body}" ;;
    esac
}

ui_yesno() {
    local title="$1" body="$2"
    case "${UI_BACKEND}" in
        whiptail) whiptail --title "${title}" --yesno "${body}" 12 72 ;;
        dialog) dialog --title "${title}" --yesno "${body}" 12 72; clear ;;
        *)
            printf '%s\n%s [y/N] ' "${title}" "${body}"
            read -r ans
            case "${ans}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
            ;;
    esac
}

ui_input() {
    local title="$1" prompt="$2" default="${3:-}" result
    case "${UI_BACKEND}" in
        whiptail)
            result="$(whiptail --title "${title}" --inputbox "${prompt}" 12 72 "${default}" 3>&1 1>&2 2>&3)" || return 1
            printf '%s' "${result}"
            ;;
        dialog)
            result="$(dialog --title "${title}" --inputbox "${prompt}" 12 72 "${default}" 3>&1 1>&2 2>&3)" || return 1
            clear
            printf '%s' "${result}"
            ;;
        *)
            printf '%s [%s]: ' "${prompt}" "${default}"
            read -r result
            printf '%s' "${result:-${default}}"
            ;;
    esac
}

ui_password() {
    local title="$1" prompt="$2" result
    case "${UI_BACKEND}" in
        whiptail)
            result="$(whiptail --title "${title}" --passwordbox "${prompt}" 12 72 3>&1 1>&2 2>&3)" || return 1
            printf '%s' "${result}"
            ;;
        dialog)
            result="$(dialog --title "${title}" --passwordbox "${prompt}" 12 72 3>&1 1>&2 2>&3)" || return 1
            clear
            printf '%s' "${result}"
            ;;
        *)
            printf '%s: ' "${prompt}"
            stty -echo; read -r result; stty echo; printf '\n'
            printf '%s' "${result}"
            ;;
    esac
}

ui_menu() {
    # ui_menu title prompt tag1 item1 tag2 item2 …
    local title="$1" prompt="$2"; shift 2
    local args=("$@") n=$(( ${#args[@]} / 2 ))
    case "${UI_BACKEND}" in
        whiptail)
            whiptail --title "${title}" --menu "${prompt}" 20 72 "${n}" "${args[@]}" 3>&1 1>&2 2>&3
            ;;
        dialog)
            dialog --title "${title}" --menu "${prompt}" 20 72 "${n}" "${args[@]}" 3>&1 1>&2 2>&3
            clear
            ;;
        *)
            printf '\n%s\n%s\n' "${title}" "${prompt}"
            local i=0
            while [ $i -lt ${#args[@]} ]; do
                printf '  %s) %s\n' "${args[$i]}" "${args[$((i+1))]}"
                i=$((i + 2))
            done
            printf 'Choice: '
            read -r choice
            printf '%s' "${choice}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

read_version() {
    tr -d '[:space:]' < "${VERSION_FILE}" 2>/dev/null || echo "4.0.0"
}

compose_cmd() {
    local parts=(docker compose)
    if [ -f "${ACCEL_ROOT}/docker/Dockerfile" ] && [ -f "${ACCEL_ROOT}/docker-compose.build.yml" ]; then
        parts+=(-f docker-compose.yml -f docker-compose.build.yml)
    fi
    if [ -f "${ENV_FILE}" ]; then
        parts+=(--env-file "${ENV_FILE}")
    fi
    printf '%q ' "${parts[@]}"
}

host_vram_mb() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | head -n1 | tr -d ' ' || echo 0
    else
        echo 0
    fi
}

# Rough fit: weights_gb + 0.13*(ctx/1024) + 0.8  (mirrors server.py _fit_report)
required_gb() {
    local weights="$1" ctx="${2:-8192}"
    awk -v w="${weights}" -v c="${ctx}" 'BEGIN {
        kv = 0.13 * (c < 512 ? 512 : c) / 1024.0
        printf "%.1f", w + kv + 0.8
    }'
}

catalogue_pick_default() {
    local vram_mb="$1" ctx="${2:-8192}" best="" best_w=0
    local id weights req total_gb
    total_gb="$(awk -v m="${vram_mb}" 'BEGIN { printf "%.2f", m / 1024.0 }')"
    while IFS=$'\t' read -r id weights; do
        [ -n "${id}" ] || continue
        req="$(required_gb "${weights}" "${ctx}")"
        if awk -v r="${req}" -v t="${total_gb}" 'BEGIN { exit !(t > 0.1 && (t - r) >= 1.0) }'; then
            if awk -v w="${weights}" -v b="${best_w}" 'BEGIN { exit !(w > b) }'; then
                best="${id}"; best_w="${weights}"
            fi
        fi
    done < <(python3 - "${CATALOG}" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8")).get("profiles") or []
for row in rows:
    if not isinstance(row, dict) or not row.get("id"):
        continue
    if row.get("curl_fetch") in (False, "false", 0, "no"):
        pass
    w = row.get("weights_gb") or row.get("approx_vram_gb") or 0
    print(f"{row['id']}\t{w}")
PY
)
    # Prefer curl-fetchable profiles for first install when nothing fitted.
    if [ -z "${best}" ]; then
        best="$(python3 - "${CATALOG}" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8")).get("profiles") or []
for row in rows:
    if isinstance(row, dict) and row.get("curl_fetch") in (True, "true", 1, "yes"):
        print(row["id"]); break
PY
)"
    fi
    printf '%s' "${best:-plain}"
}

list_profiles_for_menu() {
    local vram_mb="$1" ctx="${2:-8192}"
    python3 - "${CATALOG}" "${vram_mb}" "${ctx}" <<'PY'
import json, sys
path, vram_mb, ctx = sys.argv[1], float(sys.argv[2] or 0), int(float(sys.argv[3] or 8192))
rows = json.load(open(path, encoding="utf-8")).get("profiles") or []
total = vram_mb / 1024.0
def required(w):
    return round(float(w) + 0.13 * (max(512, ctx) / 1024.0) + 0.8, 1)
for row in rows:
    if not isinstance(row, dict) or not row.get("id"):
        continue
    w = float(row.get("weights_gb") or row.get("approx_vram_gb") or 0)
    req = required(w)
    if total <= 0.1:
        tag = "unknown"
    elif total - req >= 1.0:
        tag = "fits"
    elif total - req >= 0:
        tag = "tight"
    else:
        tag = "too-large"
    label = f"{row.get('title') or row['id']} (~{req} GB, {tag})"
    print(f"{row['id']}\t{label}")
PY
}

ghcr_already_logged_in() {
    # Heuristic: docker config lists ghcr.io credentials.
    if [ -f "${HOME}/.docker/config.json" ]; then
        grep -q 'ghcr.io' "${HOME}/.docker/config.json" 2>/dev/null && return 0
    fi
    return 1
}

ensure_ghcr_login() {
    # Local source builds do not need GHCR.
    if [ -f "${ACCEL_ROOT}/docker/Dockerfile" ]; then
        log "Dockerfile present; GHCR login not required for a local build."
        return 0
    fi
    if ghcr_already_logged_in; then
        log "Already authenticated to ghcr.io"
        return 0
    fi
    if [ -z "${TOKEN}" ]; then
        if [ "${NO_TUI}" = "1" ]; then
            die "Private GHCR package: set LIMEN_GHCR_TOKEN or pass --token (read-only PAT)."
        fi
        TOKEN="$(ui_password "GHCR login" \
            "Paste a read-only GitHub PAT that can pull ghcr.io/${GITHUB_OWNER:-enricozanardo}/limen-factory")" \
            || die "login cancelled"
    fi
    [ -n "${TOKEN}" ] || die "empty token"
    log "Logging in to ghcr.io"
    printf '%s' "${TOKEN}" | docker login ghcr.io -u "${LIMEN_GHCR_USER:-${USER}}" --password-stdin \
        || die "docker login ghcr.io failed"
}

detect_lan_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show scope global 2>/dev/null \
          | awk '!/docker|br-|veth|virbr|cni|flannel/ {print $4; exit}' \
          | cut -d/ -f1
        return
    fi
    hostname -I 2>/dev/null | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

action_status() {
    local cmd; cmd="$(compose_cmd)"
    echo
    log "Compose status"
    (cd "${ACCEL_ROOT}" && eval "${cmd}" ps) || true
    echo
    log "Health"
    curl -fsS -m3 http://127.0.0.1:8770/health 2>/dev/null | python3 -m json.tool 2>/dev/null \
        || curl -fsS -m3 http://127.0.0.1:8770/health \
        || err "Factory not answering on :8770"
}

action_logs() {
    local cmd; cmd="$(compose_cmd)"
    (cd "${ACCEL_ROOT}" && eval "${cmd}" logs --tail=80 factory llama)
}

action_pair() {
    local ip; ip="$(detect_lan_ip || true)"
    [ -n "${ip}" ] || ip="<this-lan-ip>"
    ui_msg "Pair the board" \
"In the board UI open Settings and set the factory URL to:

  http://${ip}:8770

From the board itself, confirm:

  curl -s http://${ip}:8770/health

Factory status must show Reachable=yes and LLM reachable=yes."
}

action_uninstall() {
    ui_yesno "Uninstall" "Stop and remove the Docker stack? GGUFs under ./models are kept." \
        || return 0
    local cmd; cmd="$(compose_cmd)"
    (cd "${ACCEL_ROOT}" && eval "${cmd}" down) || true
    log "Stack stopped. Models under ${ACCEL_ROOT}/models were not deleted."
}

action_update() {
    local local_v remote_v
    local_v="$(read_version)"
    ensure_ghcr_login
    if [ -d "${ACCEL_ROOT}/.git" ]; then
        log "Fetching latest limen-rtx / accelerator tags"
        git -C "${ACCEL_ROOT}" fetch --tags --quiet 2>/dev/null || true
        remote_v="$(git -C "${ACCEL_ROOT}" tag -l 'v*' | sed 's/^v//' | sort -V | tail -n1)"
    else
        remote_v="${LIMEN_VERSION:-${local_v}}"
    fi
    [ -n "${remote_v}" ] || remote_v="${local_v}"
    log "Local ${local_v} → target ${remote_v}"
    if [ -f "${ENV_FILE}" ]; then
        if grep -q '^LIMEN_VERSION=' "${ENV_FILE}"; then
            sed -i "s/^LIMEN_VERSION=.*/LIMEN_VERSION=${remote_v}/" "${ENV_FILE}"
        else
            echo "LIMEN_VERSION=${remote_v}" >> "${ENV_FILE}"
        fi
    else
        die "No ${ENV_FILE}; run install first."
    fi
    echo "${remote_v}" > "${VERSION_FILE}"
    local cmd; cmd="$(compose_cmd)"
    (cd "${ACCEL_ROOT}" && eval "${cmd}" pull && eval "${cmd}" up -d)
    log "Waiting for health…"
    local ok=0
    for _ in $(seq 1 60); do
        h="$(curl -fsS -m3 http://127.0.0.1:8770/health 2>/dev/null || true)"
        case "${h}" in
            *"\"version\":\"${remote_v}\""*|*"\"llm_reachable\":true"*)
                ok=1; break
                ;;
        esac
        sleep 2
    done
    [ "${ok}" = "1" ] || die "Factory did not become healthy after update."
    curl -fsS -m3 http://127.0.0.1:8770/health || true
    echo
}

action_change_model() {
    [ -f "${ENV_FILE}" ] || die "No ${ENV_FILE}; run install first."
    local vram_mb ctx profile
    vram_mb="$(host_vram_mb)"
    ctx="$(grep '^LIMEN_LLAMA_CTX=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo 8192)"
    [ -n "${ctx}" ] || ctx=8192
    profile="$(pick_profile_interactive "${vram_mb}" "${ctx}")" || return 1
    LIMEN_MODEL_PROFILE="${profile}" LIMEN_SKIP_MODEL=0 \
        "${INSTALL_DIR}/rtx_factory_docker.sh"
}

pick_profile_interactive() {
    local vram_mb="$1" ctx="$2"
    local default recommended menu_args=()
    recommended="$(catalogue_pick_default "${vram_mb}" "${ctx}")"
    default="${LIMEN_MODEL_PROFILE:-${recommended}}"
    if [ "${NO_TUI}" = "1" ]; then
        printf '%s' "${default}"
        return 0
    fi
    while IFS=$'\t' read -r id label; do
        [ -n "${id}" ] || continue
        menu_args+=("${id}" "${label}")
    done < <(list_profiles_for_menu "${vram_mb}" "${ctx}")
    [ ${#menu_args[@]} -gt 0 ] || die "No profiles in ${CATALOG}"
    ui_menu "Model profile" \
        "VRAM ${vram_mb} MB, context ${ctx}. Recommended: ${recommended}" \
        "${menu_args[@]}"
}

action_install() {
    log "limen-rtx install (tree: ${ACCEL_ROOT}, UI: ${UI_BACKEND})"
    [ -f "${CATALOG}" ] || die "Missing ${CATALOG}"

    if [ "${NO_TUI}" != "1" ]; then
        ui_yesno "Prerequisites" \
            "Run the GPU-in-Docker preflight (install toolkit if needed)?" \
            && "${INSTALL_DIR}/rtx_preflight.sh" --install \
            || "${INSTALL_DIR}/rtx_preflight.sh" --verify
    else
        "${INSTALL_DIR}/rtx_preflight.sh" --verify
    fi

    ensure_ghcr_login

    local vram_mb ctx profile
    vram_mb="$(host_vram_mb)"
    if [ "${vram_mb}" -gt 0 ] 2>/dev/null && [ "${vram_mb}" -lt 8000 ]; then
        ctx="${LIMEN_LLAMA_CTX:-4096}"
    else
        ctx="${LIMEN_LLAMA_CTX:-8192}"
    fi
    if [ "${NO_TUI}" != "1" ]; then
        ctx="$(ui_input "Context size" "llama.cpp context tokens" "${ctx}")" || ctx=8192
    fi
    profile="$(pick_profile_interactive "${vram_mb}" "${ctx}")" || die "no profile selected"
    log "Selected profile=${profile} ctx=${ctx} vram=${vram_mb}MB"

    mkdir -p "${ACCEL_ROOT}/models" "${ACCEL_ROOT}/data/factory" "${ACCEL_ROOT}/docker"
    LIMEN_MODEL_PROFILE="${profile}" LIMEN_LLAMA_CTX="${ctx}" \
        LIMEN_VERSION="${LIMEN_VERSION:-$(read_version)}" \
        "${INSTALL_DIR}/rtx_factory_docker.sh"

    local ip; ip="$(detect_lan_ip || true)"
    [ -n "${ip}" ] || ip="<this-lan-ip>"
    ui_msg "Install complete" \
"Factory is up on http://127.0.0.1:8770

Pair the board to:
  http://${ip}:8770

Update later with:
  ./install/limen-rtx.sh update"
}

main_menu() {
    local choice
    choice="$(ui_menu "LIMEN-AI RTX factory" "Choose an action" \
        install "Install or repair the stack" \
        change-model "Download / switch model" \
        update "Update to a newer release" \
        status "Status and health" \
        logs "Recent container logs" \
        pair "Board pairing instructions" \
        uninstall "Stop and remove containers" \
        quit "Exit")" || exit 0
    case "${choice}" in
        install) action_install ;;
        change-model) action_change_model ;;
        update) action_update ;;
        status) action_status ;;
        logs) action_logs ;;
        pair) action_pair ;;
        uninstall) action_uninstall ;;
        quit|"") exit 0 ;;
        *) die "unknown menu choice: ${choice}" ;;
    esac
}

# ---------------------------------------------------------------------------

cd "${ACCEL_ROOT}"
if [ -n "${ACTION}" ]; then
    NO_TUI=1
    case "${ACTION}" in
        install) action_install ;;
        update) action_update ;;
        status) action_status ;;
        change-model) action_change_model ;;
        pair) action_pair ;;
        uninstall) action_uninstall ;;
        logs) action_logs ;;
    esac
else
    main_menu
fi
