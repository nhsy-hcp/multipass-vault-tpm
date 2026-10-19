#!/bin/bash
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

# Part 1: install the TPM tooling and Vault Enterprise, and lay out the lab
# directory.
#
# Runs as root inside the VM via `sudo -E bash <stage>/00_provision.sh`.
# Everything here is idempotent: re-running on a provisioned VM should touch
# apt at most once and finish in seconds.
#
# Vault Enterprise comes from the HashiCorp apt repository, pinned to the
# version passed as $1 (VAULT_VERSION in the Taskfile) and held there. The
# licence is not packaged: `task provision` stages it from VAULT_LICENSE in
# the host's .env, as a systemd EnvironmentFile, before this script runs.

VAULT_VERSION="${1:?usage: 00_provision.sh <vault-enterprise apt version, e.g. 2.2.0+ent-1>}"

log_step "Part 1: install TPM tooling and Vault Enterprise"

# Non-interactive or dpkg will block on service-restart prompts under `multipass exec`.
export DEBIAN_FRONTEND=noninteractive

KEYRING="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
HASHICORP_LIST="/etc/apt/sources.list.d/hashicorp.list"
VAULT_PKG="vault-enterprise"
VAULT_INSTALLED="/usr/bin/vault"
LICENCE_STAGED="${STAGE_DIR}/licence/vault-dev.env"
LICENCE_INSTALLED="/etc/vault-dev.env"

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
  swtpm swtpm-tools tpm2-tools
  jq tmux ca-certificates curl gnupg lsb-release
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

# --- 1.2 Vault Enterprise ----------------------------------------------------

log_step "Vault Enterprise ${VAULT_VERSION}"

# The HashiCorp repository, signed by its own keyring rather than trusted
# globally. Written only when absent, so a re-run does not force an apt update.
if [[ ! -s "${KEYRING}" || ! -f "${HASHICORP_LIST}" ]]; then
  log_detected "no HashiCorp apt repository" "adding it"
  curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes -o "${KEYRING}"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=${KEYRING}] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > "${HASHICORP_LIST}"
  APT_UPDATED=0
else
  log_detected "the HashiCorp apt repository" "already configured"
fi

installed_ver="$(dpkg-query -W -f='${Version}' "${VAULT_PKG}" 2>/dev/null || true)"
if [[ "${installed_ver}" == "${VAULT_VERSION}" ]] && pkg_installed "${VAULT_PKG}"; then
  log_detected "${VAULT_PKG} ${installed_ver}" "skipping the install"
else
  log_detected "${VAULT_PKG} ${installed_ver:-not installed}" "installing ${VAULT_VERSION}"
  apt_update_once
  apt-mark unhold "${VAULT_PKG}" >/dev/null 2>&1 || true
  apt_install --allow-downgrades "${VAULT_PKG}=${VAULT_VERSION}"
fi
# Held so an unattended `apt upgrade` cannot move the lab off the pinned build.
apt-mark hold "${VAULT_PKG}" >/dev/null
log_ok "${VAULT_PKG} held at ${VAULT_VERSION}"

# The package ships vault.service for a production server, which would bind
# 127.0.0.1:8200 and fight vault-dev for the port. The lab never uses it.
if systemctl is-enabled --quiet vault.service 2>/dev/null \
  || systemctl is-active --quiet vault.service 2>/dev/null; then
  log_detected "the packaged vault.service enabled or running" "disabling it"
  systemctl disable --now vault.service
fi

vault_ver="$("${VAULT_INSTALLED}" version 2>&1)" \
  || die "${VAULT_INSTALLED} does not run: ${vault_ver}"
[[ "${vault_ver}" == *"+ent"* ]] \
  || die "${VAULT_INSTALLED} is not an Enterprise build: ${vault_ver}"
log_ok "${vault_ver}"

# --- 1.3 Lab directory and environment file ----------------------------------

log_step "Lab directory and environment file"

lab_mkdir "${VM_DIR}" "${STATE_DIR}" "${TLS_DIR}" "${TPM_DIR}" "${VM_DIR}/logs"
log_ok "lab tree under ${VM_DIR}"

