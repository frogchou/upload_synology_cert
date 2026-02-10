#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-config.txt}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
need_cmd curl
need_cmd jq
need_cmd openssl
need_cmd sed
need_cmd grep
need_cmd tee

[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
# shellcheck disable=SC1090
source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG_FILE" | sed 's/\r$//')

: "${NAS_URL:?Missing NAS_URL}"
: "${NAS_PORT:?Missing NAS_PORT}"
: "${USERNAME:?Missing USERNAME}"
: "${PASSWORD:?Missing PASSWORD}"
: "${CERT_PATH:?Missing CERT_PATH}"
: "${KEY_PATH:?Missing KEY_PATH}"
: "${CA_PATH:?Missing CA_PATH}"

LOG_DIR="${LOG_DIR:-/var/log/syno_cert_uploader}"
mkdir -p "$LOG_DIR" || die "Cannot create LOG_DIR: $LOG_DIR"
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="${LOG_DIR}/run_${RUN_ID}"
RUN_LOG="${LOG_DIR}/run_${RUN_ID}.log"
mkdir -p "$RUN_DIR" || true
exec > >(tee -a "$RUN_LOG") 2>&1

[[ -f "$CERT_PATH" ]] || die "CERT_PATH not found: $CERT_PATH"
[[ -f "$KEY_PATH"  ]] || die "KEY_PATH not found: $KEY_PATH"
[[ -f "$CA_PATH"   ]] || die "CA_PATH not found: $CA_PATH"

BASE="${NAS_URL}:${NAS_PORT}"
ENTRY="${BASE}/webapi/entry.cgi"

CURL_INSECURE="${CURL_INSECURE:-yes}"
CURL_COMMON=(-sS --connect-timeout 10 --max-time 60)
[[ "$CURL_INSECURE" == "yes" ]] && CURL_COMMON+=(-k)

save_raw() { local f="$1"; shift; printf '%s' "$*" > "${RUN_DIR}/${f}"; }
save_json_pretty() { local f="$1"; shift; printf '%s' "$*" | jq . > "${RUN_DIR}/${f}"; }

is_json() { echo "$1" | jq . >/dev/null 2>&1; }
success() { echo "$1" | jq -r '.success'; }
err_code() { echo "$1" | jq -r '.error.code // empty'; }

# Upsert a KEY=VALUE into config file (idempotent)
upsert_config_kv() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
  else
    printf "\n%s=%s\n" "$key" "$value" >> "$CONFIG_FILE"
  fi
}

http_get_entry() {
  local name="$1"; shift
  local raw
  raw="$(curl "${CURL_COMMON[@]}" --get "$@" "$ENTRY" || true)"
  save_raw "${name}.raw" "$raw"
  if is_json "$raw"; then
    save_json_pretty "${name}.json" "$raw"
  fi
  echo "$raw"
}

log "STEP 0: Loaded config from: ${CONFIG_FILE}"
log "        NAS: ${BASE}"
log "        LOG: ${RUN_LOG}"
log "        RUN: ${RUN_DIR}"

# ============================================================
# STEP 1: SYNO.API.Info query=all (discover paths/versions)
# ============================================================
log "STEP 1: Discover APIs via SYNO.API.Info"
API_INFO_RAW="$(http_get_entry "api_info" \
  --data-urlencode "api=SYNO.API.Info" \
  --data-urlencode "version=1" \
  --data-urlencode "method=query" \
  --data-urlencode "query=all")"

is_json "$API_INFO_RAW" || die "SYNO.API.Info returned non-JSON. See ${RUN_DIR}/api_info.raw"
[[ "$(success "$API_INFO_RAW")" == "true" ]] || die "SYNO.API.Info failed. See ${RUN_DIR}/api_info.json"

# Extract Auth path/maxVersion
AUTH_PATH="$(echo "$API_INFO_RAW" | jq -r '.data["SYNO.API.Auth"].path // empty')"
AUTH_VER="$(echo "$API_INFO_RAW" | jq -r '.data["SYNO.API.Auth"].maxVersion // empty')"
[[ -n "$AUTH_PATH" && -n "$AUTH_VER" ]] || die "Cannot find SYNO.API.Auth info in api_info.json"

log "  Found SYNO.API.Auth: path=${AUTH_PATH}, maxVersion=${AUTH_VER}"

# Extract Certificate API path/maxVersion
CERT_API_NAME="SYNO.Core.Certificate"
CERT_API_PATH="$(echo "$API_INFO_RAW" | jq -r --arg k "$CERT_API_NAME" '.data[$k].path // empty')"
CERT_API_VER="$(echo "$API_INFO_RAW" | jq -r --arg k "$CERT_API_NAME" '.data[$k].maxVersion // empty')"

log "  Found Certificate API: name=${CERT_API_NAME}, path=${CERT_API_PATH:-<empty>}, maxVersion=${CERT_API_VER:-<empty>}"

# ============================================================
# STEP 2: Login via SYNO.API.Auth (Mode B: device token)
# ============================================================
log "STEP 2: Login via SYNO.API.Auth (Mode B: device token)"

