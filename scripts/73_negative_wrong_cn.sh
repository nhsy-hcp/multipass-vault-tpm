#!/bin/bash
# Part 8.4: the wrong common name, even from the trusted CA.
#
# This is the subtlest of the negative tests and the most realistic. The
# certificate is genuine: same Vault, same root CA, properly signed. Only the
# common name is outside what the cert auth role accepts. It isolates
# `allowed_common_names` as a control in its own right, independent of the
# chain-of-trust check that 8.3 covers.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

ROGUE_KEY="${LAB_PKI_DIR}/rogue.tpmkey.pem"
OTHER_CSR="${LAB_PKI_DIR}/other.csr"
OTHER_CRT="${LAB_PKI_DIR}/other.crt"
OTHER_CN="node99.other.lab.local"

log_step "Part 8.4: a trusted-CA certificate with the wrong common name"

if [[ ! -f "${ROGUE_KEY}" ]]; then
  log_info "Generating a key in the TPM for the other-domain certificate..."
  as_lab_user openssl genpkey -provider tpm2 -provider default \
    -propquery '?provider=tpm2' \
    -algorithm EC -pkeyopt group:P-256 -out "${ROGUE_KEY}"
fi

log_info "Adding a second PKI role for a different domain..."
as_lab_user vault write pki/roles/other \
  allowed_domains=other.lab.local \
  allow_subdomains=true \
  client_flag=true \
  key_type=any \
  max_ttl=24h >/dev/null
log_ok "role pki/roles/other created"

log_info "Requesting a certificate for ${OTHER_CN} from the same root CA..."
as_lab_user openssl req -new -provider tpm2 -provider default \
  -propquery '?provider=tpm2' \
  -key "${ROGUE_KEY}" -subj "/CN=${OTHER_CN}" -out "${OTHER_CSR}"

as_lab_user bash -c \
  "vault write -field=certificate pki/sign/other csr=@'${OTHER_CSR}' common_name='${OTHER_CN}' ttl=1h > '${OTHER_CRT}'"

log_detail "$(as_lab_user openssl x509 -in "${OTHER_CRT}" -noout -subject -issuer)"
log_info ""
log_detail "The issuer is the trusted Lab Device Root CA — this certificate is genuine."
log_detail "Only the common name is outside the *.devices.lab.local pattern."
log_info ""

log_step "Attempting login with the wrong-domain certificate"
out=''
rc=0
out="$(bash "${STAGE_DIR}/50_login.sh" other --cert "${OTHER_CRT}" --key "${ROGUE_KEY}" --quiet-json 2>&1)" || rc=$?

if (( rc == 0 )); then
  log_error "a token WAS issued for ${OTHER_CN}"
  report_expect "login rejected by allowed_common_names" \
                "login SUCCEEDED — the common name constraint is not applied"
  exit 1
fi

report_expect "login rejected by allowed_common_names" \
              "login failed (rc=${rc})"
log_detail "$(printf '%s\n' "${out}" | tail -5 | sed 's/^/    /')"

log_info ""
log_ok "Chaining to the trusted CA is necessary but not sufficient."
log_info "A compromised or over-permissive PKI role cannot mint device identities:"
log_info "cert auth independently constrains which names it will accept."
