#!/bin/bash
# Part 8.2: a login with no client certificate is rejected.
#
# Vault's listener requests a client certificate but does not require one, so
# the TLS handshake completes and Vault answers with a JSON error rather than
# dropping the connection. That distinction is worth showing: the transport is
# fine, it is the auth method that refuses.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

log_step "Part 8.2: login with no client certificate"

log_info "Connecting over TLS but presenting no client certificate at all."
log_info ""

out=''
rc=0
out="$(bash "${STAGE_DIR}/50_login.sh" none --no-cert --quiet-json 2>&1)" || rc=$?

if (( rc == 0 )); then
  log_error "a token WAS issued without a client certificate"
  report_expect "login rejected: no client certificate supplied" \
                "login SUCCEEDED — cert auth is not enforcing anything"
  exit 1
fi

report_expect "login rejected: no client certificate supplied" \
              "login failed (rc=${rc})"
log_detail "$(printf '%s\n' "${out}" | tail -5 | sed 's/^/    /')"

log_info ""
log_ok "The TLS handshake succeeds; the cert auth method supplies the refusal."
log_info "There is no certificate to map to a trusted CA, so there is no identity"
log_info "to authenticate and no token to issue."