OTP_CODE="${OTP_CODE:-}"
ENABLE_DEVICE_TOKEN="${ENABLE_DEVICE_TOKEN:-yes}"
DEVICE_NAME="${DEVICE_NAME:-CertUploader}"
DEVICE_ID="${DEVICE_ID:-}"

login_basic() {
  http_get_entry "login_basic" \
    --data-urlencode "api=SYNO.API.Auth" \
    --data-urlencode "version=${AUTH_VER}" \
    --data-urlencode "method=login" \
    --data-urlencode "account=${USERNAME}" \
    --data-urlencode "passwd=${PASSWORD}" \
    --data-urlencode "session=Certificate" \
    --data-urlencode "format=sid" \
    --data-urlencode "enable_syno_token=yes"
}

login_omit_otp() {
  http_get_entry "login_omit" \
    --data-urlencode "api=SYNO.API.Auth" \
    --data-urlencode "version=${AUTH_VER}" \
    --data-urlencode "method=login" \
    --data-urlencode "account=${USERNAME}" \
    --data-urlencode "passwd=${PASSWORD}" \
    --data-urlencode "session=Certificate" \
    --data-urlencode "format=sid" \
    --data-urlencode "enable_syno_token=yes" \
    --data-urlencode "device_name=${DEVICE_NAME}" \
    --data-urlencode "device_id=${DEVICE_ID}"
}

login_otp_device() {
  http_get_entry "login_otp" \
    --data-urlencode "api=SYNO.API.Auth" \
    --data-urlencode "version=${AUTH_VER}" \
    --data-urlencode "method=login" \
    --data-urlencode "account=${USERNAME}" \
    --data-urlencode "passwd=${PASSWORD}" \
    --data-urlencode "session=Certificate" \
    --data-urlencode "format=sid" \
    --data-urlencode "enable_syno_token=yes" \
    --data-urlencode "otp_code=${OTP_CODE}" \
    --data-urlencode "enable_device_token=yes" \
    --data-urlencode "device_name=${DEVICE_NAME}"
}

LOGIN_RAW=""
if [[ -n "$DEVICE_ID" ]]; then
  log "  Attempt 1: omitted-OTP login with device_name + device_id"
  LOGIN_RAW="$(login_omit_otp)"
  if [[ "$(success "$LOGIN_RAW")" == "true" ]]; then
    log "  Omitted-OTP login succeeded."
  else
    log "  Omitted-OTP login failed (code=$(err_code "$LOGIN_RAW"))."
    LOGIN_RAW=""
  fi
fi

if [[ -z "$LOGIN_RAW" ]]; then
  log "  Attempt 2: basic login (may require 2FA)"
  LOGIN_RAW="$(login_basic)"
  if [[ "$(success "$LOGIN_RAW")" != "true" ]]; then
    code="$(err_code "$LOGIN_RAW")"
    if [[ "$code" == "403" || "$code" == "406" ]]; then
      log "  2FA required (code=$code). Attempt 3: OTP login with enable_device_token"
      
      # Prompt for OTP if missing/placeholder and interactive
      if [[ (-z "$OTP_CODE" || "$OTP_CODE" == "123456") ]]; then
        if [[ -t 0 ]]; then
            printf "Enter 6-digit OTP Code: " >&2
            read -r OTP_CODE
        else
            die "First run needs OTP_CODE (set to current 6-digit) in config.txt, or run interactively."
        fi
      fi

      LOGIN_RAW="$(login_otp_device)"
      
      # If failed with 404 (Invalid OTP) and interactive, retry once
      if [[ "$(success "$LOGIN_RAW")" != "true" ]]; then
           otp_err="$(err_code "$LOGIN_RAW")"
           if [[ "$otp_err" == "404" && -t 0 ]]; then
               log "  OTP code rejected (404). Please try again."
               printf "Enter new 6-digit OTP Code: " >&2
               read -r OTP_CODE
               LOGIN_RAW="$(login_otp_device)"
           fi
      fi

      [[ "$(success "$LOGIN_RAW")" == "true" ]] || die "OTP login failed. See ${RUN_DIR}/login_otp.json"
      log "  OTP login succeeded."
    else
      die "Login failed with code=${code:-unknown}. See ${RUN_DIR}/login_basic.json"
    fi
  else
    log "  Basic login succeeded."
  fi
fi

SID="$(echo "$LOGIN_RAW" | jq -r '.data.sid // empty')"
SYNOTOKEN="$(echo "$LOGIN_RAW" | jq -r '.data.synotoken // empty')"

# Persist device_id (returned by enable_device_token)
DEV_ID="$(echo "$LOGIN_RAW" | jq -r '.data.device_id // empty')"
if [[ -n "$DEV_ID" && "$DEV_ID" != "null" ]]; then
  log "  Received device_id. Persisting DEVICE_ID into config: ${CONFIG_FILE}"
  upsert_config_kv "DEVICE_ID" "$DEV_ID"
  log "  DEVICE_ID saved."
fi

