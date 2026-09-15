#!/bin/bash
# Part 7: authenticate to Vault using a private key that never leaves the TPM.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Why this script hand-rolls HTTP
#
# The Vault CLI and Vault Agent load client keys from PEM files. A TPM key is
# not a key file — it is a wrapped blob that only the TPM can use — so neither
# can drive the mTLS handshake. OpenSSL's tpm2 provider can, which is why the
# login request is written by hand and pushed through `openssl s_client`.
#
# Exit-code contract (the guide's "stdout is empty means failure" is unusable
# for automation, so this script is explicit):
#
#   0  a token was issued. With --quiet-json the response JSON is the only
#      thing on stdout, so callers can pipe straight into jq. Without it the
#      output is a narrated summary and the JSON is left in state/login.json.
#   1  usage error, missing artefact, or the handshake/transport failed
#      (no HTTP response came back at all).
#   2  Vault answered, and the answer was a rejection (response has .errors,
#      or carries no .auth.client_token).
#   3  an HTTP response came back but its body could not be parsed as JSON.
#
# Anything Vault said is printed on stderr before a non-zero exit, so the
# negative-test scripts in Part 8 can show the operator *why* a login failed.
# -----------------------------------------------------------------------------

VAULT_HOSTPORT="${VAULT_HOSTPORT:-127.0.0.1:8200}"
HELPER="${LAB_DIR}/tpm-login-request.sh"
LOGIN_JSON="${LAB_STATE_DIR}/login.json"

# The response parser slices the body by the byte counts the wire gave us
# (Content-Length, chunk sizes), so ${#s} and ${s:o:n} must count bytes rather
# than characters. Deliberately not exported: child processes keep the system
# locale and their messages stay readable.
LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: 50_login.sh <device-name> [options]

Log in to Vault's cert auth method with a TPM-held key, over openssl s_client.

Options:
  --cert FILE       client certificate (absolute, or relative to the PKI dir)
  --key FILE        TPM key file    (absolute, or relative to the PKI dir)
  --role NAME       cert auth role name (default: tpm-devices)
  --tpm-port PORT   drive a different software TPM (the stolen-key demo)
  --no-cert         send no client certificate at all (the 8.2 demo)
  --quiet-json      print only the JSON response, no narration
  --debug           verbose handshake: drop -quiet, let openssl stderr through
  -h, --help        show this help

Defaults resolve to <pki-dir>/<device-name>.crt and
<pki-dir>/<device-name>.tpmkey.pem.
USAGE
}

# --- options ----------------------------------------------------------------
device=''
cert_opt=''
key_opt=''
role='tpm-devices'
tpm_port=''
no_cert=0
quiet_json=0
debug=0

need_value() { [[ -n "${2:-}" ]] || { usage >&2; die "$1 requires a value"; }; }

while (( $# )); do
  case "$1" in
    --cert)      need_value "$1" "${2:-}"; cert_opt="$2"; shift 2 ;;
    --key)       need_value "$1" "${2:-}"; key_opt="$2";  shift 2 ;;
    --role)      need_value "$1" "${2:-}"; role="$2";     shift 2 ;;
    --tpm-port)  need_value "$1" "${2:-}"; tpm_port="$2"; shift 2 ;;
    --no-cert)   no_cert=1;   shift ;;
    --quiet-json) quiet_json=1; shift ;;
    --debug)     debug=1;     shift ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    -*)          usage >&2; die "unknown option: $1" ;;
    *)
      [[ -z "${device}" ]] || { usage >&2; die "unexpected argument: $1"; }
      device="$1"; shift ;;
  esac
done

# A device name is how every path is resolved. Only --no-cert can do without
# one, because it presents no certificate and no key.
if [[ -z "${device}" && "${no_cert}" -eq 0 ]]; then
  usage >&2
  die "a device name is required"
fi

[[ "${tpm_port}" =~ ^[0-9]+$ || -z "${tpm_port}" ]] || die "--tpm-port must be a port number, got: ${tpm_port}"

