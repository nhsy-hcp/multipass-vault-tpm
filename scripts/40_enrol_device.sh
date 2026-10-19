#!/bin/bash
# Part 6: register the device's TPM with Vault and attest it for a certificate.
# The key material is created by the lab user because that same user must be
# able to use it later — a TPM key blob is bound to the TPM, and the files that
# reference it have to be readable by whoever performs the login.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
DOMAIN="${2:-devices.lab.local}"
CN="${DEVICE}.${DOMAIN}"

# Everything `vault tpm attest` produces lives in one state directory per
# device: the certificate, the CA chain, and the two TPM key blobs.
DEVICE_DIR="${TPM_DIR}/${DEVICE}"
EK_PUB="${DEVICE_DIR}/ek.pub"
TPM_ID_FILE="${DEVICE_DIR}/tpm_id"
CRT="${DEVICE_DIR}/client.crt"
SENTINEL="${STATE_DIR}/config.json"

# The orchestrator's credential, created by 'task config' (Part 5.5). Its
# policy grants exactly two things: register an EK, and admit a TPM to the
# 'devices' group. It cannot touch the auth role.
ORCH_TOKEN_FILE="${STATE_DIR}/orchestrator.token"

# Device-side calls run with NO_TOKEN (see common.sh): the attestation
# endpoints are unauthenticated, and the placeholder keeps root off the wire.

log_step "Part 6: enrol the device TPM with Vault (${CN})"

require_cmd jq install openssl || die "missing tooling — run 'task provision' first"
[[ -f "${VM_DIR}/env.sh" ]] || die "no ${VM_DIR}/env.sh — run 'task provision' first"
[[ -f "${SENTINEL}" ]] || die "no ${SENTINEL} — run 'task config' first (Parts 4-5)"
[[ -S "${TPM_SOCK}" ]] || die "no TPM socket at ${TPM_SOCK} — run 'task tpm' first"

TPM_MOUNT="$(jq -r '.tpm_auth_mount // "auth/tpm"' "${SENTINEL}")"
TPM_GROUP="$(jq -r '.tpm_group // "devices"' "${SENTINEL}")"
TPM_ROLE="$(jq -r '.tpm_role // "auth/tpm/role/devices"' "${SENTINEL}")"
ROLE_NAME="${TPM_ROLE##*/}"

lab_mkdir "${TPM_DIR}" "${DEVICE_DIR}"

wait_for "Vault to be unsealed" 60 as_lab_user vault status \
  || die "Vault is not responding — check 'task logs:vault'"

# Vault's stderr is captured separately from its stdout throughout, so a stray
# warning can never end up inside a captured JSON payload.
ERR_LOG="$(mktemp)"
trap 'rm -f "${ERR_LOG}"' EXIT
vault_error() { grep -m1 -v '^[[:space:]]*$' "${ERR_LOG}" || printf '(no error output)'; }

