#!/bin/bash
# Non-exportability proof: the key files on disk are TPM-sealed handles, not
# keys. This sits between Part 6 (enrolment) and Part 7 (login) and is the
# claim the rest of the lab rests on. Failure of the middle check is the
# success condition, so nothing here aborts on a non-zero exit; each check
# reports expected vs actual instead.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
STATE_DIR="${LAB_TPM_DIR}/${DEVICE}"
APP_BLOB="${STATE_DIR}/app.blob"
AK_BLOB="${STATE_DIR}/ak.blob"
KEY_JSON="${STATE_DIR}/client-key.json"
CRT="${STATE_DIR}/client.crt"

log_step "Proof: the private key cannot leave the TPM (${DEVICE})"

[[ -f "${LAB_DIR}/env.sh" ]] || die "no ${LAB_DIR}/env.sh — run 'task provision' first"
[[ -s "${APP_BLOB}" && -s "${CRT}" ]] || die "no attested key at ${STATE_DIR} — run 'task enrol' first"

# --- 1. what the file claims to be ------------------------------------------
log_step "1. What is in app.blob"
log_detail "The Vault CLI stores TPM keys as a JSON handle, not a PEM key."
fields="$(as_lab_user jq -r 'keys | join(", ")' "${APP_BLOB}")"
report_expect "Public, KeyBlob, Name, and the AK's certification of the key — no private key field" \
              "${fields}"
keyblob_bytes="$(as_lab_user jq -r '.KeyBlob' "${APP_BLOB}" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
log_ok "KeyBlob is ${keyblob_bytes} bytes of TPM ciphertext: the private area, sealed under this TPM's storage key"

# --- 2. the negative: it is not a key any software can load ------------------
log_step "2. Load it as a private key WITHOUT the TPM — this must fail"
log_detail "openssl pkey -in ${APP_BLOB} -noout -text"
rc=0
out="$(as_lab_user_allow_fail openssl pkey -in "${APP_BLOB}" -noout -text 2>&1)" || rc=$?
first_line="$(printf '%s' "${out}" | head -1)"
report_expect "failure: there is no private key here to load" \
  "exit ${rc}${first_line:+ — ${first_line}}"
if (( rc != 0 )); then
  log_ok "refused — without the TPM there is nothing here to load"
else
  log_error "the blob was readable as a private key — it is NOT TPM-backed"
fi

# --- 3. what the bytes actually are -----------------------------------------
log_step "3. The public area: a TPM object with attributes the TPM enforces"
# .Public is a TPMT_PUBLIC; tpm2_print wants the size-prefixed TPM2B form.
pub_tmp="$(mktemp)"
trap 'rm -f "${pub_tmp}"' EXIT
as_lab_user jq -r '.Public' "${APP_BLOB}" | base64 -d > "${pub_tmp}.raw" 2>/dev/null || true
if [[ -s "${pub_tmp}.raw" ]]; then
  len="$(wc -c < "${pub_tmp}.raw" | tr -d ' ')"
  { printf "\\x$(printf '%02x' $(( len >> 8 )))\\x$(printf '%02x' $(( len & 255 )))"; cat "${pub_tmp}.raw"; } > "${pub_tmp}"
  rm -f "${pub_tmp}.raw"
  print_rc=0
  print_out="$(tpm2_print -t TPM2B_PUBLIC "${pub_tmp}" 2>&1)" || print_rc=$?
  if (( print_rc == 0 )); then
    printf '%s\n' "${print_out}" | grep -E -A1 '^(type|name-alg|attributes):' | grep -v '^--' | sed 's/^/  /'
    attrs="$(printf '%s\n' "${print_out}" | awk '/^attributes:/{getline; print $2}')"
    report_expect "attributes include fixedtpm and fixedparent: the object cannot be duplicated out of this TPM" \
                  "${attrs:-(not parsed)}"
    if [[ "${attrs}" == *fixedtpm* && "${attrs}" == *fixedparent* ]]; then
      log_ok "the TPM itself refuses to duplicate this key — that is the hardware guarantee"
    else
      log_warn "fixedtpm/fixedparent not both present — check the key template the Vault CLI uses"
    fi
  else
    printf '%s\n' "${print_out}" | sed 's/^/  /'
    report_expect "a parsable TPM2B_PUBLIC" "tpm2_print exited ${print_rc}"
    log_warn "could not parse the public area — see the error above"
  fi
else
  log_warn "could not decode .Public from ${APP_BLOB}"
fi

# --- 4. the asymmetry: the public half is in the certificate -----------------
log_step "4. The public key IS available — it is in the certificate, and it matches"
cert_hash="$(as_lab_user openssl x509 -in "${CRT}" -pubkey -noout 2>/dev/null \
  | as_lab_user openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
json_hash="$(as_lab_user jq -r '.public_key_sha256 // empty' "${KEY_JSON}" 2>/dev/null || true)"
report_expect "client-key.json public_key_sha256 = sha256 of the certificate's public key" \
              "json ${json_hash:0:16}… / cert ${cert_hash:0:16}…"
if [[ -n "${json_hash}" && "${json_hash}" == "${cert_hash}" ]]; then
  log_ok "public out, private never — the certificate binds to a key only this TPM can use"
else
  log_warn "the hashes differ — the handle and the certificate may not describe the same key"
fi

# --- the attestation key, for completeness -----------------------------------
log_step "5. Same story for the attestation key (ak.blob)"
ak_fields="$(as_lab_user jq -r 'keys | join(", ")' "${AK_BLOB}" 2>/dev/null || printf '(unreadable)')"
log_detail "  fields: ${ak_fields}"
log_detail "  The AK is what certified the application key during 'vault tpm attest'. It is"
log_detail "  sealed to this TPM in exactly the same way, and it is only ever used inside it."

# --- close -------------------------------------------------------------------
log_info ''
log_info "Both blobs are ciphertext under this TPM's storage root key, so they are"
log_info "useless on any other machine: copying them buys an attacker nothing without"
log_info "the silicon that unwraps them. Part 8.1 proves exactly that by pointing the"
log_info "same files at a second TPM and watching the login fail."
