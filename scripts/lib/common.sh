#!/bin/bash
# Shared helpers for the TPM cert auth lab.
# Sourced by every script in scripts/ (host and in-VM).
# shellcheck shell=bash

# Lab layout inside the VM. Overridable for testing.
LAB_USER="${LAB_USER:-ubuntu}"
LAB_DIR="${LAB_DIR:-/home/${LAB_USER}/lab}"
LAB_STATE_DIR="${LAB_STATE_DIR:-${LAB_DIR}/state}"
LAB_TLS_DIR="${LAB_TLS_DIR:-${LAB_DIR}/vault-tls}"
LAB_PKI_DIR="${LAB_PKI_DIR:-${LAB_DIR}/pki}"
export LAB_USER LAB_DIR LAB_STATE_DIR LAB_TLS_DIR LAB_PKI_DIR

# Software TPM ports. The attacker TPM stands in for a different machine.
TPM_PORT="${TPM_PORT:-2321}"
ATTACKER_TPM_PORT="${ATTACKER_TPM_PORT:-2331}"
export TPM_PORT ATTACKER_TPM_PORT

# Scratch space.
#
# On the host, transient files belong in the project's own .tmp/ — never the
# system temp directory. Inside the VM there is no project tree, so the guest's
# own namespaced staging directory serves the same purpose. VM_STAGE is where
# the Taskfile drops the scripts, and is the only place they should write
# scratch files.
VM_STAGE="${VM_STAGE:-/tmp/tpm-lab}"
LAB_TMP="${LAB_TMP:-${VM_STAGE}/tmp}"
export VM_STAGE LAB_TMP

# Point mktemp and anything else honouring TMPDIR at the lab's own scratch dir,
# so nothing this project runs leaves files loose in the system temp directory.
mkdir -p "${LAB_TMP}" 2>/dev/null || true
TMPDIR="${LAB_TMP}"
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
  runuser -u "${LAB_USER}" -- bash -lc "set -euo pipefail; source '${LAB_DIR}/env.sh'; ${cmd}"
}

# Same, but tolerates failure and returns the exit status to the caller.
# Used by the negative demos, where failure is the expected outcome.
as_lab_user_allow_fail() {
  local rc=0
  as_lab_user "$@" || rc=$?
  return "${rc}"
}

lab_mkdir() {
  install -d -o "${LAB_USER}" -g "${LAB_USER}" -m 0755 "$@"
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