# Narration is suppressed wholesale by --quiet-json so that stdout stays
# machine-readable. Errors always go to stderr, so they survive either way.
say()          { (( quiet_json )) || log_info "$@"; }
say_detail()   { (( quiet_json )) || log_detail "$@"; }
say_step()     { (( quiet_json )) || log_step "$@"; }
say_ok()       { (( quiet_json )) || log_ok "$@"; }
say_detected() { (( quiet_json )) || log_detected "$@"; }

# Device artefacts live in the PKI dir; callers may override with a bare
# filename (resolved there) or an absolute path.
resolve_pki_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s' "${LAB_PKI_DIR}/$1" ;;
  esac
}

# --- HTTP response parsing ---------------------------------------------------
# The guide pipes the response through `tail -1`, which assumes the body is a
# single line and is the last thing on the wire. Neither holds in general:
#   * Go's HTTP server drops to chunked encoding whenever it cannot size the
#     body, and a chunked response ends with "0" and a blank line, not JSON;
#   * with --debug there is no -quiet, so s_client frames the response with a
#     session banner before it and a "closed" line after it.
# So the response is taken apart properly: locate the status line, split the
# headers off at the CRLF blank line, then honour whatever framing the headers
# declare. Everything below works on the raw string rather than line by line,
# because chunk sizes are byte counts and lines are not.

