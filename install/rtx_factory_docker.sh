#!/usr/bin/env bash
# rtx_factory_docker.sh - bring up the on-prem Docker RTX factory (Phase 1).
#
# Online bring-up: fetches the GGUF with curl (host preferred; Docker fallback),
# writes docker/factory.env, builds/starts Compose, waits for :8770.
#
#   ./install/rtx_factory_docker.sh
#   LIMEN_SKIP_MODEL=1 ./install/rtx_factory_docker.sh
#   LIMEN_MODEL_PROFILE=plain ./install/rtx_factory_docker.sh
#
# Prerequisite: tree on disk (see docs/fucina-guide.md) and a
# working GPU-in-Docker setup (./install/rtx_preflight.sh). Prefer
# ./install/fucina.sh for interactive install/update.
#
# Env:
#   LIMEN_MODEL_PROFILE   id from configs/model_catalog.json (default plain)
#   LIMEN_LLAMA_IMAGE     pin the llama.cpp image tag
#   LIMEN_LLAMA_NGL / LIMEN_LLAMA_CTX
#   LIMEN_HF_ENDPOINT     override base URL (default https://huggingface.co)
#   LIMEN_CURL_IMAGE      image used if host curl is missing (curlimages/curl)

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCEL_ROOT="$(cd "${INSTALL_DIR}/.." && pwd)"
MODELS_DIR="${ACCEL_ROOT}/models"
ENV_FILE="${ACCEL_ROOT}/docker/factory.env"
ACTIVE_MODEL="${MODELS_DIR}/active_model.env"
PROFILE="${LIMEN_MODEL_PROFILE:-plain}"
HF_ENDPOINT="${LIMEN_HF_ENDPOINT:-https://huggingface.co}"
CURL_IMAGE="${LIMEN_CURL_IMAGE:-curlimages/curl:8.12.1}"

SCRIPT_VERSION="$(cat "${ACCEL_ROOT}/VERSION" 2>/dev/null || echo 5.2.3)"

