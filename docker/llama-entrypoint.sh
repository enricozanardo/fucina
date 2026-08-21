#!/bin/sh
# llama-entrypoint.sh - model-watching entrypoint for the llama.cpp container.
#
# The factory owns model selection: it downloads GGUFs into the shared ./models
# tree and rewrites models/active_model.env. This wrapper turns that file into
# the running server, so "Download & load" in the UI reloads llama.cpp without
# anyone touching the host and without handing the factory a Docker socket.
#
# Behaviour:
#   * start llama-server from active_model.env (MODEL_PATH / MODEL_ALIAS /
#     SPEC_TYPE / DRAFT_PATH), falling back to LIMEN_MODEL_FILE when the file is
#     missing, so an existing install keeps booting after an upgrade;
#   * poll the file every LIMEN_WATCH_INTERVAL_S seconds and restart the server
#     when its contents change;
#   * restart the server (with backoff) if it exits on its own.
#
# POSIX sh on purpose: the upstream CUDA image is minimal.

set -u

MODELS_DIR="${LIMEN_MODELS_DIR:-/models}"
ENV_FILE="${MODELS_DIR}/active_model.env"
INTERVAL="${LIMEN_WATCH_INTERVAL_S:-2}"
ALIAS_DEFAULT="${LIMEN_LLM_ALIAS:-qwen3-8b}"
HOST="${LIMEN_LLAMA_HOST:-0.0.0.0}"
PORT="${LIMEN_LLAMA_PORT:-8080}"
CTX="${LIMEN_LLAMA_CTX:-8192}"
NGL="${LIMEN_LLAMA_NGL:-99}"
SPEC_N_MAX="${LIMEN_SPEC_N_MAX:-2}"

log() { printf '[limen-watch] %s\n' "$*"; }

if [ -n "${LLAMA_BIN:-}" ]; then
    :
elif command -v llama-server >/dev/null 2>&1; then
    LLAMA_BIN="$(command -v llama-server)"
elif [ -x /app/llama-server ]; then
    LLAMA_BIN=/app/llama-server
elif [ -x /llama-server ]; then
    LLAMA_BIN=/llama-server
else
    log "FATAL: llama-server binary not found; set LLAMA_BIN."
    exit 1
fi

CHILD_PID=""
LAST_NOTICE=""

# The poll loop would otherwise repeat the same complaint every couple of
# seconds and bury the useful lines.
log_once() {
    [ "$*" = "${LAST_NOTICE}" ] && return 0
    LAST_NOTICE="$*"
    log "$*"
}

# Read the current selection into MODEL_PATH / MODEL_ALIAS / SPEC_TYPE /
# DRAFT_PATH, setting SELECTION_VALID. The factory writes container-visible
# paths (/models/...) because both containers mount the same tree at the same
# mount point.
#
# A selection whose MODEL_PATH is missing is never adopted: serving the previous
# weights under the newly requested alias would make the factory believe a load
# succeeded when it did not.
read_selection() {
    MODEL_PATH=""
    MODEL_ALIAS=""
    SPEC_TYPE="none"
    DRAFT_PATH=""
    SELECTION_VALID=0
    # The raw text, not just the parsed fields: the factory rewrites this file
    # on every activate, so "Reload" on the model already loaded must bounce the
    # server instead of silently reporting success.
    RAW_SELECTION="$(cat "${ENV_FILE}" 2>/dev/null || true)"
    if [ -f "${ENV_FILE}" ]; then
        # shellcheck disable=SC1090
        . "${ENV_FILE}" 2>/dev/null || log_once "WARNING: ${ENV_FILE} is not readable as shell env."
    fi
    [ -n "${MODEL_ALIAS}" ] || MODEL_ALIAS="${ALIAS_DEFAULT}"
    [ -n "${SPEC_TYPE}" ] || SPEC_TYPE="none"
    if [ -n "${MODEL_PATH}" ] && [ -f "${MODEL_PATH}" ]; then
        SELECTION_VALID=1
        return 0
    fi
    if [ -n "${MODEL_PATH}" ]; then
        log_once "WARNING: MODEL_PATH '${MODEL_PATH}' is not a file in this container; keeping the current model."
    fi
    # Bootstrap only: before anything has been started, fall back to the model
    # named in the Compose environment so an upgraded stack still comes up.
    if [ -z "${CHILD_PID}" ] && [ -n "${LIMEN_MODEL_FILE:-}" ] \
        && [ -f "${MODELS_DIR}/${LIMEN_MODEL_FILE}" ]; then
        MODEL_PATH="${MODELS_DIR}/${LIMEN_MODEL_FILE}"
        MODEL_ALIAS="${ALIAS_DEFAULT}"
        SPEC_TYPE="none"
        DRAFT_PATH=""
        SELECTION_VALID=1
        log_once "No usable active_model.env: starting LIMEN_MODEL_FILE=${LIMEN_MODEL_FILE}"
        return 0
    fi
    MODEL_PATH=""
    return 0
}

