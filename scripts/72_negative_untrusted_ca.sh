#!/bin/bash
# Part 8.3: a genuine TPM certificate from a different CA is rejected.
#
# The rogue certificate is earned by the *same* TPM, with the *same* EK, by a
# real attestation — against a second tpm auth mount, which has its own
# internal CA. That is the point: hardware-backed and honestly attested is not
# the same as issued by the CA this mount trusts. Vault trusts its own CA, not
# a TPM, so the login is refused however good the key is.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
DOMAIN="${2:-devices.lab.local}"
CN="${DEVICE}.${DOMAIN}"
DEVICE_DIR="${TPM_DIR}/${DEVICE}"
ROGUE_MOUNT="tpm-rogue"
ROGUE_STATE="${TPM_DIR}/rogue"

log_step "Part 8.3: a certificate from a CA this mount does not trust"

[[ -s "${DEVICE_DIR}/tpm_id" ]] || die "no enrolment for ${DEVICE} at ${DEVICE_DIR}; run 'task enrol' first"
[[ -S "${TPM_SOCK}" ]] || die "no TPM socket at ${TPM_SOCK} — run 'task tpm' first"
require_cmd jq openssl || die "missing prerequisites"
tpm_id="$(<"${DEVICE_DIR}/tpm_id")"
lab_mkdir "${TPM_DIR}" "${ROGUE_STATE}"

# auth/tpm-rogue exists only to be a second CA for the length of this script.
# Left enabled it shows up in `vault auth list` for the rest of the demo, as a
# tpm mount nobody configured, so it goes when the script does — on the way
# out of a successful run and an aborted one alike.
cleanup_rogue_mount() {
  mount_enabled auth "${ROGUE_MOUNT}/" || return 0
  log_info ""
  log_detected "the ${ROGUE_MOUNT} stand-in mount still enabled" "disabling it so the demo leaves no trace"
  vault_run_allow_fail vault auth disable "${ROGUE_MOUNT}" >/dev/null 2>&1 \
    || log_warn "could not disable auth/${ROGUE_MOUNT} — remove it by hand"
}
trap cleanup_rogue_mount EXIT

log_info "A second tpm auth mount stands in for an unrelated CA. Same Vault, same"
log_info "TPM, same registered EK — but a different mount, so a different internal CA."
log_info ""

# Operator work, so root is appropriate: this is a stand-in for a second,
# unrelated certificate authority that happens to also trust this TPM.
if mount_enabled auth "${ROGUE_MOUNT}/"; then
  log_detected "the ${ROGUE_MOUNT} mount already enabled" "reusing it"
else
  vault_run vault auth enable -path="${ROGUE_MOUNT}" tpm >/dev/null
  log_ok "enabled auth/${ROGUE_MOUNT} — it generated its own CA on the spot"
fi
vault_run vault write "auth/${ROGUE_MOUNT}/config" default_cert_ttl=1h >/dev/null
vault_run vault write "auth/${ROGUE_MOUNT}/role/devices" tpm_ids="${tpm_id}" token_policies=default >/dev/null
log_ok "auth/${ROGUE_MOUNT}/role/devices trusts ${tpm_id:0:20}…"

log_step "Attesting the device TPM against auth/${ROGUE_MOUNT} (a real attestation)"
rc=0
out="$(tpm_attest "${TPM_SOCK}" "${ROGUE_STATE}" devices "${CN}" "${ROGUE_MOUNT}")" || rc=$?
if (( rc != 0 )); then
  printf '%s\n' "${out}" >&2
  die "attestation against ${ROGUE_MOUNT} failed (rc=${rc}) — the demo needs a rogue-CA certificate to present"
fi
log_ok "$(printf '%s\n' "${out}" | grep -m1 -v '^[[:space:]]*$')"

log_info ""
log_detail "  rogue cert issuer:  $(as_lab_user openssl x509 -in "${ROGUE_STATE}/client.crt" -noout -issuer | sed 's/^issuer=//')"
log_detail "  rogue CA serial:    $(as_lab_user openssl x509 -in "${ROGUE_STATE}/ca_chain.pem" -noout -serial | sed 's/^serial=//')"
log_detail "  trusted CA serial:  $(as_lab_user openssl x509 -in "${DEVICE_DIR}/ca_chain.pem" -noout -serial | sed 's/^serial=//')"
log_detail "  Same issuer name, different CA key: the names match, the chain does not."
log_info ""

log_step "Presenting the rogue-CA certificate to auth/tpm"
out=''
rc=0
out="$(bash "${STAGE_DIR}/50_login.sh" "${DEVICE}" --state-dir "${ROGUE_STATE}" --quiet-json 2>&1)" || rc=$?

if (( rc == 0 )); then
  log_error "a token WAS issued for a certificate from another CA"
  report_expect "login rejected: certificate does not chain to this mount's CA" \
                "login SUCCEEDED — the trust anchor is not being enforced"
  exit 1
fi

report_expect "login rejected: certificate does not chain to this mount's CA" \
              "login failed (rc=${rc})"
log_detail "$(printf '%s\n' "${out}" | grep -v '^[[:space:]]*$' | tail -3 | sed 's/^/    /')"

log_step "Control: the same certificate IS accepted by the mount that issued it"
rc=0
bash "${STAGE_DIR}/50_login.sh" "${DEVICE}" --state-dir "${ROGUE_STATE}" \
  --mount "${ROGUE_MOUNT}" --no-save >/dev/null 2>&1 || rc=$?
if (( rc == 0 )); then
  report_expect "login to auth/${ROGUE_MOUNT} succeeds" "login succeeded — the certificate is genuine"
else
  report_expect "login to auth/${ROGUE_MOUNT} succeeds" "login failed (rc=${rc}) — unexpected; the rogue mount may be misconfigured"
fi

log_info ""
log_ok "A key in a TPM, honestly attested, is still not enough."
log_info "Each tpm auth mount trusts only the certificates it issued itself. Hardware"
log_info "protection secures the key; the CA decides whose key counts."