# Now that we are authenticated, certificate API path might be accessible; re-query if missing.
if [[ -z "$CERT_API_PATH" || -z "$CERT_API_VER" ]]; then
  log "STEP 1b: Re-discover APIs after login (to get certificate API path/version)"
  API_INFO2_RAW="$(http_get_entry "api_info_after_login" \
    --data-urlencode "api=SYNO.API.Info" \
    --data-urlencode "version=1" \
    --data-urlencode "method=query" \
    --data-urlencode "query=all" \
    --data-urlencode "_sid=${SID}" \
    $( [[ -n "$SYNOTOKEN" ]] && printf -- '--data-urlencode SynoToken=%s ' "$SYNOTOKEN" ))"

  if is_json "$API_INFO2_RAW" && [[ "$(success "$API_INFO2_RAW")" == "true" ]]; then
    CERT_API_PATH="$(echo "$API_INFO2_RAW" | jq -r --arg k "$CERT_API_NAME" '.data[$k].path // empty')"
    CERT_API_VER="$(echo "$API_INFO2_RAW" | jq -r --arg k "$CERT_API_NAME" '.data[$k].maxVersion // empty')"
  fi
fi

[[ -n "$CERT_API_PATH" ]] || die "Certificate API path is empty; likely permission issue. Check account permissions. See ${RUN_DIR}/api_info_after_login.json"
CERT_ENTRY="${BASE}/webapi/${CERT_API_PATH}"
log "  Certificate API URL: ${CERT_ENTRY}, version=${CERT_API_VER}"

# ============================================================
# STEP 3: Upload certificate (import) - update mode supported
# Strategy:
#  - Put _sid and SynoToken into URL query (not multipart fields)
#  - Also send SynoToken as header (some DSM versions require CSRF header)
#  - If CERT_ID exists -> update that certificate (no new entries)
#  - If CERT_ID missing -> first import creates one, then persist CERT_ID back to config
# ============================================================
log "STEP 3: Upload certificate via ${CERT_API_NAME}.import (update-capable)"

CERT_DESC="${CERT_DESC:-}"
if [[ -z "$CERT_DESC" ]]; then
  CERT_CN="$(openssl x509 -in "$CERT_PATH" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' | head -n1 || true)"
  CERT_DESC="$CERT_CN"
fi
log "  Using CERT_DESC: ${CERT_DESC:-<empty>}"

CERT_ID="${CERT_ID:-}"
if [[ -n "$CERT_ID" ]]; then
  log "  Update mode: CERT_ID=${CERT_ID} (will overwrite existing certificate, no new entry)"
else
  log "  Create mode: CERT_ID is empty (DSM will create a new certificate once, then script will save CERT_ID)"
fi

# Build URL with session/token in query, plus optional id for update
IMPORT_URL="${CERT_ENTRY}?api=${CERT_API_NAME}&version=${CERT_API_VER:-1}&method=import&_sid=${SID}"
if [[ -n "$CERT_ID" ]]; then
  IMPORT_URL="${IMPORT_URL}&id=${CERT_ID}"
fi
if [[ -n "$SYNOTOKEN" ]]; then
  IMPORT_URL="${IMPORT_URL}&SynoToken=${SYNOTOKEN}"
fi

IMPORT_RAW="$(curl "${CURL_COMMON[@]}" \
  -X POST \
  -H "X-SYNO-TOKEN: ${SYNOTOKEN}" \
  -F "desc=${CERT_DESC}" \
  -F "cert=@${CERT_PATH}" \
  -F "key=@${KEY_PATH}" \
  -F "inter_cert=@${CA_PATH}" \
  "${IMPORT_URL}" \
  || true)"

save_raw "cert_import.raw" "$IMPORT_RAW"
is_json "$IMPORT_RAW" || die "Import returned non-JSON. See ${RUN_DIR}/cert_import.raw"
save_json_pretty "cert_import.json" "$IMPORT_RAW"

if [[ "$(success "$IMPORT_RAW")" != "true" ]]; then
  code="$(err_code "$IMPORT_RAW")"
  die "Import failed (code=${code:-unknown}). See ${RUN_DIR}/cert_import.json"
fi

IMPORTED_ID="$(echo "$IMPORT_RAW" | jq -r '.data.id // empty')"
log "  Import success. Returned id=${IMPORTED_ID:-<empty>}"

# If CERT_ID is empty, persist the returned id as the stable update target for future runs
if [[ -z "$CERT_ID" && -n "$IMPORTED_ID" && "$IMPORTED_ID" != "null" ]]; then
  log "  Persisting CERT_ID=${IMPORTED_ID} into config for future update runs."
  upsert_config_kv "CERT_ID" "$IMPORTED_ID"
  log "  CERT_ID saved."
fi

# ============================================================
# STEP 4: Logout
# ============================================================
log "STEP 4: Logout"
LOGOUT_RAW="$(http_get_entry "logout" \
  --data-urlencode "api=SYNO.API.Auth" \
  --data-urlencode "version=${AUTH_VER}" \
  --data-urlencode "method=logout" \
  --data-urlencode "session=Certificate" \
  --data-urlencode "_sid=${SID}" \
  $( [[ -n "$SYNOTOKEN" ]] && printf -- '--data-urlencode SynoToken=%s ' "$SYNOTOKEN" ))" || true

log "DONE. Run dir: ${RUN_DIR}"