log() { printf '%s\n' "== $*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

log "rtx_factory_docker.sh ${SCRIPT_VERSION} (tree: ${ACCEL_ROOT})"

# -- prerequisites ----------------------------------------------------------
command -v docker >/dev/null 2>&1 || { err "docker not found. Run install/rtx_preflight.sh first."; exit 1; }
docker compose version >/dev/null 2>&1 || { err "'docker compose' v2 not found."; exit 1; }

# Probe HuggingFace reachability from the host (clear error beats a silent hang).
probe_hf() {
    local url="${HF_ENDPOINT}"
    log "Probing ${url} (10s timeout)..."
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSIL --max-time 10 "${url}" >/dev/null 2>&1; then
            log "Host can reach ${url}"
            return 0
        fi
    fi
    if docker run --rm --network host "${CURL_IMAGE}" \
         curl -fsSIL --max-time 10 "${url}" >/dev/null 2>&1; then
        log "Docker can reach ${url}"
        return 0
    fi
    err "Cannot reach ${url} from this host or from Docker."
    err "Options:"
    err "  1) Fix DNS/firewall/proxy, then retry"
    err "  2) Copy a pre-fetched model from the seller machine, e.g.:"
    err "       rsync -aP seller:…/limen-ai-accelerator/models/ ./models/"
    err "     then: LIMEN_SKIP_MODEL=1 ./install/rtx_factory_docker.sh"
    err "  3) Set LIMEN_HF_ENDPOINT to a reachable mirror if you use one"
    return 1
}

# Download one exact file with curl progress + resume. Prefer host curl (same
# network path as the browser); fall back to a curl container.
curl_fetch() {
    local url="$1" dest="$2"
    local dest_dir partial
    dest_dir="$(dirname "${dest}")"
    partial="${dest}.partial"
    mkdir -p "${dest_dir}"

    if [ -f "${dest}" ] && [ -s "${dest}" ]; then
        log "Already present: ${dest}"
        return 0
    fi

    log "Downloading $(basename "${dest}") (~5 GB — keep this terminal open)"
    log "URL: ${url}"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
            --connect-timeout 30 --continue-at - \
            --progress-bar \
            -o "${partial}" "${url}"
    else
        log "Host curl missing; using ${CURL_IMAGE}"
        # Bind the destination dir; write the partial next to the final file.
        docker run --rm --network host \
            -v "${dest_dir}:/out" \
            "${CURL_IMAGE}" \
            curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
                --connect-timeout 30 --continue-at - \
                --progress-bar \
                -o "/out/$(basename "${partial}")" "${url}"
    fi
    mv -f "${partial}" "${dest}"
    log "Saved ${dest} ($(du -h "${dest}" | awk '{print $1}'))"
}

fetch_model_curl() {
    local repo file out_rel url dest curl_ok
    local model_path draft_path="" spec_type="none"
    local catalog="${ACCEL_ROOT}/configs/model_catalog.json"

    catalog_get() {
        python3 - "$catalog" "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
path, profile, key = sys.argv[1], sys.argv[2], sys.argv[3]
rows = (json.load(open(path, encoding="utf-8")).get("profiles") or [])
for row in rows:
    if isinstance(row, dict) and row.get("id") == profile:
        val = row.get(key)
        print("" if val is None else val)
        raise SystemExit(0)
PY
    }

    if [ ! -f "${catalog}" ]; then
        err "model catalogue missing: ${catalog}"
        exit 2
    fi
    curl_ok="$(catalog_get "${PROFILE}" curl_fetch)"
    case "${curl_ok}" in
        True|true|1|yes) ;;
        *)
            err "profile '${PROFILE}' is not supported by the curl fetcher"
            err "Use a curl_fetch=true profile from ${catalog}, or run host/scripts/fetch_model.sh"
            exit 2
            ;;
    esac
    repo="${MODEL_REPO:-$(catalog_get "${PROFILE}" repo)}"
    file="${MODEL_FILE:-$(catalog_get "${PROFILE}" file)}"
    spec_type="$(catalog_get "${PROFILE}" spec_type)"
    [ -n "${spec_type}" ] || spec_type="none"
    if [ -z "${repo}" ] || [ -z "${file}" ]; then
        err "catalogue entry '${PROFILE}' is missing repo/file for curl fetch"
        exit 2
    fi
    alias_default="$(catalog_get "${PROFILE}" alias)"
    [ -n "${alias_default}" ] && LIMEN_LLM_ALIAS="${LIMEN_LLM_ALIAS:-${alias_default}}"

    out_rel="$(echo "${repo}" | tr '/' '_')"
    dest="${MODELS_DIR}/${out_rel}/${file}"
    url="${HF_ENDPOINT}/${repo}/resolve/main/${file}"

    mkdir -p "${MODELS_DIR}"
    probe_hf
    curl_fetch "${url}" "${dest}"
    model_path="${dest}"
    [ -s "${model_path}" ] || { err "download produced an empty file: ${model_path}"; exit 1; }
    log "model: ${model_path}"

    write_active_model "${model_path}" "${spec_type}" "${draft_path}"
}

# active_model.env is shared state between the two containers, so MODEL_PATH is
# written as the *container* path (/models/...). Both services mount this tree
# at /models, and the factory rewrites the same file when the UI loads another
# GGUF, so host paths would break on the first reload.
write_active_model() {
    local model_path="$1" spec_type="${2:-none}" draft_path="${3:-}" rel alias
    rel="${model_path#"${MODELS_DIR}/"}"
    alias="${LIMEN_LLM_ALIAS:-qwen3-8b}"
    {
        echo "# Written by rtx_factory_docker.sh on $(date -Iseconds)."
        echo "LIMEN_MODEL_PROFILE=${LIMEN_MODEL_PROFILE:-${PROFILE:-plain}}"
        echo "MODEL_PATH=/models/${rel}"
        echo "MODEL_ALIAS=${alias}"
        echo "SPEC_TYPE=${spec_type}"
        if [ -n "${draft_path}" ]; then
            echo "DRAFT_PATH=/models/${draft_path#"${MODELS_DIR}/"}"
        else
            echo "DRAFT_PATH="
        fi
    } > "${ACTIVE_MODEL}"
    log "Wrote ${ACTIVE_MODEL} (MODEL_PATH=/models/${rel})"
}

# Largest .gguf under a directory, ignoring interrupted .partial downloads.
find_gguf() {
    local dir="$1"
    [ -d "${dir}" ] || return 1
    find "${dir}" -type f -name '*.gguf' -printf '%s\t%p\n' 2>/dev/null \
        | sort -rn | head -n1 | cut -f2-
}

