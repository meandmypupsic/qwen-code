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

jwt_part_count() {
  if [ -z "$1" ]; then
    printf '0'
    return
  fi
  printf '%s' "$1" | awk -F. '{print NF}'
}

is_jwt_like() {
  [ "$(jwt_part_count "$1")" -eq 3 ]
}

if [ -z "${BLAZE_DP_TOKEN:-}" ] &&
  ! is_jwt_like "${BLAZE_DP_JWT:-}" &&
  ! is_jwt_like "${NESSY_CLI_DP_AUTH_TOKEN:-}"; then
  fail "set BLAZE_DP_TOKEN/DP_TOKEN for Nestor exchange, or BLAZE_DP_JWT/NESSY_CLI_DP_AUTH_TOKEN for delegated JWT auth"
fi

export BLAZE_RUNTIME_PORT="${BLAZE_RUNTIME_PORT:-4170}"
export BLAZE_RUNTIME_HOST="${BLAZE_RUNTIME_HOST:-0.0.0.0}"
export BLAZE_RUNTIME_WORKSPACE="${BLAZE_RUNTIME_WORKSPACE:-/workspace}"
export BLAZE_RUNTIME_PACKAGE="${BLAZE_RUNTIME_PACKAGE:-@art/blaze-runtime}"
export BLAZE_RUNTIME_HOME="${BLAZE_RUNTIME_HOME:-/root/.blaze-runtime}"
export BLAZE_DP_CREDENTIALS_PATH="${BLAZE_DP_CREDENTIALS_PATH:-${BLAZE_RUNTIME_HOME}/dp_auth_creds.json}"
export BLAZE_NESTOR_SERVER_URL="${BLAZE_NESTOR_SERVER_URL:-https://code-completion-nestor.tcsbank.ru}"
export DP_AUTH="${DP_AUTH:-true}"

mkdir -p "$BLAZE_RUNTIME_WORKSPACE" "$BLAZE_RUNTIME_HOME" /root/.nessy

write_credentials_from_jwt() {
  local jwt="$1"
  if ! is_jwt_like "$jwt"; then
    fail "Nestor credentials require a valid JWT with 3 parts"
  fi

  local jwt_payload
  jwt_payload="$(printf '%s' "$jwt" | cut -d. -f2 | tr -- '-_' '+/')"
  case $((${#jwt_payload} % 4)) in
    2) jwt_payload="${jwt_payload}==" ;;
    3) jwt_payload="${jwt_payload}=" ;;
  esac

  local decoded_payload
  decoded_payload="$(printf '%s' "$jwt_payload" | base64 -d 2>/dev/null || printf '{}')"

  local expires_at
  expires_at="$(printf '%s' "$decoded_payload" | jq -r '.exp // 0')"
  if [ -z "$expires_at" ] || [ "$expires_at" = "0" ]; then
    fail "Nestor JWT payload does not contain numeric exp"
  fi

  local expires_at_ms=$((expires_at * 1000))
  local username
  local user_id
  username="$(printf '%s' "$decoded_payload" | jq -r '.preferred_username // .email // .sub // ""')"
  user_id="$(printf '%s' "$decoded_payload" | jq -r '.sub // ""')"

  mkdir -p "$(dirname "$BLAZE_DP_CREDENTIALS_PATH")"
  jq -n \
    --arg jwt "$jwt" \
    --arg username "$username" \
    --arg userId "$user_id" \
    --argjson expiresAt "$expires_at_ms" \
    '{jwt: $jwt, expiresAt: $expiresAt, username: $username, userId: $userId, cachedModels: []}' \
    >"$BLAZE_DP_CREDENTIALS_PATH"
  chmod 600 "$BLAZE_DP_CREDENTIALS_PATH"

  cp "$BLAZE_DP_CREDENTIALS_PATH" /root/.nessy/dp_auth_creds.json
  chmod 600 /root/.nessy/dp_auth_creds.json
  log "Nestor credentials cache prepared"
}

prepare_nestor_credentials() {
  if [ -n "${BLAZE_DP_JWT:-}" ]; then
    if is_jwt_like "$BLAZE_DP_JWT"; then
      log "delegated Nestor JWT env detected (BLAZE_DP_JWT), skipping DP token exchange"
      write_credentials_from_jwt "$BLAZE_DP_JWT"
      return
    fi
    log "BLAZE_DP_JWT is set but not a valid JWT; will use DP token exchange if available"
  fi

  if [ -n "${NESSY_CLI_DP_AUTH_TOKEN:-}" ]; then
    if is_jwt_like "$NESSY_CLI_DP_AUTH_TOKEN"; then
      log "delegated Nestor JWT env detected (NESSY_CLI_DP_AUTH_TOKEN), skipping DP token exchange"
      write_credentials_from_jwt "$NESSY_CLI_DP_AUTH_TOKEN"
      return
    fi
    log "NESSY_CLI_DP_AUTH_TOKEN is set but not a valid JWT; will use DP token exchange if available"
  fi

  if [ -z "${BLAZE_DP_TOKEN:-}" ]; then
    return
  fi

  local token_url="${BLAZE_NESTOR_SERVER_URL%/}/api/v2/token"
  local response_file="/tmp/blaze-runtime-nestor-token.json"

  log "exchanging DP token for Nestor JWT"
  if ! curl --fail --silent --show-error --request POST \
    --url "$token_url" \
    --header 'Accept: application/json' \
    --header "Authorization: Bearer ${BLAZE_DP_TOKEN}" \
    --header 'Content-Type: application/json' \
    --data '{}' >"$response_file"; then
    fail "Nestor token exchange failed at ${token_url}. Check DP token validity and sandbox egress to Nestor."
  fi

  local jwt
  jwt="$(jq -r '.jwt // empty' "$response_file")"
  if [ -z "$jwt" ] || [ "$(printf '%s' "$jwt" | awk -F. '{print NF}')" -ne 3 ]; then
    fail "Nestor token exchange response did not contain a valid jwt field"
  fi

  write_credentials_from_jwt "$jwt"
}

prepare_nestor_credentials

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
log "dp_credentials_path=${BLAZE_DP_CREDENTIALS_PATH}"

exec blaze-runtime serve \
  --hostname "$BLAZE_RUNTIME_HOST" \
  --port "$BLAZE_RUNTIME_PORT" \
  --workspace "$BLAZE_RUNTIME_WORKSPACE" \
  --require-auth
