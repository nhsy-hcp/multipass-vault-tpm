#!/bin/bash
# Part 8.1: a stolen key file and certificate do not work on another machine.
#
# The guide simulates "another machine" by killing swtpm and restarting it on
# the same port against a fresh state directory. That is fiddly, loses the real
# TPM's state if anything goes wrong, and leaves the lab in a half-broken state
# if the script dies midway.
#
# Instead the lab runs a second swtpm permanently on its own port with its own
# storage seed. Switching machines is then just a different TCTI string: no
# restarts, no PID juggling, and both TPMs stay live so the contrast is visible
# side by side.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
ATTACKER_PORT="${2:-${ATTACKER_TPM_PORT}}"

log_step "Part 8.1: a stolen key blob against a different TPM"

[[ -f "${LAB_PKI_DIR}/${DEVICE}.tpmkey.pem" ]] \
  || die "no key for ${DEVICE}; run 'task enrol' first"

log_info "The attacker has copied both files off the device:"
log_detail "  ${DEVICE}.tpmkey.pem   (the TPM-wrapped key blob)"
log_detail "  ${DEVICE}.crt          (the Vault-issued certificate)"
log_info ""
log_info "They are now on a different machine — a TPM with a different storage"
log_info "seed, which the lab models as a second swtpm on port ${ATTACKER_PORT}."
log_info ""

log_step "Attempting login against the attacker TPM (port ${ATTACKER_PORT})"
attacker_out=''
attacker_rc=0
attacker_out="$(bash "${STAGE_DIR}/50_login.sh" "${DEVICE}" --tpm-port "${ATTACKER_PORT}" --quiet-json 2>&1)" \
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
log_detail "$(printf '%s\n' "${attacker_out}" | tail -5 | sed 's/^/    /')"

log_step "Same files, same certificate, against the real device TPM (port ${TPM_PORT})"
device_rc=0
bash "${STAGE_DIR}/50_login.sh" "${DEVICE}" --tpm-port "${TPM_PORT}" >/dev/null 2>&1 || device_rc=$?

if (( device_rc == 0 )); then
  report_expect "login succeeds on the device's own TPM" \
                "login succeeded — token issued"
else
  log_error "the device TPM also failed (rc=${device_rc}); the lab is broken"
  log_error "check: journalctl -u swtpm@device --no-pager -n 50"
  exit 1
fi

log_info ""
log_ok "The key blob is bound to the TPM that created it."
log_info "Copying the files achieves nothing: the private key never existed"
log_info "outside the TPM, so there is nothing to steal. The blob is ciphertext"
log_info "under a storage root key the attacker's TPM does not have."