# Decode Transfer-Encoding: chunked, byte for byte. A line-based filter cannot
# do this correctly: chunk boundaries need not fall on line boundaries, so a
# size token can be glued to the tail of a body line — where a line filter
# would not see it and would silently splice it into the JSON.
decode_chunked() {
  local rest="$1" out='' size_line size
  while [[ -n "${rest}" ]]; do
    size_line="${rest%%$'\n'*}"
    [[ "${size_line}" != "${rest}" ]] || return 1       # no newline: truncated
    rest="${rest#*$'\n'}"
    size_line="${size_line%$'\r'}"
    size_line="${size_line%%;*}"                        # ignore chunk extensions
    [[ "${size_line}" =~ ^[0-9a-fA-F]+$ ]] || return 1
    size=$(( 16#${size_line} ))
    if (( size == 0 )); then break; fi                  # terminating chunk
    (( ${#rest} >= size )) || return 1                  # chunk cut short
    out+="${rest:0:size}"
    rest="${rest:size}"
    rest="${rest#$'\r'}"
    rest="${rest#$'\n'}"                                # CRLF after chunk data
  done
  printf '%s' "${out}"
}

# Last-resort framing recovery: drop bare-hex chunk size lines. JSON never
# produces a line that looks like one.
strip_chunk_lines() {
  awk '{ line = $0; sub(/\r$/, "", line); if (line ~ /^[0-9a-fA-F]+$/) next; print line }'
}

# extract_json_body <raw-response>
# Sets PARSED_JSON to the pretty-printed body and HTTP_STATUS_LINE to the
# status line. Returns 1 no status line, 2 no header terminator, 3 empty body,
# 4 not JSON. It assigns rather than echoes so the caller can read both values
# without running it in a subshell.
HTTP_STATUS_LINE=''
PARSED_JSON=''
extract_json_body() {
  local response="$1" headers body encoding length candidate json

  # 1. Discard anything before the status line (the --debug banner).
  if [[ "${response}" != HTTP/1.* ]]; then
    [[ "${response}" == *$'\n'HTTP/1.* ]] || return 1
    response="HTTP/1.${response#*$'\n'HTTP/1.}"
  fi

  # 2. Headers end at the first blank line. Tolerate bare LF as well as CRLF.
  if [[ "${response}" == *$'\r\n\r\n'* ]]; then
    headers="${response%%$'\r\n\r\n'*}"; body="${response#*$'\r\n\r\n'}"
  elif [[ "${response}" == *$'\n\n'* ]]; then
    headers="${response%%$'\n\n'*}"; body="${response#*$'\n\n'}"
  else
    return 2
  fi
  HTTP_STATUS_LINE="${headers%%$'\n'*}"
  HTTP_STATUS_LINE="${HTTP_STATUS_LINE%$'\r'}"

  # 3. Honour the declared framing.
  encoding="$(printf '%s\n' "${headers}" | grep -i -m1 '^transfer-encoding:' | tr -d '\r' || true)"
  length="$(printf '%s\n' "${headers}" | grep -i -m1 '^content-length:' | tr -dc '0-9' || true)"

  candidate=''
  if [[ "${encoding,,}" == *chunked* ]]; then
    candidate="$(decode_chunked "${body}")" || candidate=''
  elif [[ -n "${length}" ]]; then
    # Exactly Content-Length bytes — this is what keeps the trailing "closed"
    # that s_client prints in --debug mode out of the body.
    candidate="${body:0:length}"
  else
    candidate="${body}"
  fi

  [[ -n "${body//[[:space:]]/}" ]] || return 3

  # 4. Parse, with two fallbacks for a response whose framing we misread.
  json="$(printf '%s' "${candidate}" | jq . 2>/dev/null)" || json=''
  if [[ -z "${json}" ]]; then
    candidate="$(printf '%s\n' "${body}" | strip_chunk_lines)"
    json="$(printf '%s\n' "${candidate}" | jq . 2>/dev/null)" || json=''
  fi
  if [[ -z "${json}" && "${candidate}" == *'}'* ]]; then
    # Trim trailing noise: a JSON object ends at its last closing brace.
    candidate="${candidate%\}*}}"
    json="$(printf '%s' "${candidate}" | jq . 2>/dev/null)" || json=''
  fi
  [[ -n "${json}" ]] || return 4

  PARSED_JSON="${json}"
}

require_cmd jq awk runuser || die "missing prerequisites"
lab_mkdir "${LAB_DIR}" "${LAB_STATE_DIR}"

say_step "Part 7: Vault login with the TPM-held key (role ${role})"

# --- build the openssl argument tail ----------------------------------------
# Kept as an array so quoting survives the trip through as_lab_user.
openssl_extra=()
cert_path=''
key_path=''

if (( no_cert )); then
  say_detected "--no-cert" "the request is sent with no client certificate, so Vault has nothing to authenticate"
else
  cert_path="$(resolve_pki_path "${cert_opt:-${device}.crt}")"
  key_path="$(resolve_pki_path "${key_opt:-${device}.tpmkey.pem}")"
  [[ -f "${cert_path}" ]] || die "client certificate not found: ${cert_path} (run 'task enrol' first?)"
  [[ -f "${key_path}"  ]] || die "TPM key not found: ${key_path} (run 'task enrol' first?)"
  openssl_extra=(-cert "${cert_path}" -key "${key_path}")
  say_detail "certificate  ${cert_path}"
  say_detail "tpm key      ${key_path}"
fi

if [[ -n "${tpm_port}" ]]; then
  say_detected "--tpm-port ${tpm_port}" "the handshake will use swtpm:port=${tpm_port} rather than the device TPM"
fi

# --- the request helper -----------------------------------------------------
# Written out as a standalone file rather than squeezed into one shell -c
# string: the pipeline below is fiddly, and an operator who needs to reproduce
# a failure can run this file by hand. Root-owned 0755 — the lab user only
# needs to read it, and must not be able to rewrite what root will execute.
if FILE_MODE=0755 write_if_changed "${HELPER}" <<'HELPER'
#!/bin/bash
# Generated by scripts/50_login.sh — edits are overwritten on the next run.
#
# Usage: tpm-login-request.sh <host:port> <role> <debug 0|1> [openssl args...]
#
# Sends one HTTP POST to /v1/auth/cert/login through an mTLS connection whose
# client key lives in the TPM, and writes the RAW response (status line,
# headers and body) to stdout. Parsing is the caller's job; this script only
# has to get the bytes on and off the wire, and to exit with openssl's status
# so a failed handshake is distinguishable from a rejected login.
#
# Must run as the lab user: a TPM key blob is usable only by the user that
# created it.
#
# No `set -e`: the openssl exit status is captured and returned deliberately.
set -uo pipefail

hostport="$1"
role="$2"
debug="$3"
shift 3

: "${VAULT_CACERT:?VAULT_CACERT is unset — source ~/lab/env.sh first}"

body="{\"name\":\"${role}\"}"

# Provider ORDER matters here, and not in the way the written guide suggests.
#
# With `-provider tpm2` first, OpenSSL prefers the tpm2 provider for every
# operation it can serve — including ordinary SHA-256 hashing. The TLS handshake
# then drives the software TPM through many hash sequences, and swtpm runs out
# of transient object slots partway through verifying the server's
# CertificateVerify:
#
#   Esys_HashSequenceStart ... ErrorCode (0x00000902)
#   tpm2::cannot hash:: tpm:warn(2.0): out of memory for object contexts
#   SSL routines:tls_process_cert_verify:bad signature
#
# which reads like a certificate problem but is really resource exhaustion.
#
# Loading `default` first keeps general-purpose hashing in software. The TPM is
# still the only thing that can touch the private key — nothing but the tpm2
# provider can decode a TSS2 blob, so the CertificateVerify signature is still
# computed inside the TPM, which is the whole point of the demo. No propquery is
# needed: provider order alone resolves it.
opts=(
  -provider default -provider tpm2
  -connect "${hostport}"
  -CAfile "${VAULT_CACERT}"
)

if [[ "${debug}" == "1" ]]; then
  # Drop -quiet so the session and certificate banner is visible. -quiet also
  # implies -ign_eof, so ask for that explicitly: without it s_client tears the
  # connection down the moment our request hits EOF on stdin — before Vault's
  # response arrives — and the body would appear to be empty.
  opts+=(-ign_eof)
else
  opts+=(-quiet)
fi
opts+=("$@")

if [[ "${debug}" == "1" ]]; then
  printf '+ openssl s_client %s\n' "$(printf '%q ' "${opts[@]}")" >&2
  printf '+ request body: %s\n' "${body}" >&2
fi

# HTTP/1.1 framing, done by hand:
#   Host            — mandatory in HTTP/1.1.
#   Content-Length  — Vault will not read a body without it.
#   Connection: close — makes Vault close the socket after the response, which
#                     is what lets s_client return instead of hanging.
printf 'POST /v1/auth/cert/login HTTP/1.1\r\nHost: %s\r\nUser-Agent: tpm-lab-login/1.0\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
  "${hostport}" "${#body}" "${body}" \
  | openssl s_client "${opts[@]}"

exit "${PIPESTATUS[1]}"
HELPER
then
  say_detail "wrote request helper ${HELPER}"
fi

# --- run it -----------------------------------------------------------------
# env(1) runs *after* as_lab_user sources env.sh, so these assignments win over
# the TCTI exported there. That is the whole trick behind --tpm-port.
run_cmd=(env)
if [[ -n "${tpm_port}" ]]; then
  run_cmd+=("TPM2OPENSSL_TCTI=swtpm:port=${tpm_port}" "TPM2TOOLS_TCTI=swtpm:port=${tpm_port}")
fi
run_cmd+=(bash "${HELPER}" "${VAULT_HOSTPORT}" "${role}" "${debug}" "${openssl_extra[@]}")

err_file=''
cleanup() { [[ -n "${err_file}" && -f "${err_file}" ]] && rm -f "${err_file}"; return 0; }
trap cleanup EXIT

say "Performing the mTLS handshake — the TPM signs the CertificateVerify, so this takes a moment..."
if (( debug )); then
  say_detail "reproduce by hand:"
  say_detail "  sudo -u ${LAB_USER} bash -lc 'source ${LAB_DIR}/env.sh; $(printf '%q ' "${run_cmd[@]}")'"
fi

raw=''
rc=0
if (( debug )); then
  # Let openssl's stderr through untouched: a failed handshake says why there.
  raw="$(as_lab_user "${run_cmd[@]}")" || rc=$?
else
  # Not discarded, just parked: shown only if something goes wrong. The guide's
  # 2>/dev/null threw away the only evidence of a handshake failure.
  err_file="$(mktemp)"
  raw="$(as_lab_user "${run_cmd[@]}" 2>"${err_file}")" || rc=$?
fi

show_stderr() {
  [[ -n "${err_file}" && -s "${err_file}" ]] || return 0
  log_error "openssl said:"
  sed 's/^/    /' "${err_file}" >&2
}

if [[ -z "${raw}" ]]; then
  log_error "no HTTP response — the TLS handshake did not complete (openssl exit ${rc})"
  show_stderr
  log_info "Re-run with --debug to see the full handshake." >&2
  exit 1
fi

rc_parse=0
extract_json_body "${raw}" || rc_parse=$?
json="${PARSED_JSON}"
if [[ -z "${json}" ]]; then
  case "${rc_parse}" in
    1) log_error "no HTTP status line in the response (openssl exit ${rc})" ;;
    2) log_error "malformed HTTP response: headers are not terminated by a blank line" ;;
    3) log_error "HTTP response carried no body — ${HTTP_STATUS_LINE:-?}" ;;
    *) log_error "HTTP response body is not JSON — ${HTTP_STATUS_LINE:-?}" ;;
  esac
  show_stderr
  printf '%s\n' "${raw}" | head -25 >&2
  exit 3
fi
say_detail "response: ${HTTP_STATUS_LINE}"

# A parsed response is not a successful one: Vault reports auth failures as
# 400/403 with an .errors array, which is a failure for our purposes.
mapfile -t vault_errors < <(printf '%s' "${json}" | jq -r '(.errors // [])[]')
if (( ${#vault_errors[@]} )); then
  log_error "Vault rejected the login:"
  printf '    %s\n' "${vault_errors[@]}" >&2
  exit 2
fi

client_token="$(printf '%s' "${json}" | jq -r '.auth.client_token // empty')"
if [[ -z "${client_token}" ]]; then
  log_error "Vault returned no client token"
  printf '%s\n' "${json}" >&2
  exit 2
fi

# --- success ----------------------------------------------------------------
# The file holds a live token: lab-user owned, 0600.
tmp_json="$(mktemp)"
printf '%s\n' "${json}" > "${tmp_json}"
install -o "${LAB_USER}" -g "${LAB_USER}" -m 0600 "${tmp_json}" "${LOGIN_JSON}"
rm -f "${tmp_json}"

if (( quiet_json )); then
  printf '%s\n' "${json}"
  exit 0
fi

policies="$(printf '%s' "${json}" | jq -r '(.auth.token_policies // .auth.policies // []) | join(", ")')"
common_name="$(printf '%s' "${json}" | jq -r '.auth.metadata.common_name // "(none)"')"
cert_name="$(printf '%s' "${json}" | jq -r '.auth.metadata.cert_name // "(none)"')"
lease="$(printf '%s' "${json}" | jq -r '.auth.lease_duration // 0')"
[[ "${lease}" =~ ^[0-9]+$ ]] || lease=0

if (( debug )); then
  token_display="${client_token}"
else
  # Elide the token: this output is meant to be shown on a projector.
  token_display="${client_token:0:12}... (${#client_token} chars)"
fi

say_ok "authenticated as ${common_name}"
say_detail "  client token   ${token_display}"
say_detail "  policies       ${policies}"
say_detail "  cert role      ${cert_name}"
say_detail "  lease          ${lease}s (~$(( lease / 60 ))m)"
say_detail "  saved to       ${LOGIN_JSON}"
say ""
say "The private key never left the TPM — only a signature did."
say "Next: task demo:privilege"
exit 0
