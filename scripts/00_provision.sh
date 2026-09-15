#!/bin/bash
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

# Part 1: install the TPM tooling and Vault, and lay out the lab directory.
#
# Runs as root inside the VM via `sudo -E bash <stage>/00_provision.sh`.
# Everything here is idempotent: re-running on a provisioned VM should touch
# apt at most once and finish in seconds.

log_step "Part 1: install TPM tooling and Vault"

# Non-interactive or dpkg will block on service-restart prompts under `multipass exec`.
export DEBIAN_FRONTEND=noninteractive

KEYRING="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
HASHICORP_LIST="/etc/apt/sources.list.d/hashicorp.list"

# --- apt helpers -------------------------------------------------------------

# `apt-get update` is the slow part of this script, so it runs at most once and
# only when something actually needs fresh package lists.
APT_UPDATED=0
apt_update_once() {
  if (( APT_UPDATED == 0 )); then
    log_info "Refreshing apt package lists, this takes a moment..."
    apt-get update -qq
    APT_UPDATED=1
  fi
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# Prints the subset of its arguments that are not already installed.
missing_packages() {
  local pkg
  for pkg in "$@"; do
    pkg_installed "${pkg}" || printf '%s\n' "${pkg}"
  done
}

apt_install() {
  log_info "Installing: $*"
  apt-get install -y -qq "$@"
}

# --- 1.1 TPM packages --------------------------------------------------------

log_info "Checking base packages..."
BASE_PACKAGES=(
  swtpm swtpm-tools tpm2-tools tpm2-openssl
  jq tmux gpg wget lsb-release ca-certificates
)

missing=()
mapfile -t missing < <(missing_packages "${BASE_PACKAGES[@]}")
if (( ${#missing[@]} > 0 )); then
  log_detected "${#missing[@]} missing package(s)" "installing them now (this takes a minute)"
  apt_update_once
  apt_install "${missing[@]}"
else
  log_detected "all base packages already installed" "skipping apt"
fi

# The swtpm TCTI library is what lets tpm2-tools and the OpenSSL tpm2 provider
# talk to a TCP software TPM. Its package name is release-dependent — Ubuntu
# 24.04 carries the time_t-64 transition, so the name gained a `t64` suffix.
# Resolve it rather than hardcoding either spelling.
log_info "Resolving the swtpm TCTI library package name..."
tcti_pkg="$(apt-cache search --names-only '^libtss2-tcti-swtpm' | awk '{print $1}' | sort | head -n1 || true)"
if [[ -z "${tcti_pkg}" ]]; then
  # Empty or stale package lists are the usual cause; refresh once and retry.
  apt_update_once
  tcti_pkg="$(apt-cache search --names-only '^libtss2-tcti-swtpm' | awk '{print $1}' | sort | head -n1 || true)"
fi
[[ -n "${tcti_pkg}" ]] || die "no package matching '^libtss2-tcti-swtpm' in apt — without the swtpm TCTI, tpm2-tools cannot reach the software TPM. Check that the universe component is enabled."

log_detected "swtpm TCTI package '${tcti_pkg}'" "this is the name that matters on this release/arch"
if pkg_installed "${tcti_pkg}"; then
  log_ok "${tcti_pkg} already installed"
else
  apt_update_once
  apt_install "${tcti_pkg}"
fi

# --- 1.2 Vault ---------------------------------------------------------------

log_step "HashiCorp apt repository"

# The source line is built from command substitutions. If one of these is
# missing the heredoc below would silently write a malformed apt entry, so fail
# loudly instead.
require_cmd wget gpg lsb_release dpkg \
  || die "the base package install did not provide the tools needed to add the HashiCorp repo"

repo_changed=0
if [[ -s "${KEYRING}" ]]; then
  log_detected "existing keyring at ${KEYRING}" "skipping the fetch and dearmor"
else
  log_info "Fetching and dearmoring the HashiCorp apt signing key..."
  # Dearmor straight to the keyring; a partial file here would break every
  # later apt run, so write via a temp file and move it into place.
  tmp_key="$(mktemp)"
  wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor > "${tmp_key}"
  install -m 0644 "${tmp_key}" "${KEYRING}"
  rm -f "${tmp_key}"
  repo_changed=1
fi

if write_if_changed "${HASHICORP_LIST}" <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=${KEYRING}] https://apt.releases.hashicorp.com $(lsb_release -cs) main
EOF
then
  log_info "Wrote ${HASHICORP_LIST}"
  repo_changed=1
else
  log_detected "unchanged ${HASHICORP_LIST}" "no apt list rewrite needed"
fi

# A new key or a rewritten source line means the cached lists predate the repo.
# apt_update_once is a no-op after the base install has already refreshed, so
# clear the flag first — otherwise the HashiCorp index is never fetched and
# `apt-get install vault` fails with "Unable to locate package".
if (( repo_changed )); then
  APT_UPDATED=0
  apt_update_once
fi

if pkg_installed vault; then
  log_detected "existing vault package" "skipping the install"
else
  # Guard against a stale index from any earlier run: if apt cannot see the
  # package at all, refresh unconditionally before giving up on it.
  if ! apt-cache show vault >/dev/null 2>&1; then
    log_detected "vault absent from the apt index" "refreshing package lists"
    APT_UPDATED=0
  fi
  apt_update_once
  apt_install vault
fi

# --- 1.3 Lab directory and environment file ----------------------------------

log_step "Lab directory and environment file"

lab_mkdir "${LAB_DIR}" "${LAB_STATE_DIR}" "${LAB_TLS_DIR}" "${LAB_PKI_DIR}" "${LAB_DIR}/logs"
log_ok "lab tree under ${LAB_DIR}"

# One environment file, sourced by interactive shells and by as_lab_user()
# alike, so an automated step and a live demo shell behave identically.
#
# This heredoc is the authoritative copy; templates/lab-env.sh.tpl is the
# readable reference of the same content and must be kept in sync. Templates
# stay on the host — only scripts/ and lib/common.sh are transferred into the VM.
#
# The \$ escapes keep the :- defaults literal in the written file, so a caller
# can override TPM2TOOLS_TCTI to aim at the attacker TPM (port ${ATTACKER_TPM_PORT}).
if write_if_changed "${LAB_DIR}/env.sh" <<EOF
# Lab environment for the Vault TPM cert-auth lab.
# Generated by scripts/00_provision.sh — edit templates/lab-env.sh.tpl and the
# heredoc in that script, not this file.

export LAB_DIR="${LAB_DIR}"

# TPM connection. The software TPM speaks TCP, so the TCTI names a port rather
# than /dev/tpmrm0 — on real hardware this is the only line that changes.
#
# Both are written with a :- default so a caller can point a single command at
# the attacker TPM without editing this file:
#   TPM2TOOLS_TCTI=swtpm:port=${ATTACKER_TPM_PORT} tpm2_getrandom 8 --hex
# That is how the Part 8.1 stolen-key demo simulates a different machine.
export TPM2TOOLS_TCTI="\${TPM2TOOLS_TCTI:-swtpm:port=${TPM_PORT}}"
export TPM2OPENSSL_TCTI="\${TPM2OPENSSL_TCTI:-swtpm:port=${TPM_PORT}}"

# Vault dev server with TLS. The dev certificate is issued for 127.0.0.1 only,
# which is why client and server both live inside the VM.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${LAB_TLS_DIR}/vault-ca.pem"
export VAULT_TOKEN="root"
EOF
then
  log_info "Wrote ${LAB_DIR}/env.sh"
else
  log_detected "unchanged ${LAB_DIR}/env.sh" "leaving it alone"
fi
# write_if_changed installs as root; the lab user must be able to source it.
chown "${LAB_USER}:${LAB_USER}" "${LAB_DIR}/env.sh"
chmod 0644 "${LAB_DIR}/env.sh"
log_ok "${LAB_DIR}/env.sh owned by ${LAB_USER}, mode 0644"

# --- Verify ------------------------------------------------------------------

log_step "Verify Part 1"

require_cmd swtpm swtpm_setup tpm2_getrandom tpm2_getcap openssl vault jq \
  || die "provisioning left a required command missing — see the errors above"

log_info "vault version:"
log_detail "  $(vault version)"

# `-v` only prints the tool banner, but it still loads the TCTI library, so a
# failure here usually means the TCTI package resolved above is not usable.
log_info "tpm2_getcap -v:"
tpm2_getcap -v 2>&1 | sed 's/^/  /' \
  || log_warn "tpm2_getcap -v failed — check that ${tcti_pkg} provides the swtpm TCTI"

log_info "swtpm --version:"
swtpm --version 2>&1 | sed 's/^/  /' \
  || log_warn "swtpm --version failed"

log_ok "Part 1 complete — next: task tpm"
