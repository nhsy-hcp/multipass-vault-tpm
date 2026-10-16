#!/bin/bash
# Part 8.5: a revoked device token can no longer read.
#
# The guide reads $DEVICE_TOKEN from a variable set in an earlier shell, which
# does not survive between `multipass exec` invocations. The token is read from
# the login sentinel file instead.
#
# Note this demonstrates *revocation*, not expiry. The token's 15m TTL means it
# would lapse on its own; revoking makes the same point immediately and without
# a wait, and shows an operator can cut a device off on demand.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DEVICE="${1:-node01}"
LOGIN_JSON="${STATE_DIR}/login.json"

log_step "Part 8.5: revoking the device token"

[[ -f "${LOGIN_JSON}" ]] \
  || die "no login on record; run 'task demo:login' first"

TOKEN="$(as_lab_user jq -r '.auth.client_token' "${LOGIN_JSON}")"
[[ -n "${TOKEN}" && "${TOKEN}" != "null" ]] \
  || die "could not read a client token from ${LOGIN_JSON}"

log_info "Confirming the token currently works..."
before_rc=0
show_cmd env 'VAULT_TOKEN=<device>' vault kv get -field=message "secret/devices/${DEVICE}"
as_lab_user env VAULT_TOKEN="${TOKEN}" vault kv get -field=message "secret/devices/${DEVICE}" >/dev/null 2>&1 \
  || before_rc=$?

if (( before_rc != 0 )); then
  log_warn "the token could not read before revocation (rc=${before_rc})"
  log_warn "it may have already expired — its TTL is 15m. Re-run 'task demo:login'."
  exit 1
fi
report_expect "read succeeds before revocation" "read succeeded"

log_step "Revoking the token as the Vault operator"
vault_run vault token revoke "${TOKEN}" >/dev/null
log_ok "token revoked"

log_step "Retrying the same read with the revoked token"
after_rc=0
after_out=''
show_cmd env 'VAULT_TOKEN=<device>' vault kv get "secret/devices/${DEVICE}"
after_out="$(as_lab_user_allow_fail env VAULT_TOKEN="${TOKEN}" \
  vault kv get "secret/devices/${DEVICE}" 2>&1)" || after_rc=$?

if (( after_rc == 0 )); then
  log_error "the revoked token STILL worked"
  report_expect "read denied after revocation" "read SUCCEEDED"
  exit 1
fi

report_expect "read denied after revocation" \
              "read failed (rc=${after_rc})"
log_detail "$(printf '%s\n' "${after_out}" | tail -3 | sed 's/^/    /')"

# The sentinel now holds a dead token; remove it so a later demo step fails
# loudly with "run task demo:login" rather than mysteriously being denied.
rm -f "${LOGIN_JSON}"
log_detail "Cleared ${LOGIN_JSON} — the recorded token is no longer valid."

log_info ""
log_ok "Device access is revocable centrally and takes effect immediately."
log_info "The TPM still holds the key and the certificate is still valid, but the"
log_info "device must authenticate again — and Vault can refuse. Hardware-bound"
log_info "identity and central revocation are complementary controls."
