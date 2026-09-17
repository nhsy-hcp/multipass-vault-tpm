#!/bin/bash
# Shared helpers for the TPM cert auth lab.
# Sourced by every script in scripts/ (host and in-VM).
# shellcheck shell=bash

# Lab layout inside the VM. Overridable for testing.
VM_USER="${VM_USER:-ubuntu}"
VM_DIR="${VM_DIR:-/home/${VM_USER}/lab}"
STATE_DIR="${STATE_DIR:-${VM_DIR}/state}"
TLS_DIR="${TLS_DIR:-${VM_DIR}/vault-tls}"
# Where `vault tpm attest` keeps each device's certificate and key blobs.
TPM_DIR="${TPM_DIR:-${VM_DIR}/tpm}"
export VM_USER VM_DIR STATE_DIR TLS_DIR TPM_DIR

# Software TPMs. Each swtpm instance serves a unix socket inside its own state
# directory, and tpm2-tools, OpenSSL and the Vault CLI all reach the TPM through
# that one path — on real hardware it becomes /dev/tpmrm0 and nothing else
# changes. The attacker TPM stands in for a different machine: same software,
# different storage seed.
TPM_STATE_ROOT="${TPM_STATE_ROOT:-${VM_DIR}/tpmstate}"
TPM_SOCK="${TPM_SOCK:-${TPM_STATE_ROOT}/device/swtpm.sock}"
ATTACKER_TPM_SOCK="${ATTACKER_TPM_SOCK:-${TPM_STATE_ROOT}/attacker/swtpm.sock}"
export TPM_STATE_ROOT TPM_SOCK ATTACKER_TPM_SOCK

# Scratch space.
#
# These scripts run inside the VM, where the guest's own /tmp is the right home
# for staged scripts and scratch. (On the host side the project keeps its
# scratch in a project-local .tmp/ instead, so the Mac stays clean.) VM_STAGE is
# where the Taskfile drops the scripts and is the only place they should write
# scratch files — namespaced so the lab cannot collide with anything else.
VM_STAGE="${VM_STAGE:-/tmp/tpm-lab}"
SCRATCH_DIR="${SCRATCH_DIR:-${VM_STAGE}/scratch}"
export VM_STAGE SCRATCH_DIR

# Point mktemp and anything else honouring TMPDIR at the lab's own scratch dir,
# so nothing this project runs leaves files loose in the system temp directory.
#
# In-VM scripts run as root, but every as_lab_user command inherits TMPDIR via
# runuser, so the lab user must be able to write here too — otherwise anything
# that honours TMPDIR under as_lab_user (swtpm_setup's cert scratch, mktemp)
# fails with "Permission denied". Root can still write to a 0700 directory it
# does not own. Guarded so host-side scripts, where the lab user does not
# exist, are unaffected.
mkdir -p "${SCRATCH_DIR}" 2>/dev/null || true
if [[ ${EUID} -eq 0 ]] && id -u "${VM_USER}" >/dev/null 2>&1; then
  chown "${VM_USER}:${VM_USER}" "${SCRATCH_DIR}" 2>/dev/null || true
  chmod 0700 "${SCRATCH_DIR}" 2>/dev/null || true
fi
TMPDIR="${SCRATCH_DIR}"
export TMPDIR

# --- output -----------------------------------------------------------------
# Colour only when attached to a terminal, so piped/captured output stays clean.
if [[ -t 1 ]]; then
  _C_RESET=$'\033[0m'; _C_BOLD=$'\033[1m'; _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'
else
  _C_RESET=''; _C_BOLD=''; _C_DIM=''
  _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''
fi