# Enterprise licence as VAULT_LICENSE=<text>, the vault-dev unit's
# EnvironmentFile. Root-only: systemd reads it before dropping to the lab user,
# so the server gets the licence and the lab shell cannot read it.
if [[ -s "${LICENCE_STAGED}" ]]; then
  if [[ -f "${LICENCE_INSTALLED}" ]] && cmp -s "${LICENCE_STAGED}" "${LICENCE_INSTALLED}"; then
    log_detected "unchanged ${LICENCE_INSTALLED}" "skipping the install"
  else
    install -m 0600 -o root -g root "${LICENCE_STAGED}" "${LICENCE_INSTALLED}"
    log_ok "installed licence at ${LICENCE_INSTALLED}"
  fi
  rm -rf "$(dirname "${LICENCE_STAGED}")"
elif [[ -s "${LICENCE_INSTALLED}" ]]; then
  log_detected "existing licence at ${LICENCE_INSTALLED}" "keeping it"
else
  log_warn "no licence staged or installed — Vault Enterprise will not start; paste the licence text into VAULT_LICENSE in the host's .env and re-run 'task provision'"
fi

# One environment file, sourced by interactive shells and by as_lab_user()
# alike, so an automated step and a live demo shell behave identically.
#
# This heredoc is the authoritative copy; templates/lab-env.sh.tpl is the
# readable reference of the same content and must be kept in sync. Templates
# stay on the host — only scripts/ and lib/common.sh are transferred into the VM.
#
# The \$ escapes keep the :- defaults literal in the written file, so a caller
# can override the TPM path to aim at the attacker TPM.
if write_if_changed "${VM_DIR}/env.sh" <<EOF
# Lab environment for the Vault TPM auth lab.
# Generated by scripts/00_provision.sh — edit templates/lab-env.sh.tpl and the
# heredoc in that script, not this file.

export VM_DIR="${VM_DIR}"
export TPM_DIR="${TPM_DIR}"

# TPM connection. Each software TPM serves a unix socket, and tpm2-tools and
# the Vault CLI reach the same TPM through the same path. On real hardware this
# becomes /dev/tpmrm0 (TCTI "device:/dev/tpmrm0") and nothing else changes.
#
# Written with :- defaults so a caller can point one command at the attacker
# TPM without editing this file — that is how the Part 8 demos simulate a
# different machine:
#   vault tpm ek -tpm-device-path=\${ATTACKER_TPM_DEVICE_PATH}
#   TPM2TOOLS_TCTI=swtpm:path=\${ATTACKER_TPM_DEVICE_PATH} tpm2_getrandom 8 --hex
export TPM_DEVICE_PATH="\${TPM_DEVICE_PATH:-${TPM_SOCK}}"
export TPM2TOOLS_TCTI="\${TPM2TOOLS_TCTI:-swtpm:path=${TPM_SOCK}}"
export ATTACKER_TPM_DEVICE_PATH="${ATTACKER_TPM_SOCK}"

# Vault dev server with TLS. The dev certificate is issued for 127.0.0.1 only,
# which is why client and server both live inside the VM.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${TLS_DIR}/vault-ca.pem"
export VAULT_TOKEN="root"
EOF
then
  log_info "Wrote ${VM_DIR}/env.sh"
else
  log_detected "unchanged ${VM_DIR}/env.sh" "leaving it alone"
fi
# write_if_changed installs as root; the lab user must be able to source it.
chown "${VM_USER}:${VM_USER}" "${VM_DIR}/env.sh"
chmod 0644 "${VM_DIR}/env.sh"
log_ok "${VM_DIR}/env.sh owned by ${VM_USER}, mode 0644"

# --- Verify ------------------------------------------------------------------

log_step "Verify Part 1"

require_cmd swtpm swtpm_setup tpm2_getrandom tpm2_getcap tpm2_flushcontext tpm2_print openssl vault jq \
  || die "provisioning left a required command missing — see the errors above"

log_info "vault on PATH (expect ${VAULT_INSTALLED}):"
log_detail "  $(command -v vault) — $(vault version)"

# `-v` only prints the tool banner, but it still loads the TCTI library, so a
# failure here usually means the TCTI package resolved above is not usable.
log_info "tpm2_getcap -v:"
tpm2_getcap -v 2>&1 | sed 's/^/  /' \
  || log_warn "tpm2_getcap -v failed — check that ${tcti_pkg} provides the swtpm TCTI"

log_info "swtpm --version:"
swtpm --version 2>&1 | sed 's/^/  /' \
  || log_warn "swtpm --version failed"

log_ok "Part 1 complete — next: task tpm"
