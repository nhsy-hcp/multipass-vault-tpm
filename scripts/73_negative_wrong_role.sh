#!/bin/bash
# Part 8.4: a genuine certificate from the trusted CA, for the wrong role.
#
# The subtlest of the negative tests and the most realistic. The certificate
# is real: same mount, same internal CA, issued after a real attestation. Only
# the TPM behind it is not one the 'devices' role trusts. It isolates the role
# binding as a control in its own right, independent of the chain-of-trust
# check that 8.3 covers — a compromised or over-permissive second role cannot
# mint identities for this one.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
ATT_STATE="${LAB_TPM_DIR}/attacker"
OTHER_NAME="node99"
OTHER_ROLE="other"
OTHER_CN="${OTHER_NAME}.other.lab.local"
NO_TOKEN="device-holds-no-token"

log_step "Part 8.4: a trusted-CA certificate bound to the wrong role"

[[ -S "${ATTACKER_TPM_SOCK}" ]] || die "no attacker TPM at ${ATTACKER_TPM_SOCK} — run 'task tpm' first"
require_cmd jq openssl || die "missing prerequisites"
lab_mkdir "${LAB_TPM_DIR}" "${ATT_STATE}"

log_info "The second TPM becomes a legitimate device of a different kind: the operator"
log_info "registers it as '${OTHER_NAME}' and gives it its own role, '${OTHER_ROLE}'."
log_info ""

# Operator work: registering a second, legitimate device. Root is appropriate.
flush_tpm_contexts "${ATTACKER_TPM_SOCK}"
ek_json="$(as_lab_user env "VAULT_TOKEN=${NO_TOKEN}" vault tpm ek -tpm-device-path="${ATTACKER_TPM_SOCK}" -format=json)"
att_id="$(printf '%s' "${ek_json}" | jq -r '.tpm_id // empty')"
[[ -n "${att_id}" ]] || die "could not read the attacker TPM's EK"
printf '%s' "${ek_json}" | jq -r '.tpm_ek_public_key' | write_lab_file "${ATT_STATE}/ek.pub"
printf '%s\n' "${att_id}" | write_lab_file "${ATT_STATE}/tpm_id"

as_lab_user vault write identity/tpm name="${OTHER_NAME}" tpm_ek_public_key=@"${ATT_STATE}/ek.pub" >/dev/null
as_lab_user vault write "auth/tpm/role/${OTHER_ROLE}" tpm_ids="${att_id}" token_policies=default token_ttl=5m >/dev/null
log_ok "registered ${OTHER_NAME} = ${att_id:0:20}…, trusted by role '${OTHER_ROLE}' only"

log_step "Attesting the second TPM against role '${OTHER_ROLE}' (a real attestation)"
attempt=0
while :; do
  attempt=$(( attempt + 1 ))
  flush_tpm_contexts "${ATTACKER_TPM_SOCK}"
  rc=0
  out="$(as_lab_user_allow_fail env "VAULT_TOKEN=${NO_TOKEN}" \
    vault tpm attest -role-name="${OTHER_ROLE}" \
      -tpm-device-path="${ATTACKER_TPM_SOCK}" -tpm-state-dir="${ATT_STATE}" \
      -cert-subject-CN="${OTHER_CN}" 2>&1)" || rc=$?
  if (( rc == 0 )); then break; fi
  if printf '%s' "${out}" | grep -qi 'rate limit' && (( attempt < 4 )); then
    log_detected "Vault's per-EK attestation rate limit" "waiting 12s before retrying"
    sleep 12
  else
    printf '%s\n' "${out}" >&2
    die "attestation for ${OTHER_NAME} failed (rc=${rc})"
  fi
done
log_ok "$(printf '%s\n' "${out}" | grep -m1 -v '^[[:space:]]*$')"

log_info ""
log_detail "$(as_lab_user openssl x509 -in "${ATT_STATE}/client.crt" -noout -subject -issuer | sed 's/^/  /')"
log_detail "$(as_lab_user openssl x509 -in "${ATT_STATE}/client.crt" -noout -ext subjectAltName | tail -n +2 | sed 's/^ */  SAN: /')"
log_detail "  The issuer is the trusted internal CA — this certificate is genuine."
log_detail "  Its SAN names TPM ${att_id:0:20}… and role '${OTHER_ROLE}', not 'devices'."
log_info ""

log_step "Presenting it to the 'devices' role"
out=''
rc=0
out="$(bash "${STAGE_DIR}/50_login.sh" "${OTHER_NAME}" --state-dir "${ATT_STATE}" \
  --tpm-device "${ATTACKER_TPM_SOCK}" --role devices --quiet-json 2>&1)" || rc=$?

if (( rc == 0 )); then
  log_error "a token WAS issued for ${OTHER_NAME} in the 'devices' role that ${DEVICE} belongs to"
  report_expect "login rejected: this TPM is not in the devices group" \
                "login SUCCEEDED — the role binding is not applied"
  exit 1
fi

report_expect "login rejected: this TPM is not in the devices group" \
              "login failed (rc=${rc})"
log_detail "$(printf '%s\n' "${out}" | grep -v '^[[:space:]]*$' | tail -3 | sed 's/^/    /')"

log_step "Control: the same certificate IS accepted by its own role"
rc=0
bash "${STAGE_DIR}/50_login.sh" "${OTHER_NAME}" --state-dir "${ATT_STATE}" \
  --tpm-device "${ATTACKER_TPM_SOCK}" --role "${OTHER_ROLE}" --no-save >/dev/null 2>&1 || rc=$?
if (( rc == 0 )); then
  report_expect "login to role '${OTHER_ROLE}' succeeds" "login succeeded — the certificate is genuine"
else
  report_expect "login to role '${OTHER_ROLE}' succeeds" "login failed (rc=${rc}) — unexpected"
fi

log_info ""
log_ok "Chaining to the trusted CA is necessary but not sufficient."
log_info "The certificate names the TPM that earned it and the role it was issued"
log_info "for, and login checks both against the role being asked for. One CA can"
log_info "serve many roles without any of them being able to impersonate another."