log_step()  { printf '\n%s=== %s ===%s\n' "${_C_BOLD}${_C_BLUE}" "$*" "${_C_RESET}"; }
log_info()  { printf '%s\n' "$*"; }
log_detail(){ printf '%s%s%s\n' "${_C_DIM}" "$*" "${_C_RESET}"; }
log_ok()    { printf '%s  ok%s  %s\n' "${_C_GREEN}" "${_C_RESET}" "$*"; }
log_warn()  { printf '%swarn%s  %s\n' "${_C_YELLOW}" "${_C_RESET}" "$*" >&2; }
log_error() { printf '%sfail%s  %s\n' "${_C_RED}" "${_C_RESET}" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# Announce an automatic decision: what was detected and what follows from it.
log_detected() { printf 'Detected %s — %s\n' "$1" "$2"; }

# Print an expected-vs-actual pair. Used by the Part 8 negative demos, which
# report rather than assert: the operator sees both halves and judges.
report_expect() {
  printf '  %-10s %s\n' 'expect:' "$1"
  printf '  %-10s %s\n' 'actual:' "$2"
}

# --- readiness --------------------------------------------------------------
# wait_for <description> <timeout-seconds> <command...>
# Polls the command until it succeeds. Replaces the guide's blind `sleep`.
wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local interval=1 elapsed=0

  printf 'Waiting for %s (timeout %ss)' "${desc}" "${timeout}"
  while ! "$@" >/dev/null 2>&1; do
    if (( elapsed >= timeout )); then
      printf '\n'
      log_error "timed out after ${timeout}s waiting for ${desc}"
      return 1
    fi
    printf '.'
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
  done
  printf '\n'
  log_ok "${desc} ready after ${elapsed}s"
}

# wait_for_unit <unit> [timeout] [settle]
# systemd-native readiness: the unit is active and *stays* active.
#
# A single `systemctl is-active` check is not enough. With Restart=on-failure a
# crashing service cycles through active on every attempt, so a one-shot check
# can catch it mid-flap and report success for a unit that is actually dying —
# which then surfaces much later as a confusing timeout somewhere else. Require
# several consecutive active observations, and bail out immediately if systemd
# has already given up on the unit.
wait_for_unit() {
  local unit="$1" timeout="${2:-30}" settle="${3:-3}"
  local elapsed=0 streak=0

  printf 'Waiting for systemd unit %s (timeout %ss)' "${unit}" "${timeout}"
  while (( streak < settle )); do
    if systemctl is-failed --quiet "${unit}"; then
      printf '\n'
      log_error "${unit} entered a failed state"
      log_error "inspect with: journalctl -u ${unit} --no-pager -n 50"
      return 1
    fi

    if systemctl is-active --quiet "${unit}"; then
      streak=$(( streak + 1 ))
    elif (( streak > 0 )); then
      # It was up and is not any more: a restart loop, not a slow start.
      printf '!'
      streak=0
    fi

    if (( streak >= settle )); then break; fi

    if (( elapsed >= timeout )); then
      printf '\n'
      log_error "timed out after ${timeout}s waiting for ${unit} to stay active"
      log_error "inspect with: journalctl -u ${unit} --no-pager -n 50"
      return 1
    fi
    printf '.'
    sleep 1
    elapsed=$(( elapsed + 1 ))
  done

  printf '\n'
  log_ok "${unit} active and stable"
}

# --- running as the lab user ------------------------------------------------
# Scripts arrive via `sudo -E bash`, so they run as root. Lab artefacts must be
# owned by the unprivileged lab user, and the TPM key blobs must be created by
# the same user that will later use them. Everything touching the lab directory
# goes through here.
#
#   as_lab_user openssl genpkey ...
#
# The lab environment (TCTI, VAULT_ADDR, VAULT_TOKEN) is sourced from env.sh so
# the command sees exactly what an interactive `multipass shell` session would.
as_lab_user() {
  local cmd
  cmd="$(printf '%q ' "$@")"
  runuser -u "${VM_USER}" -- bash -lc "set -euo pipefail; source '${VM_DIR}/env.sh'; ${cmd}"
}

# Same, but tolerates failure and returns the exit status to the caller.
# Used by the negative demos, where failure is the expected outcome.
as_lab_user_allow_fail() {
  local rc=0
  as_lab_user "$@" || rc=$?
  return "${rc}"
}

lab_mkdir() {
  install -d -o "${VM_USER}" -g "${VM_USER}" -m 0755 "$@"
}

# Write stdin to a lab-owned file. Vault CLI output is captured by root, so
# ownership is applied on the way to disk rather than inherited.
write_lab_file() {
  local dest="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat > "${tmp}"
  install -o "${VM_USER}" -g "${VM_USER}" -m "${mode}" "${tmp}" "${dest}"
  rm -f "${tmp}"
}

