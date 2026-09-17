#!/bin/bash
# Part 7: authenticate to Vault using a private key that never leaves the TPM.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

# -----------------------------------------------------------------------------
# `vault login -method=tpm` drives the mTLS handshake itself: it reads the
# certificate and the key handle from the state directory written by
# `vault tpm attest`, asks the TPM to sign the handshake with the application
# key, and posts the result to auth/tpm/login. Vault checks that the
# certificate chains to the mount's own CA and that the TPM ID in the
# certificate is one the role trusts, then issues a token.
#
# Exit-code contract, so the Part 8 negative tests can reason about outcomes:
#
#   0  a token was issued. With --quiet-json the response JSON is the only
#      thing on stdout, so callers can pipe straight into jq. Without it the
#      output is a narrated summary and the JSON is left in state/login.json.
#   1  usage error or a missing artefact (no certificate, no TPM socket).
#   2  the login was attempted and refused — by the TPM (it could not load the
#      key) or by Vault (it rejected the certificate).
#
# Anything Vault or the TPM said is printed on stderr before a non-zero exit,
# so the negative-test scripts can show the operator *why* a login failed.
# -----------------------------------------------------------------------------

LOGIN_JSON="${STATE_DIR}/login.json"

usage() {
  cat <<'USAGE'
Usage: 50_login.sh <device-name> [options]

Log in to Vault's tpm auth method with the TPM-held key attested in Part 6.

Options:
  --state-dir DIR    directory written by `vault tpm attest`
                     (default: <lab tpm dir>/<device-name>)
  --role NAME        tpm auth role name (default: devices)
  --mount PATH       tpm auth mount path (default: tpm)
  --tpm-device PATH  TPM socket to sign with (default: the device TPM;
                     the stolen-key demo points this at the attacker TPM)
  --no-save          do not record the token in state/login.json
  --quiet-json       print only the JSON response, no narration
  --debug            show the Vault CLI's stderr in full
  -h, --help         show this help
USAGE
}

device="${1:-}"
[[ -n "${device}" && "${device}" != -* ]] || { usage >&2; exit 1; }
shift

state_dir=''
role='devices'
mount='tpm'
tpm_device="${TPM_SOCK}"
no_save=0
quiet_json=0
debug=0

need_value() { [[ -n "${2:-}" ]] || { usage >&2; die "$1 requires a value"; }; }

while (( $# > 0 )); do
  case "$1" in
    --state-dir)  need_value "$1" "${2:-}"; state_dir="$2";  shift 2 ;;
    --role)       need_value "$1" "${2:-}"; role="$2";       shift 2 ;;
    --mount)      need_value "$1" "${2:-}"; mount="$2";      shift 2 ;;
    --tpm-device) need_value "$1" "${2:-}"; tpm_device="$2"; shift 2 ;;
    --no-save)    no_save=1;    shift ;;
    --quiet-json) quiet_json=1; shift ;;
    --debug)      debug=1;      shift ;;
    -h|--help)    usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[[ -n "${state_dir}" ]] || state_dir="${TPM_DIR}/${device}"

# Narration is suppressed wholesale by --quiet-json so that stdout stays
# machine-readable.
say()          { (( quiet_json )) || log_info "$@"; }
say_detail()   { (( quiet_json )) || log_detail "$@"; }
say_step()     { (( quiet_json )) || log_step "$@"; }
say_ok()       { (( quiet_json )) || log_ok "$@"; }

crt="${state_dir}/client.crt"
[[ -s "${crt}" ]] || die "no certificate at ${crt} — run 'task enrol' first"
[[ -s "${state_dir}/client-key.json" ]] || die "no key handle at ${state_dir}/client-key.json — run 'task enrol' first"
[[ -S "${tpm_device}" ]] || die "no TPM socket at ${tpm_device} — run 'task tpm' first"
require_cmd jq || die "missing prerequisites"

