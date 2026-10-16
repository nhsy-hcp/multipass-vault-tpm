#!/bin/bash
# Push the Vault Enterprise licence from the host's .env into the VM's staging
# directory. Runs on macOS, never inside the VM.
#
# Vault itself comes from the HashiCorp apt repository inside the VM; only the
# licence has to cross from the host. It is the licence text, read from the
# VAULT_LICENSE environment variable (Task loads it from .env), and it never
# goes on a command line: it is written as `VAULT_LICENSE=<text>` to a 0600
# file under .tmp/, transferred, and deleted. 00_provision.sh installs the
# staged copy as /etc/vault-dev.env, the vault-dev unit's EnvironmentFile. The
# transfer is skipped when the installed copy already matches.
#
# Usage: VAULT_LICENSE=... push_licence.sh <vm-name> <vm-stage-dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export SCRATCH_DIR="${PROJECT_ROOT}/.tmp"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

VM_NAME="${1:?usage: push_licence.sh <vm-name> <vm-stage-dir>}"
VM_STAGE="${2:?missing vm stage dir}"

# Where 00_provision.sh installs the file. Kept here so the skip check can
# compare against the installed copy, not just the staged one.
ENV_INSTALLED="/etc/vault-dev.env"
ENV_STAGED="${VM_STAGE}/vault-dev.env"

log_step "Vault Enterprise licence → ${VM_NAME}"

[[ -n "${VAULT_LICENSE:-}" ]] \
  || die "VAULT_LICENSE is empty — paste your Vault Enterprise licence text into .env (see .env.template)"

mkdir -p "${SCRATCH_DIR}"
env_file="$(umask 077 && mktemp "${SCRATCH_DIR}/vault-dev.env.XXXXXX")"
trap 'rm -f "${env_file}"' EXIT
printf 'VAULT_LICENSE=%s\n' "${VAULT_LICENSE}" > "${env_file}"

want="$(shasum -a 256 "${env_file}" | awk '{print $1}')"
# Root-only in the VM, so the comparison needs sudo. Empty when absent.
have="$(multipass exec "${VM_NAME}" -- sudo sh -c "sha256sum '${ENV_INSTALLED}' 2>/dev/null | cut -d' ' -f1" || true)"

multipass exec "${VM_NAME}" -- mkdir -p "${VM_STAGE}"

if [[ "${have}" == "${want}" ]]; then
  log_detected "${ENV_INSTALLED} already holds this licence" "skipping the transfer"
  # A staged copy left by an interrupted earlier run could differ; 00_provision.sh
  # would install it in preference to the good installed one.
  multipass exec "${VM_NAME}" -- rm -f "${ENV_STAGED}"
  exit 0
fi

log_info "Transferring the licence to ${VM_NAME}:${ENV_STAGED} ..."
multipass transfer "${env_file}" "${VM_NAME}:${ENV_STAGED}"
multipass exec "${VM_NAME}" -- chmod 0600 "${ENV_STAGED}"
log_ok "staged ${ENV_STAGED}"
