#!/bin/bash
# Part 8.2: a TPM Vault has never heard of cannot even begin attestation.
#
# This is the enrolment gate. Attestation needs no Vault token — possession
# of a registered endorsement key is the credential — so the obvious question
# is what stops any TPM in the world from asking for a certificate. The
# answer is the registry: Vault looks the EK up before it will issue a
# challenge, and an unknown EK is refused at the first step.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
DOMAIN="${2:-devices.lab.local}"
ATT_STATE="${TPM_DIR}/attacker"

log_step "Part 8.2: an unregistered TPM is refused at attestation"

[[ -S "${ATTACKER_TPM_SOCK}" ]] || die "no attacker TPM at ${ATTACKER_TPM_SOCK} — run 'task tpm' first"
require_cmd jq || die "missing prerequisites"
lab_mkdir "${TPM_DIR}" "${ATT_STATE}"

log_info "The attacker owns a perfectly good TPM — the second swtpm — and asks Vault"
log_info "for a certificate in the '${DEVICE}' role, exactly as the device did in Part 6."
log_info ""

flush_tpm_contexts "${ATTACKER_TPM_SOCK}"
att_id="$(as_lab_user env "VAULT_TOKEN=${NO_TOKEN}" \
  vault tpm ek -tpm-device-path="${ATTACKER_TPM_SOCK}" -format=json | jq -r '.tpm_id // empty')"
[[ -n "${att_id}" ]] || die "could not read the attacker TPM's EK"
log_detail "  attacker TPM ID: ${att_id}"

# 8.4 registers this TPM as a legitimate second device. Undo that here so the
# precondition — Vault has never seen this EK — holds on every run.
if as_lab_user vault read "identity/tpm/id/${att_id}" >/dev/null 2>&1; then
  log_detected "the attacker TPM registered from an earlier 8.4 run" "deleting the registration as the operator"
  as_lab_user vault delete "identity/tpm/id/${att_id}" >/dev/null
fi
rc=0
as_lab_user_allow_fail vault read "identity/tpm/id/${att_id}" >/dev/null 2>&1 || rc=$?
if (( rc == 0 )); then
  reg_state="FOUND"
else
  reg_state="not found (vault exit ${rc})"
fi
report_expect "identity/tpm/id/${att_id:0:20}…: not found" "${reg_state}"

log_step "Attempting attestation from the unregistered TPM (no token, as in Part 6)"
log_detail "  vault tpm attest -role-name=devices -tpm-device-path=${ATTACKER_TPM_SOCK}"
rc=0
out="$(tpm_attest "${ATTACKER_TPM_SOCK}" "${ATT_STATE}" devices "${DEVICE}.${DOMAIN}")" || rc=$?

if (( rc == 0 )); then
  log_error "a certificate WAS issued to an unregistered TPM"
  report_expect "attestation refused at gentpmcert/begin: no TPM found for EK public key" \
                "attestation SUCCEEDED — the registry is not gating anything"
  exit 1
fi

report_expect "attestation refused at gentpmcert/begin: no TPM found for EK public key" \
              "attestation failed (rc=${rc})"
log_detail "$(printf '%s\n' "${out}" | grep -v '^[[:space:]]*$' | tail -3 | sed 's/^/    /')"

log_info ""
log_ok "No token was needed — and none would have helped."
log_info "Attestation is open to anyone, but Vault answers only for endorsement keys"
log_info "an orchestrator has registered. The identity is the silicon, and the"
log_info "operator decides which silicon counts."
