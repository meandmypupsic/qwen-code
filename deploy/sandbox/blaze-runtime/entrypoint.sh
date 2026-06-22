#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[blaze-runtime-entrypoint] %s\n' "$*"
}

fail() {
  printf '[blaze-runtime-entrypoint] ERROR: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -gt 0 ]; then
  log "custom command provided, executing it instead of default serve command"
  exec "$@"
fi

if [ -z "${BLAZE_RUNTIME_TOKEN:-}" ] && [ -n "${QWEN_SERVER_TOKEN:-}" ]; then
  export BLAZE_RUNTIME_TOKEN="$QWEN_SERVER_TOKEN"
fi

if [ -z "${BLAZE_RUNTIME_TOKEN:-}" ]; then
  fail "BLAZE_RUNTIME_TOKEN is required. Generate it in Blaze/BFF and pass it as a sandbox env var."
fi

if [ -z "${BLAZE_DP_TOKEN:-}" ] && [ -n "${DP_TOKEN:-}" ]; then
  export BLAZE_DP_TOKEN="$DP_TOKEN"
fi

if [ -z "${BLAZE_DP_TOKEN:-}" ] &&
  [ -z "${BLAZE_DP_JWT:-}" ] &&
  [ -z "${NESSY_CLI_DP_AUTH_TOKEN:-}" ]; then
  fail "set BLAZE_DP_TOKEN/DP_TOKEN for Nestor exchange, or BLAZE_DP_JWT/NESSY_CLI_DP_AUTH_TOKEN for delegated JWT auth"
fi

export BLAZE_RUNTIME_PORT="${BLAZE_RUNTIME_PORT:-4170}"
export BLAZE_RUNTIME_HOST="${BLAZE_RUNTIME_HOST:-0.0.0.0}"
export BLAZE_RUNTIME_WORKSPACE="${BLAZE_RUNTIME_WORKSPACE:-/workspace}"
export BLAZE_RUNTIME_PACKAGE="${BLAZE_RUNTIME_PACKAGE:-@art/blaze-runtime}"

mkdir -p "$BLAZE_RUNTIME_WORKSPACE" /root/.blaze-runtime

if ! command -v blaze-runtime >/dev/null 2>&1; then
  fail "blaze-runtime binary not found in PATH. Check npm package install in Dockerfile."
fi

if [ -z "${BLAZE_RUNTIME_ENTRY:-}" ]; then
  global_root="$(npm root -g)"
  candidates=(
    "${global_root}/${BLAZE_RUNTIME_PACKAGE}/blaze-runtime.js"
    "${global_root}/${BLAZE_RUNTIME_PACKAGE}/dist/blaze-runtime.js"
    "${global_root}/${BLAZE_RUNTIME_PACKAGE}/dist/src/blaze-runtime.js"
  )

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      export BLAZE_RUNTIME_ENTRY="$candidate"
      break
    fi
  done
fi

if [ -z "${BLAZE_RUNTIME_ENTRY:-}" ] || [ ! -f "$BLAZE_RUNTIME_ENTRY" ]; then
  fail "BLAZE_RUNTIME_ENTRY could not be resolved. Expected a blaze-runtime.js file in the global npm package."
fi

log "starting blaze-runtime serve"
log "host=${BLAZE_RUNTIME_HOST} port=${BLAZE_RUNTIME_PORT} workspace=${BLAZE_RUNTIME_WORKSPACE}"
log "runtime_entry=${BLAZE_RUNTIME_ENTRY}"
log "package=${BLAZE_RUNTIME_PACKAGE}"

exec blaze-runtime serve \
  --hostname "$BLAZE_RUNTIME_HOST" \
  --port "$BLAZE_RUNTIME_PORT" \
  --workspace "$BLAZE_RUNTIME_WORKSPACE" \
  --require-auth
