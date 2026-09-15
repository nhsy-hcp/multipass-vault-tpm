#!/bin/bash
# Non-exportability proof: the file on disk is a TPM-wrapped blob, not a key.
# This sits between Part 6 (enrolment) and Part 7 (login) and is the claim the
# rest of the lab rests on — the written guide asserts it but never shows it.
# Failure of the middle check is the success condition, so nothing here aborts
# the script on a non-zero exit; each check reports expected vs actual instead.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
KEY="${LAB_PKI_DIR}/${DEVICE}.tpmkey.pem"
TSS2_HEADER="-----BEGIN TSS2 PRIVATE KEY-----"

log_step "Proof: the private key cannot leave the TPM (${DEVICE})"

[[ -f "${LAB_DIR}/env.sh" ]] || die "no ${LAB_DIR}/env.sh — run 'task provision' first"
[[ -f "${KEY}" ]] || die "no key at ${KEY} — run 'task enrol' first"

# --- 1. what the file claims to be ------------------------------------------
log_step "1. The PEM header"
header="$(head -1 "${KEY}")"
report_expect "${TSS2_HEADER}" "${header}"
if [[ "${header}" == "${TSS2_HEADER}" ]]; then
  log_ok "not 'BEGIN PRIVATE KEY' — there is no private key in this file"
else
  log_error "this file is NOT a TPM key blob; everything below is meaningless"
fi

# --- 2. the negative: read it without the TPM provider ----------------------
log_step "2. Read the key WITHOUT the tpm2 provider — this must fail"
log_detail "openssl pkey -in ${KEY} -noout -text"
rc=0
out="$(as_lab_user_allow_fail openssl pkey -in "${KEY}" -noout -text 2>&1)" || rc=$?
first_line="$(printf '%s' "${out}" | head -1)"
report_expect "failure: the default provider cannot decode a TSS2 blob" \
  "exit ${rc}${first_line:+ — ${first_line}}"
if (( rc != 0 )); then
  log_ok "refused — without the TPM there is nothing here to load"
else
  log_error "the key was readable without the TPM provider — it is NOT TPM-backed"
fi

# --- 3. what the bytes actually are -----------------------------------------
log_step "3. The ASN.1 structure: a wrapped TPM object, not key material"
asn_rc=0
asn_out="$(as_lab_user_allow_fail openssl asn1parse -in "${KEY}" 2>&1)" || asn_rc=$?
if (( asn_rc == 0 )); then
  printf '%s\n' "${asn_out}" | sed 's/^/  /'
  # grep -c exits 1 on no match; the count is what matters, not the status.
  octets="$(printf '%s\n' "${asn_out}" | grep -c 'OCTET STRING' || true)"
  report_expect "an OID plus opaque OCTET STRINGs (the TPM public area and the sealed private area)" \
    "${octets} OCTET STRING(s), no EC private key field"
  log_ok "the octet strings are ciphertext — only this TPM holds the key that unwraps them"
else
  printf '%s\n' "${asn_out}" | sed 's/^/  /'
  report_expect "a parsable ASN.1 wrapper" "asn1parse exited ${asn_rc}"
  log_warn "could not parse the blob — see the error above"
fi

# --- 4. the asymmetry: the public half does come out ------------------------
log_step "4. The public key IS extractable — the asymmetry is the point"
pub_rc=0
pub_out="$(as_lab_user_allow_fail openssl pkey -provider tpm2 -provider default \
  -in "${KEY}" -pubout 2>&1)" || pub_rc=$?
if (( pub_rc == 0 )); then
  printf '%s\n' "${pub_out}" | sed 's/^/  /'
  report_expect "a PUBLIC KEY PEM" "$(printf '%s' "${pub_out}" | head -1)"
  log_ok "public out, private never — which is exactly what a CSR needs"
else
  report_expect "a PUBLIC KEY PEM" "openssl exited ${pub_rc}: $(printf '%s' "${pub_out}" | head -1)"
  log_error "could not extract the public key — is swtpm running? ('task logs:tpm')"
fi

# --- close -------------------------------------------------------------------
log_info ''
log_info "This blob is encrypted to this TPM's storage root key, so it is useless on"
log_info "any other machine: copying it buys an attacker nothing without the silicon"
log_info "that unwraps it. Part 8.1 proves exactly that by pointing the same file at"
log_info "a second TPM and watching the login fail."