# Resolve / rewrite MODEL_PATH so a seller-machine absolute path in
# active_model.env still works after the tree is copied to Gentoo.
resolve_model_path() {
    local candidate="" base="" found="" prev="${MODEL_PATH:-}"
    mkdir -p "${MODELS_DIR}"

    if [ -f "${ACTIVE_MODEL}" ]; then
        # shellcheck disable=SC1090
        . "${ACTIVE_MODEL}"
        prev="${MODEL_PATH:-${prev}}"
    fi

    # 1. Honour MODEL_PATH when it lives under THIS tree's ./models and exists.
    # The file normally holds the container path (/models/...), which maps onto
    # the host tree one-to-one.
    case "${prev}" in
        /models/*)
            [ -f "${MODELS_DIR}/${prev#/models/}" ] && candidate="${MODELS_DIR}/${prev#/models/}"
            ;;
        "${MODELS_DIR}/"*)
            [ -f "${prev}" ] && candidate="${prev}"
            ;;
    esac

    # 2. Otherwise treat it as a foreign/stale path and match by filename locally.
    if [ -z "${candidate}" ] && [ -n "${prev}" ]; then
        base="$(basename "${prev}")"
        found="$(find "${MODELS_DIR}" -name "${base}" -type f 2>/dev/null | head -n1 || true)"
        if [ -n "${found}" ]; then
            log "MODEL_PATH pointed outside this tree; using local copy instead"
            candidate="${found}"
        fi
    fi

    # 3. Fall back to the canonical GGUF, then the largest GGUF under ./models.
    if [ -z "${candidate}" ] && [ -f "${MODELS_DIR}/unsloth_Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf" ]; then
        candidate="${MODELS_DIR}/unsloth_Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf"
    fi
    if [ -z "${candidate}" ]; then
        candidate="$(find_gguf "${MODELS_DIR}" || true)"
    fi

    if [ -z "${candidate}" ] || [ ! -f "${candidate}" ]; then
        err "No .gguf found under ${MODELS_DIR}"
        err "Copy the model from the seller machine, e.g.:"
        err "  rsync -aP seller:…/limen-ai-accelerator/models/ ./models/"
        err "or re-run WITHOUT LIMEN_SKIP_MODEL=1 to download it."
        return 1
    fi

    MODEL_PATH="${candidate}"
    write_active_model "${MODEL_PATH}" "${SPEC_TYPE:-none}" "${DRAFT_PATH:-}"
    log "Using model: ${MODEL_PATH}"
}

# -- ensure a model is present ----------------------------------------------
if ! resolve_model_path; then
    if [ "${LIMEN_SKIP_MODEL:-0}" = "1" ]; then
        exit 1
    fi
    log "Fetching model with curl (profile=${PROFILE}; no huggingface_hub)"
    fetch_model_curl
    resolve_model_path || exit 1
fi

MODEL_FILE="${MODEL_PATH#"${MODELS_DIR}/"}"
log "Model file (relative to ./models): ${MODEL_FILE}"

# -- write Compose env file -------------------------------------------------
# Default ctx 8192: the board's /translate prompt carries the whole KB schema,
# so a small context (e.g. 2048) makes llama.cpp reject the request with
# exceed_context_size_error and the board shows an opaque 500. With q8_0 KV
# cache this fits on a 16 GB card next to the ~5 GB weights. On <12 GB VRAM
# drop to 4096; do NOT go to 2048 unless the KB is tiny.
LLAMA_CTX="${LIMEN_LLAMA_CTX:-8192}"
if [ "${LLAMA_CTX}" -lt 4096 ] 2>/dev/null; then
    err "LIMEN_LLAMA_CTX=${LLAMA_CTX} is very small. The board sends the whole KB"
    err "schema to /translate; contexts below ~4096 cause exceed_context_size_error"
    err "and NL queries fail with an opaque 500. Raise it unless your KB is tiny."
fi
mkdir -p "${ACCEL_ROOT}/docker" "${ACCEL_ROOT}/data/factory"
{
    echo "# Written by rtx_factory_docker.sh on $(date -Iseconds)."
    echo "LIMEN_MODEL_FILE=${MODEL_FILE}"
    # Keep GGUFs downloaded through the UI owned by this user, not by root.
    echo "LIMEN_UID=$(id -u)"
    echo "LIMEN_GID=$(id -g)"
    echo "LIMEN_LLM_ALIAS=${LIMEN_LLM_ALIAS:-qwen3-8b}"
    echo "LIMEN_LLAMA_CTX=${LLAMA_CTX}"
    echo "LIMEN_LLAMA_NGL=${LIMEN_LLAMA_NGL:-99}"
    echo "LIMEN_VERSION=${LIMEN_VERSION:-$(cat "${ACCEL_ROOT}/VERSION" 2>/dev/null || echo 5.2.3)}"
    [ -n "${LIMEN_FACTORY_IMAGE:-}" ] && echo "LIMEN_FACTORY_IMAGE=${LIMEN_FACTORY_IMAGE}"
    [ -n "${LIMEN_LLAMA_IMAGE:-}" ] && echo "LIMEN_LLAMA_IMAGE=${LIMEN_LLAMA_IMAGE}"
    [ -n "${LIMEN_AI_VERSION:-}" ]  && echo "LIMEN_AI_VERSION=${LIMEN_AI_VERSION}"
    # Only needed when the NVIDIA runtime cannot inject nvidia-smi into the
    # factory container; the UI uses it to size models against the card.
    [ -n "${LIMEN_VRAM_TOTAL_MB:-}" ] && echo "LIMEN_VRAM_TOTAL_MB=${LIMEN_VRAM_TOTAL_MB}"
    [ -n "${LIMEN_GPU_NAME:-}" ]      && echo "LIMEN_GPU_NAME=${LIMEN_GPU_NAME}"
} > "${ENV_FILE}"
log "Wrote ${ENV_FILE} (ctx=${LLAMA_CTX})"

# -- pull or build + start --------------------------------------------------
cd "${ACCEL_ROOT}"
COMPOSE=(docker compose --env-file "${ENV_FILE}")
if [ -f "${ACCEL_ROOT}/docker/Dockerfile" ] && [ -f "${ACCEL_ROOT}/docker-compose.build.yml" ]; then
    log "Dockerfile present: building the factory image from this tree"
    COMPOSE+=(-f docker-compose.yml -f docker-compose.build.yml)
    "${COMPOSE[@]}" up -d --build
else
    log "Pulling the factory image by tag and starting the stack"
    "${COMPOSE[@]}" pull
    "${COMPOSE[@]}" up -d
fi

# -- wait for health --------------------------------------------------------
log "Waiting for the factory to become healthy on http://127.0.0.1:8770/health"
ok=0
for _ in $(seq 1 90); do
    if curl -fsS -m3 http://127.0.0.1:8770/health >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
done
if [ "${ok}" != "1" ]; then
    err "Factory did not answer on :8770. Inspect: docker compose logs factory"
    exit 1
fi

status="$(curl -fsS -m3 http://127.0.0.1:8770/health || true)"
echo "  health: ${status}"

# The UI proposes models that fit the card, which needs a real VRAM reading
# inside the factory container (NVIDIA runtime with the utility capability).
case "${status}" in
    *'"vram_total_mb":0'*|*'"vram_total_mb": 0'*)
        err "The factory cannot read the GPU (vram_total_mb=0), so the UI cannot"
        err "size models against your card. Check that the NVIDIA Container Toolkit"
        err "is wired into Docker (install/rtx_preflight.sh --verify). As a fallback,"
        err "state the card explicitly and recreate the factory:"
        err "  LIMEN_VRAM_TOTAL_MB=16384 LIMEN_SKIP_MODEL=1 ./install/rtx_factory_docker.sh"
        ;;
esac

# Detect the primary LAN IPv4 (skip docker/br-/veth/lo).
detect_lan_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show scope global 2>/dev/null \
          | awk '!/docker|br-|veth|virbr|cni|flannel/ {print $4; exit}' \
          | cut -d/ -f1
        return
    fi
    hostname -I 2>/dev/null | awk '{print $1}'
}

LAN_IP="$(detect_lan_ip || true)"
echo
log "LAN reachability check"
if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | grep -E ':8770\b' || \
        log "ss: nothing listening on :8770 (unexpected)"
elif command -v netstat >/dev/null 2>&1; then
    netstat -lntp 2>/dev/null | grep -E ':8770\b' || true
fi

if [ -n "${LAN_IP}" ]; then
    log "Host LAN IP appears to be ${LAN_IP}"
    if curl -fsS -m3 "http://${LAN_IP}:8770/health" >/dev/null 2>&1; then
        log "OK: factory answers on http://${LAN_IP}:8770/health (LAN-bind works)"
    else
        err "Factory answers on 127.0.0.1 but NOT on http://${LAN_IP}:8770"
        err "Almost always a host firewall. On Gentoo try one of:"
        err "  # nftables (common):"
        err "  sudo nft insert rule inet filter input tcp dport 8770 accept"
        err "  # or iptables:"
        err "  sudo iptables -I INPUT -p tcp --dport 8770 -j ACCEPT"
        err "Also confirm Docker may manage iptables (daemon.json must NOT set"
        err "  \"iptables\": false). Then re-test:"
        err "  curl -s http://${LAN_IP}:8770/health"
        err "From the board: curl -s http://${LAN_IP}:8770/health"
    fi
    echo
    log "Pair the board: Settings -> factory URL ="
    log "  http://${LAN_IP}:8770"
else
    log "Could not auto-detect LAN IP. From ifconfig/ip addr pick the Wi-Fi/Ethernet"
    log "address (e.g. 192.168.1.146) and pair the board to:"
    log "  http://<that-ip>:8770"
fi

echo
log "Waiting for llama (llm_reachable=true) — GPU model load can take 1-3 min"
llm_ok=0
for _ in $(seq 1 90); do
    h="$(curl -fsS -m3 http://127.0.0.1:8770/health 2>/dev/null || true)"
    case "${h}" in
        *'"llm_reachable":true'*) llm_ok=1; break ;;
    esac
    sleep 2
done
if [ "${llm_ok}" = "1" ]; then
    log "OK: llm_reachable=true"
    curl -fsS -m3 http://127.0.0.1:8770/health || true
    echo
else
    err "llm_reachable is still false. The board will look like there is no RTX."
    err "Diagnose on this host:"
    err "  docker compose --env-file docker/factory.env ps"
    err "  docker compose --env-file docker/factory.env logs --tail=80 llama"
    err "  curl -s http://127.0.0.1:8080/v1/models"
    err "  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi"
    err "Common causes: NVIDIA Container Toolkit not wired, bad MODEL_FILE path,"
    err "or llama container crash-looping. Fix llama before pairing the board."
fi

# -- end-to-end /translate smoke test ---------------------------------------
# /health only probes GET /v1/models, so it stays green even when the context
# is too small for a real query. The board sends its whole KB schema to
# /translate on every NL query; replay a realistically sized request here so a
# context that is too small fails loudly NOW instead of as an opaque 500 on the
# board. ~90 atoms mirrors a modest legal KB.
if [ "${llm_ok}" = "1" ]; then
    echo
    log "Smoke-testing /translate with a realistic KB-sized payload"
    smoke_payload="$(
        python3 - <<'PY' 2>/dev/null
import json
atoms = [f"publishedInOfficialJournal(normattiva:2023-08-10:23G{i:05d}, Ufficiale)"
         for i in range(90)]
print(json.dumps({
    "question": "Was law 23G00001 published in the Official Journal?",
    "atoms": atoms,
    "predicates": [{"name": "publishedInOfficialJournal", "arity": 2,
                    "description": "document published in the official journal"}],
    "constants": ["Ufficiale"],
}))
PY
    )"
    if [ -z "${smoke_payload}" ]; then
        # Fallback if python3 is unavailable: a smaller hand-built payload.
        smoke_payload='{"question":"test","atoms":["publishedInOfficialJournal(a, Ufficiale)"],"predicates":[{"name":"publishedInOfficialJournal","arity":2}],"constants":["a"]}'
    fi
    code="$(curl -s -o /tmp/limen_translate_smoke.json -w '%{http_code}' \
        -m 60 -X POST http://127.0.0.1:8770/translate \
        -H 'Content-Type: application/json' -d "${smoke_payload}" || echo 000)"
    if [ "${code}" = "200" ]; then
        log "OK: /translate returned 200 — NL queries will work"
    else
        err "/translate returned HTTP ${code} (NL queries will FAIL on the board)."
        err "Response body:"
        sed 's/^/    /' /tmp/limen_translate_smoke.json 2>/dev/null || true
        echo >&2
        if grep -qi 'context' /tmp/limen_translate_smoke.json 2>/dev/null; then
            err "This is a context-size problem. Increase LIMEN_LLAMA_CTX and recreate:"
            err "  LIMEN_LLAMA_CTX=8192 LIMEN_SKIP_MODEL=1 ./install/rtx_factory_docker.sh"
        else
            err "Inspect the factory log for the traceback:"
            err "  docker compose --env-file docker/factory.env logs --tail=80 factory"
        fi
    fi
    rm -f /tmp/limen_translate_smoke.json
fi

echo
log "Board pairing checklist:"
log "  1) From the PYNQ board itself (ssh or serial):"
log "       curl -s http://<this-lan-ip>:8770/health"
log "     If that fails while your PC succeeds, the Wi-Fi AP is isolating clients"
log "     (disable AP/client isolation, or put board+host on the same LAN segment)."
log "  2) Board UI Settings -> factory URL = http://<this-lan-ip>:8770"
log "  3) Factory status must show Reachable=yes and LLM reachable=yes"
