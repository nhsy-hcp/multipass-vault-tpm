#!/bin/bash
# Part 8.1: stolen key blobs and certificate do not work on another machine.
#
# The lab runs a second swtpm permanently with its own storage seed. Switching
# machines is then just a different TPM socket: no restarts, no PID juggling,
# and both TPMs stay live so the contrast is visible side by side.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
STATE_DIR="${LAB_TPM_DIR}/${DEVICE}"
STOLEN_DIR="${LAB_TPM_DIR}/stolen"

log_step "Part 8.1: stolen key blobs against a different TPM"

[[ -s "${STATE_DIR}/client.crt" && -s "${STATE_DIR}/app.blob" ]] \
  || die "no attested state for ${DEVICE} at ${STATE_DIR}; run 'task enrol' first"
[[ -S "${ATTACKER_TPM_SOCK}" ]] || die "no attacker TPM at ${ATTACKER_TPM_SOCK} — run 'task tpm' first"

log_info "The attacker has copied the whole state directory off the device:"
log_detail "  client.crt        (the Vault-issued certificate)"
log_detail "  app.blob, ak.blob (the TPM-sealed key handles)"
log_detail "  client-key.json   (how the CLI finds them)"
log_info ""
log_info "They are now on a different machine — a TPM with a different storage"
log_info "seed, which the lab models as a second swtpm at ${ATTACKER_TPM_SOCK}."
log_info ""

rm -rf "${STOLEN_DIR}"
as_lab_user cp -a "${STATE_DIR}" "${STOLEN_DIR}"
log_ok "copied to ${STOLEN_DIR} — byte for byte the same files"

log_step "Attempting login with the copied files against the attacker TPM"
attacker_out=''
attacker_rc=0
attacker_out="$(bash "${STAGE_DIR}/50_login.sh" "${DEVICE}" \
  --state-dir "${STOLEN_DIR}" --tpm-device "${ATTACKER_TPM_SOCK}" --quiet-json 2>&1)" \
  || attacker_rc=$?

if (( attacker_rc == 0 )); then
  log_error "a token WAS issued — this must not happen"
  report_expect "login fails: the attacker TPM cannot load the key blob" \
                "login SUCCEEDED (rc=0)"
  log_error "the key may not be TPM-backed; check 'task demo:nonexportable'"
  exit 1
fi

report_expect "login fails: the attacker TPM cannot load the key blob" \
              "login failed (rc=${attacker_rc}) — no token issued"
log_detail "$(printf '%s\n' "${attacker_out}" | tail -4 | sed 's/^/    /')"
log_detail "  'integrity check failed' is the TPM speaking: the blob's private area is"
log_detail "  encrypted under a storage key this TPM does not have, and the HMAC over it"
log_detail "  does not verify. The login never reaches Vault."

log_step "Same files, same certificate, against the real device TPM"
device_rc=0
bash "${STAGE_DIR}/50_login.sh" "${DEVICE}" \
  --state-dir "${STOLEN_DIR}" --tpm-device "${TPM_SOCK}" >/dev/null 2>&1 || device_rc=$?

if (( device_rc == 0 )); then
  report_expect "login succeeds on the device's own TPM" \
                "login succeeded — token issued"
else
  log_error "the device TPM also failed (rc=${device_rc}); the lab is broken"
  log_error "check: journalctl -u swtpm@device --no-pager -n 50"
  exit 1
fi

log_info ""
log_ok "The key blobs are bound to the TPM that created them."
log_info "Copying the files achieves nothing: the private key never existed"
log_info "outside the TPM, so there is nothing to steal. The blob is ciphertext"
log_info "under a storage root key the attacker's TPM does not have."
