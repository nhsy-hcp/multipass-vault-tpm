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
  jq tmux gpg wget unzip socat lsb-release ca-certificates
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

# --- 1.2 Vault Enterprise (TPM auth) -----------------------------------------
#
# This lab needs the Vault Enterprise TPM auth method and the matching Proxy
# auto-auth. Those are not in the OSS apt package. Pin a release zip from
# releases.hashicorp.com and install the binary at /usr/local/bin/vault so it
# wins over any leftover /usr/bin/vault from an earlier apt install.

VAULT_VERSION="${VAULT_VERSION:-2.2.0+ent}"
VAULT_INSTALL_DIR="/usr/local/bin"
VAULT_BIN="${VAULT_INSTALL_DIR}/vault"

log_step "Vault Enterprise ${VAULT_VERSION}"

require_cmd wget unzip sha256sum dpkg \
  || die "the base package install did not provide the tools needed to install Vault"

# Prefer the zip's linux_<arch> name. dpkg reports arm64; releases use arm64 too.
arch="$(dpkg --print-architecture)"
case "${arch}" in
  amd64|arm64|386|ppc64le|s390x) ;;
  *) die "no Vault Enterprise zip for architecture '${arch}'" ;;
esac

vault_zip="vault_${VAULT_VERSION}_linux_${arch}.zip"
vault_base_url="https://releases.hashicorp.com/vault/${VAULT_VERSION}"
vault_zip_url="${vault_base_url}/${vault_zip}"
vault_sums_url="${vault_base_url}/vault_${VAULT_VERSION}_SHA256SUMS"

need_vault_install=1
if [[ -x "${VAULT_BIN}" ]]; then
  installed="$(${VAULT_BIN} version 2>/dev/null || true)"
  # vault version prints "Vault v2.2.0+ent (...)" — match the version token.
  if printf '%s' "${installed}" | grep -Fq "v${VAULT_VERSION}"; then
    need_vault_install=0
    log_detected "Vault ${VAULT_VERSION} already at ${VAULT_BIN}" "skipping download"
  else
    log_detected "a different Vault at ${VAULT_BIN}" "${installed:-unknown} — replacing it"
  fi
fi

if (( need_vault_install == 1 )); then
  # Stop anything still holding the old binary before we overwrite it.
  systemctl stop vault-dev vault-proxy@payments vault-proxy@analytics \
    vault.service 2>/dev/null || true

  work="$(mktemp -d)"
  cleanup_vault_work() { rm -rf "${work}"; }
  trap cleanup_vault_work EXIT

  log_info "Downloading ${vault_zip_url}"
  wget -q -O "${work}/${vault_zip}" "${vault_zip_url}"
  wget -q -O "${work}/SHA256SUMS" "${vault_sums_url}"

  log_info "Verifying SHA-256"
  (
    cd "${work}"
    grep -F " ${vault_zip}" SHA256SUMS | sha256sum -c -
  )

  log_info "Installing vault to ${VAULT_BIN}"
  unzip -qo "${work}/${vault_zip}" -d "${work}"
  install -m 0755 "${work}/vault" "${VAULT_BIN}"

  # An apt-installed vault at /usr/bin/vault would otherwise shadow this one
  # when PATH puts /usr/bin first. Remove the packages; the binary we want is
  # the one under /usr/local/bin.
  if pkg_installed vault || pkg_installed vault-enterprise; then
    log_detected "apt vault package(s)" "removing so ${VAULT_BIN} is the only vault"
    apt-get remove -y -qq vault vault-enterprise 2>/dev/null || true
  fi

  cleanup_vault_work
  trap - EXIT
fi

# Ensure /usr/local/bin is ahead of /usr/bin for non-login shells that
# multipass and systemd ExecStart use. The unit files call /usr/bin/vault
# today; point them at the Enterprise binary via a symlink if needed.
if [[ ! -e /usr/bin/vault ]] || [[ "$(readlink -f /usr/bin/vault 2>/dev/null || true)" != "$(readlink -f "${VAULT_BIN}")" ]]; then
  if [[ -e /usr/bin/vault && ! -L /usr/bin/vault ]]; then
    log_warn "/usr/bin/vault is a real file, not a symlink — leaving it; units use ${VAULT_BIN}"
  else
    ln -sfn "${VAULT_BIN}" /usr/bin/vault
    log_ok "/usr/bin/vault -> ${VAULT_BIN}"
  fi
fi

[[ -x "${VAULT_BIN}" ]] || die "Vault binary missing at ${VAULT_BIN} after install"
log_ok "$(${VAULT_BIN} version)"

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