redact() {
  local v="${1:-}"
  if (( ${#v} > 8 )); then printf '%s...' "${v:0:8}"; else printf '(%d chars)' "${#v}"; fi
}

# The flow is deliberately two-sided, and the output labels each side, because
# the separation IS the point:
#
#   operator     (root)         : configure trust                 <- task config
#   orchestrator (scoped token) : register the EK, admit the TPM  <- 6.2
#   device       (NO token)     : prove it holds that EK, get a certificate
#
# Nothing on the device side holds any Vault credential. What the device
# presents is its endorsement key — burned into the TPM at manufacture and
# never leaving it — and the attestation protocol proves possession of it.
#
# Mechanics: as_lab_user runs `bash -lc "source ${VM_DIR}/env.sh; <cmd>"`, and
# env.sh exports VAULT_TOKEN=root, so no call below can simply be given a
# different token — the source would overwrite it. Each one therefore uses
# `env VAULT_TOKEN=<token> vault ...`, which the shell executes *after* the
# source has run. Same idiom as scripts/60_privilege.sh.

# --- 6.1 device: the endorsement key ----------------------------------------
log_step "6.1 (DEVICE, no token): read the endorsement key from the TPM"
log_detail "  The EK is created from a seed burned into the TPM at manufacture. Its"
log_detail "  private half never leaves the chip; the public half is the device's identity."

flush_tpm_contexts
rc=0
show_cmd env "VAULT_TOKEN=${NO_TOKEN}" vault tpm ek -tpm-device-path="${TPM_SOCK}" -format=json
ek_json="$(as_lab_user_allow_fail env "VAULT_TOKEN=${NO_TOKEN}" \
  vault tpm ek -tpm-device-path="${TPM_SOCK}" -format=json 2>"${ERR_LOG}")" || rc=$?
(( rc == 0 )) || die "could not read the EK (vault exit ${rc}): $(vault_error) — is swtpm@device running? ('task logs:tpm')"

ek_pem="$(printf '%s' "${ek_json}" | jq -r '.tpm_ek_public_key // empty')"
tpm_id="$(printf '%s' "${ek_json}" | jq -r '.tpm_id // empty')"
[[ -n "${ek_pem}" && -n "${tpm_id}" ]] || die "vault tpm ek returned no EK / TPM ID"

printf '%s\n' "${ek_pem}" | write_lab_file "${EK_PUB}"
printf '%s\n' "${tpm_id}" | write_lab_file "${TPM_ID_FILE}"
log_ok "EK public key at ${EK_PUB}; TPM ID ${tpm_id}"

# The TPM ID is nothing more than the SHA-256 of the EK public key's DER
# encoding. Recomputing it locally shows there is no hidden registry value.
rc=0
computed="$(as_lab_user_allow_fail openssl pkey -pubin -in "${EK_PUB}" -outform DER 2>/dev/null \
  | sha256sum | cut -d' ' -f1)" || rc=$?
(( rc == 0 )) || die "could not compute the SHA-256 of ${EK_PUB} (openssl exit ${rc}) — is it a valid public key?"
report_expect "sha256-${computed} (sha256 of the EK public key, computed locally)" "${tpm_id}"
[[ "${tpm_id}" == "sha256-${computed}" ]] || log_warn "the TPM ID is not the SHA-256 of the PEM's DER — check how this build derives it"

# --- 6.2 orchestrator: register the EK and admit it to the group -------------
log_step "6.2 (ORCHESTRATOR, scoped token): register the EK, admit the TPM to '${TPM_GROUP}'"

# This script runs as root inside the VM, so it can read the lab user's 0600
# credential file directly. What matters is which token goes on the wire below,
# and it is not the root one.
[[ -s "${ORCH_TOKEN_FILE}" ]] \
  || die "no orchestrator token at ${ORCH_TOKEN_FILE} — run 'task config' first (Part 5.5 mints it)"
orch_token="$(<"${ORCH_TOKEN_FILE}")"
[[ -n "${orch_token}" ]] || die "${ORCH_TOKEN_FILE} is empty — re-run 'task config'"
log_detail "orchestrator token $(redact "${orch_token}") — policy 'enrol-orchestrator', two paths, nothing else"

# Run a vault command with the orchestrator's token, showing it as
# VAULT_TOKEN=<orchestrator>: which of the three identities is on the wire is
# the whole point of 6.2, and naming it says more than a redaction would.
# Same shape as vault_as_device in scripts/60_privilege.sh.
as_orchestrator() {
  show_cmd env 'VAULT_TOKEN=<orchestrator>' "$@"
  as_lab_user_allow_fail env "VAULT_TOKEN=${orch_token}" "$@"
}

log_info "Registering the EK as '${DEVICE}' in identity/tpm"
rc=0
reg_json="$(as_orchestrator \
  vault write -format=json identity/tpm \
  name="${DEVICE}" tpm_ek_public_key=@"${EK_PUB}" metadata="domain=${DOMAIN}" 2>"${ERR_LOG}")" || rc=$?
(( rc == 0 )) || die "could not register the EK as the orchestrator (vault exit ${rc}): $(vault_error)"
reg_id="$(printf '%s' "${reg_json}" | jq -r '.data.id // empty')"
[[ "${reg_id}" == "${tpm_id}" ]] \
  || die "Vault registered the EK as ${reg_id:-(none)}, but the CLI computed ${tpm_id}"
log_ok "identity/tpm/name/${DEVICE} = ${reg_id} (an upsert: re-running changes nothing)"

log_info "Admitting ${tpm_id} to TPM group '${TPM_GROUP}'"
rc=0
group_json="$(as_orchestrator \
  vault read -format=json "identity/tpmgroup/name/${TPM_GROUP}" 2>"${ERR_LOG}")" || rc=$?
(( rc == 0 )) || die "could not read group '${TPM_GROUP}' as the orchestrator (vault exit ${rc}): $(vault_error) — run 'task config' first"
members="$(printf '%s' "${group_json}" | jq -r '.data.member_tpm_ids // [] | join(",")')"
if [[ ",${members}," == *",${tpm_id},"* ]]; then
  log_detected "${tpm_id} already in '${TPM_GROUP}'" "skipping the group update"
else
  # A group write replaces the member list, so it is read-modify-write.
  new_members="${members:+${members},}${tpm_id}"
  rc=0
  as_orchestrator \
    vault write "identity/tpmgroup/name/${TPM_GROUP}" member_tpm_ids="${new_members}" >/dev/null 2>"${ERR_LOG}" || rc=$?
  (( rc == 0 )) || die "could not admit the TPM to '${TPM_GROUP}' (vault exit ${rc}): $(vault_error)"
  log_ok "group '${TPM_GROUP}' now trusts ${tpm_id}"
fi

# The scope of that token, demonstrated. Failure is the expected outcome, so
# the calls tolerate it and the script reports rather than aborts.
#
# Three outcomes, not two. A denial is the point; a *different* failure — Vault
# unreachable, the path gone after a dev-server restart — is not evidence about
# the policy either way, and must not be reported as one. Only a call that
# actually succeeds means the policy is wider than intended.
expect_denied() {
  local what="$1" wider="$2"; shift 2
  local rc=0 out first
  out="$(as_orchestrator "$@" 2>&1)" || rc=$?
  first="$(printf '%s\n' "${out}" | grep -m1 -v '^[[:space:]]*$' || true)"

  if (( rc == 0 )); then
    report_expect "${what}: permission denied" "SUCCEEDED — the call was allowed"
    log_warn "${wider}"
  elif printf '%s' "${out}" | grep -qiE 'permission denied|Code: 403'; then
    report_expect "${what}: permission denied" "permission denied (vault exit ${rc})"
  else
    report_expect "${what}: permission denied" \
      "failed for another reason (vault exit ${rc}): ${first}"
    log_warn "that is not a denial — check Vault is up before reading anything into it"
  fi
}

log_info "What the orchestrator cannot do:"
expect_denied "read ${TPM_ROLE}" \
  "the orchestrator can see the auth role — its policy is wider than intended" \
  vault read "${TPM_ROLE}"
expect_denied "read the device secret" \
  "the orchestrator can read secrets — its policy is wider than intended" \
  vault kv get "secret/devices/${DEVICE}"

# --- 6.3 device: attest -------------------------------------------------------
log_step "6.3 (DEVICE, no token): attest — prove possession of the EK, get a certificate"

# Re-runs must not re-attest for no reason: Vault rate-limits attestation per
# EK (about ten seconds), and a fresh certificate every run would hide the
# fact that the device holds a durable identity. Keep a certificate that is
# still good for an hour and belongs to this TPM and role.
cert_current() {
  [[ -s "${CRT}" ]] || return 1
  as_lab_user openssl x509 -in "${CRT}" -noout -checkend 3600 >/dev/null 2>&1 || return 1
  local san
  san="$(as_lab_user openssl x509 -in "${CRT}" -noout -ext subjectAltName 2>/dev/null | tr -d '\n')"
  [[ "${san}" == *"${tpm_id}"* && "${san}" == *"::${ROLE_NAME}"* ]]
}

if cert_current; then
  log_detected "a valid certificate for ${tpm_id} / role ${ROLE_NAME} in ${DEVICE_DIR}" "skipping attestation (delete ${DEVICE_DIR} or run 'task reset' to force it)"
else
  log_detail "  1. begin:  the device sends its EK public key and a fresh attestation key (AK);"
  log_detail "             Vault looks the EK up, checks the role trusts it, and returns a"
  log_detail "             secret encrypted so that only that EK can unwrap it — bound to the AK."
  log_detail "  2. TPM2_ActivateCredential: the TPM decrypts the secret, and will only do so if"
  log_detail "             the AK really lives in the same TPM as the EK."
  log_detail "  3. finish: the device returns the secret, a CSR for a new application key, and"
  log_detail "             the AK's certification of that key; Vault issues the certificate."
  log_detail "  No Vault token is involved: the EK is the credential."

  rc=0
  attest_out="$(tpm_attest "${TPM_SOCK}" "${DEVICE_DIR}" "${ROLE_NAME}" "${CN}" "${TPM_MOUNT#auth/}")" || rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "${attest_out}" >&2
    die "attestation failed (vault exit ${rc}) — see Vault's message above"
  fi
  log_ok "$(printf '%s\n' "${attest_out}" | grep -m1 -v '^[[:space:]]*$')"
fi

# --- 6.4 what is on disk now -------------------------------------------------
log_step "6.4: what the device holds now"
ls -la "${DEVICE_DIR}" | sed 's/^/  /'
log_detail "  client.crt / ca_chain.pem  the certificate and the mount's CA"
log_detail "  app.blob                   the application key: public area + private area sealed to this TPM"
log_detail "  ak.blob                    the attestation key that certified the application key"
log_detail "  client-key.json            how the Vault CLI finds the two blobs at login"
log_detail "  ek.pub / tpm_id            what the orchestrator registered (public; not secrets)"

# --- verify ------------------------------------------------------------------
log_step "Verify: the issued device certificate"
as_lab_user openssl x509 -in "${CRT}" -noout -subject -issuer -dates -ext subjectAltName,extendedKeyUsage

subject="$(as_lab_user openssl x509 -in "${CRT}" -noout -subject)"
issuer="$(as_lab_user openssl x509 -in "${CRT}" -noout -issuer)"
san="$(as_lab_user openssl x509 -in "${CRT}" -noout -ext subjectAltName | tr -d '\n')"
eku="$(as_lab_user openssl x509 -in "${CRT}" -noout -ext extendedKeyUsage | tr -d '\n')"

log_info ''
report_expect "subject CN=${CN} (what the device asked for — self-asserted, not an enforced identity)" "${subject}"
report_expect "issuer CN=Vault TPM Auth Internal CA (the mount's own CA)" "${issuer}"
# The SAN carries two OtherNames under HashiCorp's arc: …55813.1.1.1 is the
# TPM ID and …55813.1.1.2 is the role name.
san_tpm="$(printf '%s' "${san}" | grep -o '55813\.1\.1\.1::[^, ]*' | sed 's/.*:://' || true)"
san_role="$(printf '%s' "${san}" | grep -o '55813\.1\.1\.2::[^, ]*' | sed 's/.*:://' || true)"
report_expect "SAN carries the TPM ID ${tpm_id}" "${san_tpm:-(no TPM ID in SAN)}"
report_expect "SAN carries the role name ${ROLE_NAME}" "${san_role:-(no role in SAN)}"
report_expect "EKU TLS Web Client Authentication" "${eku}"

fail=0
[[ "${subject}" == *"CN = ${CN}"* || "${subject}" == *"CN=${CN}"* ]] \
  || { log_error "subject common name does not match ${CN}"; fail=1; }
[[ "${issuer}" == *"Vault TPM Auth Internal CA"* ]] \
  || { log_error "certificate was not issued by the tpm auth mount's CA"; fail=1; }
[[ "${san}" == *"${tpm_id}"* ]] \
  || { log_error "certificate does not carry this TPM's ID"; fail=1; }
[[ "${eku}" == *"TLS Web Client Authentication"* ]] \
  || { log_error "certificate is not marked for client authentication"; fail=1; }
(( fail == 0 )) || die "the issued certificate does not match the '${ROLE_NAME}' role"

log_info ''
log_detail "Two of those fields are identities Vault enforces at login: the TPM ID and the"
log_detail "role, both in the SAN. The common name is whatever -cert-subject-CN said, and"
log_detail "nothing checks it — do not build policy on it. The TPM ID is the device."

log_info ''
log_info "vault tpm inspect:"
as_lab_user vault tpm inspect -tpm-state-dir="${DEVICE_DIR}" | sed 's/^/  /'

log_ok "Part 6 complete — ${DEVICE} is enrolled"
log_info ''
log_info "Next: task demo — starting with the non-exportability proof."