# Fingerprint of the selection: any change here means "reload".
fingerprint() {
    printf '%s|%s' "${MODEL_PATH}" "${RAW_SELECTION}"
}

start_llama() {
    set -- "${LLAMA_BIN}" \
        --model "${MODEL_PATH}" \
        --alias "${MODEL_ALIAS}" \
        --host "${HOST}" --port "${PORT}" \
        --ctx-size "${CTX}" \
        -ngl "${NGL}" \
        --cache-type-k q8_0 --cache-type-v q8_0

    # Qwen3 and friends spend the whole token budget inside a <think> block
    # unless thinking is disabled, which yields an empty knowledge base.
    if [ "${LIMEN_DISABLE_THINKING:-1}" = "1" ]; then
        set -- "$@" --chat-template-kwargs '{"enable_thinking":false}'
    fi

    case "${SPEC_TYPE}" in
        none|"") ;;
        draft-mtp)
            set -- "$@" --spec-type draft-mtp --spec-draft-n-max "${SPEC_N_MAX}"
            ;;
        draft-eagle3)
            if [ -n "${DRAFT_PATH}" ] && [ -f "${DRAFT_PATH}" ]; then
                set -- "$@" --spec-type draft-eagle3 \
                    --model-draft "${DRAFT_PATH}" --spec-draft-n-max "${SPEC_N_MAX}"
            else
                log "draft-eagle3 requested but DRAFT_PATH missing; plain decoding."
            fi
            ;;
        *)
            log "unknown SPEC_TYPE '${SPEC_TYPE}'; plain decoding."
            ;;
    esac

    log "starting: $*"
    "$@" &
    CHILD_PID=$!
}

stop_llama() {
    [ -n "${CHILD_PID}" ] || return 0
    kill -TERM "${CHILD_PID}" 2>/dev/null || true
    i=0
    while [ "${i}" -lt 60 ]; do
        kill -0 "${CHILD_PID}" 2>/dev/null || break
        sleep 0.5
        i=$((i + 1))
    done
    kill -0 "${CHILD_PID}" 2>/dev/null && kill -KILL "${CHILD_PID}" 2>/dev/null
    wait "${CHILD_PID}" 2>/dev/null
    CHILD_PID=""
}

on_signal() {
    log "signal received; shutting down"
    stop_llama
    exit 0
}
trap on_signal INT TERM

log "watching ${ENV_FILE} (interval ${INTERVAL}s, binary ${LLAMA_BIN})"

read_selection
while [ "${SELECTION_VALID}" != "1" ]; do
    log_once "no model selected yet: waiting for ${ENV_FILE} (download one from the UI)"
    sleep 5
    read_selection
done

CURRENT="$(fingerprint)"
start_llama
FAILURES=0

while true; do
    sleep "${INTERVAL}"

    read_selection
    NEXT="$(fingerprint)"
    if [ "${SELECTION_VALID}" = "1" ] && [ "${NEXT}" != "${CURRENT}" ]; then
        log "selection changed -> ${MODEL_PATH} (alias ${MODEL_ALIAS}, spec ${SPEC_TYPE})"
        stop_llama
        CURRENT="${NEXT}"
        FAILURES=0
        start_llama
        continue
    fi

    # Crash recovery: keep the port up so the factory sees a real failure only
    # when the weights themselves are unusable.
    if [ -n "${CHILD_PID}" ] && ! kill -0 "${CHILD_PID}" 2>/dev/null; then
        wait "${CHILD_PID}" 2>/dev/null
        CHILD_PID=""
        FAILURES=$((FAILURES + 1))
        BACKOFF=$((FAILURES * 5))
        [ "${BACKOFF}" -gt 60 ] && BACKOFF=60
        log "llama-server exited (failure ${FAILURES}); restarting in ${BACKOFF}s"
        sleep "${BACKOFF}"
        start_llama
    fi
done
