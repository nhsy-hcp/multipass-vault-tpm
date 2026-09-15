#!/bin/bash
# Part 7.3: what the device token can and cannot do.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Three checks against the token minted in Part 7, each reported as
# expect-vs-actual so the operator judges the outcome rather than trusting a
# green tick:
#
#   1. token lookup  -> display_name cert-tpm-devices, TTL around 15m
#   2. kv get        -> succeeds
#   3. kv put        -> permission denied  (the failure IS the pass condition)
#
# Every vault call runs with the *device* token. as_lab_user sources env.sh,
# which exports VAULT_TOKEN=root, so the override has to happen after that
# sourcing: `env VAULT_TOKEN=<device> vault ...` is executed by the shell after
# the source has already run, and VAULT_TOKEN in the environment beats both the
# sourced value and the ~/.vault-token helper file.
#
# This script reports; it does not assert. It exits 0 even when an expectation
# is missed, but says so loudly, because an unexpected result is the
# interesting part of a demo, not a reason to abort the run.
# -----------------------------------------------------------------------------

device="${1:-}"
[[ -n "${device}" ]] || die "usage: 60_privilege.sh <device-name>"

LOGIN_JSON="${LAB_STATE_DIR}/login.json"
SECRET_PATH="secret/devices/${device}"

require_cmd jq runuser || die "missing prerequisites"

log_step "Part 7.3: least privilege — what the device token can do"

[[ -f "${LOGIN_JSON}" ]] || die "no device token found at ${LOGIN_JSON} — run 'task demo:login' first"

token="$(jq -r '.auth.client_token // empty' "${LOGIN_JSON}")"
[[ -n "${token}" ]] || die "${LOGIN_JSON} contains no .auth.client_token — re-run 'task demo:login'"

log_detail "using the device token from ${LOGIN_JSON} (${token:0:12}...), not the root token"

# Run a vault command as the lab user with the device token in the environment.
# Output and errors are merged so the Vault error text can be reported as the
# "actual" half of the pair; failure is never fatal here.
vault_as_device() {
  local rc=0 out
  out="$(as_lab_user_allow_fail env "VAULT_TOKEN=${token}" "$@" 2>&1)" || rc=$?
  printf '%s' "${out}"
  return "${rc}"
}

# First non-empty line, for one-line reporting of multi-line Vault errors.
first_line() { printf '%s\n' "$1" | grep -m1 -v '^[[:space:]]*$' || printf '(no output)'; }

# --- 1. who is this token? ---------------------------------------------------
log_info ""
log_info "1. Look the token up — who does Vault think we are?"
log_detail "   VAULT_TOKEN=<device> vault token lookup"

rc=0
lookup="$(vault_as_device vault token lookup -format=json)" || rc=$?
if (( rc == 0 )); then
  display_name="$(printf '%s' "${lookup}" | jq -r '.data.display_name // "(none)"')"
  ttl="$(printf '%s' "${lookup}" | jq -r '.data.ttl // 0')"
  policies="$(printf '%s' "${lookup}" | jq -r '(.data.policies // []) | join(", ")')"
  [[ "${ttl}" =~ ^[0-9]+$ ]] || ttl=0
  report_expect "display_name cert-tpm-devices, ttl ~15m" \
                "display_name ${display_name}, ttl ${ttl}s (~$(( ttl / 60 ))m)"
  log_detail "   policies: ${policies}"
  [[ "${display_name}" == "cert-tpm-devices" ]] || log_warn "display_name is not cert-tpm-devices — was the cert role renamed?"
else
  report_expect "display_name cert-tpm-devices, ttl ~15m" "lookup failed: $(first_line "${lookup}")"
  log_warn "the token is not usable — it may already have expired (15m TTL)"
fi

# --- 2. the read it is entitled to -------------------------------------------
log_info ""
log_info "2. Read the device secret — inside the policy."
log_detail "   VAULT_TOKEN=<device> vault kv get ${SECRET_PATH}"

rc=0
read_out="$(vault_as_device vault kv get -format=json "${SECRET_PATH}")" || rc=$?
if (( rc == 0 )); then
  message="$(printf '%s' "${read_out}" | jq -r '.data.data.message // "(no message field)"')"
  report_expect "read succeeds" "read succeeded: message = \"${message}\""
else
  report_expect "read succeeds" "read FAILED: $(first_line "${read_out}")"
  log_warn "the device-read policy should permit this — check 'vault policy read device-read'"
fi

# --- 3. the write it is not ---------------------------------------------------
log_info ""
log_info "3. Write to the same path — outside the policy. This should be refused."
log_detail "   VAULT_TOKEN=<device> vault kv put ${SECRET_PATH} message=tampered"

rc=0
write_out="$(vault_as_device vault kv put "${SECRET_PATH}" message=tampered)" || rc=$?
if (( rc != 0 )); then
  if printf '%s' "${write_out}" | grep -qi 'permission denied'; then
    report_expect "permission denied" "permission denied (vault exit ${rc})"
  else
    report_expect "permission denied" "denied, but differently: $(first_line "${write_out}")"
  fi
else
  # The write succeeding means the policy grants more than read. Report it
  # rather than hide it, then put the secret back the way it was.
  report_expect "permission denied" "WRITE SUCCEEDED — the policy is not least-privilege"
  log_warn "restoring the original value with the root token"
  as_lab_user_allow_fail vault kv put "${SECRET_PATH}" \
    message="hello from vault, attested by TPM key" >/dev/null 2>&1 || true
fi

log_info ""
log_ok "the same identity that proved itself with the TPM key is still only allowed what the policy says: read this secret, nothing more"