say_step "Part 7: log in to Vault with the TPM-held key (${device})"
say "  certificate  ${crt}"
say "  key handle   ${state_dir}/client-key.json → app.blob (sealed to a TPM)"
say "  TPM          ${tpm_device}"
say "  role         ${role} on auth/${mount}"
say ''
say_detail "$(as_lab_user openssl x509 -in "${crt}" -noout -subject -issuer 2>/dev/null | sed 's/^/  /')"
say ''

# Lab-only housekeeping: a raw socket has no resource manager to free the
# handles a previous login left loaded. See flush_tpm_contexts in common.sh.
flush_tpm_contexts "${tpm_device}"

say "vault login -method=tpm -no-store role_name=${role} tpm-state-dir=… tpmDevice=…"
say_detail "  -no-store keeps the device token out of ~/.vault-token, where it would"
say_detail "  otherwise replace the dev root token the lab shell relies on."

tmp_json="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "${tmp_json}" "${err_file}"' EXIT

login_args=(-method=tpm -no-store -format=json)
[[ "${mount}" == "tpm" ]] || login_args+=(-path="${mount}")

rc=0
as_lab_user_allow_fail env "VAULT_TOKEN=${NO_TOKEN}" \
  vault login "${login_args[@]}" \
    role_name="${role}" \
    tpm-state-dir="${state_dir}" \
    tpmDevice="${tpm_device}" >"${tmp_json}" 2>"${err_file}" || rc=$?

# The CLI always prints a reminder that the token was not stored. Drop it so
# the operator sees only the lines that matter.
grep -v -E 'token was not stored|VAULT_TOKEN environment|pass the token below|^[[:space:]]*$' "${err_file}" > "${err_file}.clean" || true
mv -f "${err_file}.clean" "${err_file}"

if (( rc != 0 )); then
  if (( debug )); then cat "${err_file}" >&2; else head -n 6 "${err_file}" >&2; fi
  die_msg="login refused (vault exit ${rc})"
  (( quiet_json )) || log_error "${die_msg}"
  exit 2
fi

token="$(jq -r '.auth.client_token // empty' "${tmp_json}" 2>/dev/null || true)"
if [[ -z "${token}" ]]; then
  cat "${err_file}" >&2
  (( quiet_json )) || log_error "Vault answered, but with no client token"
  exit 2
fi

if (( no_save == 0 )); then
  install -o "${VM_USER}" -g "${VM_USER}" -m 0600 "${tmp_json}" "${LOGIN_JSON}"
fi

if (( quiet_json )); then
  cat "${tmp_json}"
  exit 0
fi

policies="$(jq -r '(.auth.policies // []) | join(", ")' "${tmp_json}")"
ttl="$(jq -r '.auth.lease_duration // 0' "${tmp_json}")"
meta_tpm="$(jq -r '.auth.metadata.tpm_id // "(none)"' "${tmp_json}")"
meta_role="$(jq -r '.auth.metadata.role_name // "(none)"' "${tmp_json}")"
meta_cn="$(jq -r '.auth.metadata.common_name // "(none)"' "${tmp_json}")"
meta_serial="$(jq -r '.auth.metadata.serial_number // "(none)"' "${tmp_json}")"

say ''
say_ok "token issued: ${token:0:12}… (ttl ${ttl}s, policies: ${policies})"
say_detail "  Token metadata, from the certificate Vault verified:"
say_detail "    tpm_id       ${meta_tpm}   ← the identity Vault enforced: this TPM is in the role's group"
say_detail "    role_name    ${meta_role}"
say_detail "    common_name  ${meta_cn}   ← self-asserted at attestation; not checked by anything"
say_detail "    serial       ${meta_serial}"
if (( no_save == 0 )); then
  say_detail "  saved to       ${LOGIN_JSON}"
fi
say ''
say "The handshake was signed inside the TPM. The application key was never in a"
say "file, never in memory outside the chip, and cannot be — Part 8.1 shows what"
say "happens to the same files on a different TPM."

exit 0
