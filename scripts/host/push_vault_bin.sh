#!/bin/bash
# Push the Vault Enterprise binary and licence from the host's .bin/ into the
# VM's staging directory. Runs on macOS, never inside the VM.
#
# Vault is a private beta build, so it is not an apt package: `task provision`
# calls this before 00_provision.sh, which then installs the staged copy. The
# binary is ~550 MB, so each file is transferred only when its sha256 differs
# from the copy already installed (or already staged) in the VM.
#
# Usage: push_vault_bin.sh <vm-name> <vm-stage-dir> <vault-binary> [licence]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export LAB_TMP="${PROJECT_ROOT}/.tmp"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

VM_NAME="${1:?usage: push_vault_bin.sh <vm-name> <vm-stage-dir> <vault-binary> [licence]}"
VM_STAGE="${2:?missing vm stage dir}"
VAULT_BIN="${3:?missing path to the vault binary}"
VAULT_LICENSE="${4:-}"

# Where 00_provision.sh installs each file. Kept here so the skip check can
# compare against the installed copy, not just the staged one.
VAULT_INSTALLED="/usr/local/bin/vault"
LICENCE_INSTALLED="${LAB_DIR}/vault.hclic"

log_step "Vault Enterprise binary → ${VM_NAME}"

[[ -f "${VAULT_BIN}" ]] \
  || die "no Vault binary at ${VAULT_BIN} — copy the private beta binary into .bin/ (it is gitignored and never committed)"

host_sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# sha256 of a path inside the VM, empty when the file is absent.
vm_sha() {
  multipass exec "${VM_NAME}" -- sh -c "sha256sum '$1' 2>/dev/null | cut -d' ' -f1" || true
}

# push_if_changed <host-file> <staged-name> <installed-path>
push_if_changed() {
  local src="$1" staged="${VM_STAGE}/$2" installed="$3"
  local want
  want="$(host_sha "${src}")"

  if [[ "$(vm_sha "${installed}")" == "${want}" ]]; then
    log_detected "${installed} already matches ${src}" "skipping the transfer"
    return 0
  fi
  if [[ "$(vm_sha "${staged}")" == "${want}" ]]; then
    log_detected "${staged} already matches ${src}" "skipping the transfer"
    return 0
  fi

  log_info "Transferring ${src} ($(du -h "${src}" | cut -f1)) to ${VM_NAME}:${staged} ..."
  multipass transfer "${src}" "${VM_NAME}:${staged}"
  log_ok "staged ${staged}"
}

multipass exec "${VM_NAME}" -- mkdir -p "${VM_STAGE}"

push_if_changed "${VAULT_BIN}" vault "${VAULT_INSTALLED}"

if [[ -n "${VAULT_LICENSE}" && -f "${VAULT_LICENSE}" ]]; then
  push_if_changed "${VAULT_LICENSE}" vault.hclic "${LICENCE_INSTALLED}"
else
  log_warn "no licence at ${VAULT_LICENSE:-<unset>} — Vault Enterprise will not start without one; copy it to .bin/vault.hclic and re-run 'task provision'"
fi
