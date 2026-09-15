#!/bin/bash
# Part 8.3: a certificate from an untrusted CA is rejected.
#
# The rogue key is generated in the *same* TPM as the real device key. That is
# the point: possession of a TPM-held key proves nothing on its own. Vault
# trusts a CA, not a TPM, so a self-signed certificate — however well its key is
# protected — has no path to the device CA and is refused.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DOMAIN="${1:-devices.lab.local}"
ROGUE_KEY="${LAB_PKI_DIR}/rogue.tpmkey.pem"
ROGUE_CRT="${LAB_PKI_DIR}/rogue.crt"

log_step "Part 8.3: a certificate from an untrusted CA"

if [[ -f "${ROGUE_KEY}" ]] && head -1 "${ROGUE_KEY}" | grep -q 'TSS2 PRIVATE KEY'; then
  log_detected "an existing rogue TPM key" "reusing it"
else
  log_info "Generating a rogue key inside the same TPM..."
  as_lab_user openssl genpkey -provider tpm2 -provider default \
    -propquery '?provider=tpm2' \
    -algorithm EC -pkeyopt group:P-256 -out "${ROGUE_KEY}"
  log_ok "rogue key created in the TPM"
fi

log_info "Self-signing a certificate for rogue.${DOMAIN} — no CA involved..."
as_lab_user openssl req -new -x509 -days 1 \
  -provider tpm2 -provider default -propquery '?provider=tpm2' \
  -key "${ROGUE_KEY}" -subj "/CN=rogue.${DOMAIN}" -out "${ROGUE_CRT}"

log_detail "$(as_lab_user openssl x509 -in "${ROGUE_CRT}" -noout -subject -issuer)"
log_info ""
log_detail "Note the subject and issuer are identical — it is self-signed."
log_info ""

log_step "Attempting login with the rogue certificate"
out=''
rc=0
out="$(bash "${STAGE_DIR}/50_login.sh" rogue --cert "${ROGUE_CRT}" --key "${ROGUE_KEY}" --quiet-json 2>&1)" || rc=$?

if (( rc == 0 )); then
  log_error "a token WAS issued for an untrusted certificate"
  report_expect "login rejected: certificate does not chain to the device CA" \
                "login SUCCEEDED — the trust anchor is not being enforced"
  exit 1
fi

report_expect "login rejected: certificate does not chain to the device CA" \
              "login failed (rc=${rc})"
log_detail "$(printf '%s\n' "${out}" | tail -5 | sed 's/^/    /')"

log_info ""
log_ok "A key in a TPM is not enough."
log_info "Vault's trust anchor is the device CA it was configured with. Hardware"
log_info "protection secures the key; the CA decides whose key counts."