# --- TPM housekeeping -------------------------------------------------------
# flush_tpm_contexts [socket]
#
# The software TPM is reached over a raw socket. There is no kernel resource
# manager (/dev/tpmrm0) in the path to free transient objects when a client
# disconnects, and `vault login -method=tpm` leaves one loaded key behind per
# call. swtpm has three transient slots, so the fourth login would fail with
# "out of memory for object contexts". Flush before every TPM-touching Vault
# command. On real hardware the resource manager makes this unnecessary.
flush_tpm_contexts() {
  local sock="${1:-${TPM_SOCK}}"
  as_lab_user_allow_fail env "TPM2TOOLS_TCTI=swtpm:path=${sock}" \
    tpm2_flushcontext -t >/dev/null 2>&1 || true
  as_lab_user_allow_fail env "TPM2TOOLS_TCTI=swtpm:path=${sock}" \
    tpm2_flushcontext -l >/dev/null 2>&1 || true
}

# --- the device side of Vault ------------------------------------------------
# The attestation and login endpoints are unauthenticated, so Vault ignores
# whatever token the CLI attaches — but leaving VAULT_TOKEN alone would put
# 'root' on the wire during the very steps that are meant to prove the device
# holds no credential, and an empty value is worse: the CLI falls back to the
# ~/.vault-token helper file, which the dev server populates with the root
# token. A deliberate placeholder keeps the demo honest.
NO_TOKEN="device-holds-no-token"
export NO_TOKEN

# tpm_attest <socket> <state-dir> <role> <cn> [mount]
#
# Runs `vault tpm attest` as the lab user with no token, flushing transient
# contexts first. Vault rate-limits attestation per EK (about ten seconds in
# this beta), so a rate-limit refusal is retried after a wait; any other
# outcome is returned as-is. Prints the CLI's output; returns its exit status.
tpm_attest() {
  local sock="$1" state_dir="$2" role="$3" cn="$4" mount="${5:-tpm}"
  local attempt=0 rc out
  while :; do
    attempt=$(( attempt + 1 ))
    flush_tpm_contexts "${sock}"
    rc=0
    out="$(as_lab_user_allow_fail env "VAULT_TOKEN=${NO_TOKEN}" \
      vault tpm attest \
        -role-name="${role}" \
        -mount-path="auth/${mount}" \
        -tpm-device-path="${sock}" \
        -tpm-state-dir="${state_dir}" \
        -cert-subject-CN="${cn}" 2>&1)" || rc=$?
    if (( rc != 0 )) && (( attempt < 4 )) && printf '%s' "${out}" | grep -qi 'rate limit'; then
      log_detected "Vault's per-EK attestation rate limit" "waiting 12s before retrying (attempt ${attempt})" >&2
      sleep 12
      continue
    fi
    printf '%s\n' "${out}"
    return "${rc}"
  done
}

# True when the named mount is already present at the given path ("tpm/").
mount_enabled() {
  local kind="$1" path="$2"
  as_lab_user vault "${kind}" list -format=json 2>/dev/null \
    | jq -e --arg p "${path}" 'has($p)' >/dev/null 2>&1
}

# --- misc -------------------------------------------------------------------
require_cmd() {
  local missing=0
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { log_error "required command not found: $c"; missing=1; }
  done
  (( missing == 0 )) || return 1
}

# Render a .tpl file, substituting ${NAME} placeholders from the environment.
# Zero-dependency templating, per the reference projects' sed convention.
render_template() {
  local src="$1" dest="$2"; shift 2
  local expr=''
  for var in "$@"; do
    expr+="s|\\\${${var}}|${!var}|g;"
  done
  sed "${expr}" "${src}" > "${dest}"
}

# Write a file only if the content differs, so callers can skip needless
# systemd reloads. Returns 0 when changed, 1 when already up to date.
write_if_changed() {
  local dest="$1" tmp
  # TMPDIR is set above to the lab's own scratch dir, so this never lands in
  # the system temp directory.
  tmp="$(mktemp)"
  cat > "${tmp}"
  if [[ -f "${dest}" ]] && cmp -s "${tmp}" "${dest}"; then
    rm -f "${tmp}"
    return 1
  fi
  install -m "${FILE_MODE:-0644}" "${tmp}" "${dest}"
  rm -f "${tmp}"
  return 0
}
